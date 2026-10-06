import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:life_os/features/notifications/domain/models/notification_occurrence.dart';
import 'package:life_os/features/notifications/data/tables/notification_dismissals.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/local_mutation_gate.dart';
import 'package:life_os/features/notifications/data/tables/notifications_table.dart';

part 'notification_dao.g.dart';

@DriftAccessor(
  tables: [NotificationsTable, NotificationDismissals, SyncQueueTable],
)
class NotificationDao extends DatabaseAccessor<AppDatabase>
    with _$NotificationDaoMixin {
  NotificationDao(super.db);

  Stream<List<NotificationsTableData>> watchAllNotifications() {
    return (select(
      notificationsTable,
    )..orderBy([(t) => OrderingTerm.desc(t.createdAt)])).watch();
  }

  Future<List<NotificationsTableData>> getAllNotifications() =>
      select(notificationsTable).get();

  Future<NotificationsTableData?> getNotificationById(String id) {
    return (select(
      notificationsTable,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  /// Insere uma nova notificação ou atualiza apenas o conteúdo mutável.
  ///
  /// O estado de interação do usuário (isRead/isCompleted) é preservado
  /// enquanto o evento representado pela notificação não mudou de data.
  Future<bool> upsertPreservingState(
    NotificationsTableCompanion incoming, {
    LocalMutationTicket? admission,
  }) => attachedDatabase.localMutations.run(
    () => attachedDatabase.transaction(() => _upsertPreservingState(incoming)),
    ticket: admission,
    waitForReopen: false,
  );

  Future<bool> _upsertPreservingState(
    NotificationsTableCompanion incoming,
  ) async {
    final key = NotificationOccurrence.key(
      id: incoming.id.value,
      moduleType: incoming.moduleType.value,
      dueDate: incoming.dueDate.value,
    );
    if (key != null && await isDismissed(incoming.id.value, key)) return false;
    if (key == null &&
        await (select(notificationDismissals)
                  ..where((t) => t.notificationId.equals(incoming.id.value))
                  ..limit(1))
                .getSingleOrNull() !=
            null) {
      // A malformed/legacy document cannot prove that it is a new occurrence.
      return false;
    }
    // Old keys stay inert for new occurrences and protect against late hydration.
    final existing = await getNotificationById(incoming.id.value);

    // Notificação ainda não existe.
    if (existing == null) {
      await into(
        notificationsTable,
      ).insert(incoming.copyWith(occurrenceKey: Value(key)));
      return true;
    }

    final incomingPriority = incoming.priority.value;
    final incomingModuleType = incoming.moduleType.value;
    final incomingRoute = incoming.route.value;
    final incomingDueDate = incoming.dueDate.value;
    final incomingIsCompleted = incoming.isCompleted.value;

    final sameEventDay = _sameLocalDay(existing.dueDate, incomingDueDate);
    final isHabitNotification =
        incomingModuleType == 'habits' &&
        incoming.id.value.startsWith('habit_');
    final isDerivedHabitCompletion = isHabitNotification && incomingIsCompleted;
    final wasDerivedHabitCompletion =
        isHabitNotification && existing.priority == 'completed';

    final bool nextIsRead;
    final bool nextIsCompleted;

    if (!sameEventDay) {
      nextIsRead = isDerivedHabitCompletion;
      nextIsCompleted = isDerivedHabitCompletion;
    } else if (isDerivedHabitCompletion) {
      nextIsRead = true;
      nextIsCompleted = true;
    } else if (wasDerivedHabitCompletion) {
      // O hábito foi desmarcado no módulo de origem no mesmo dia.
      nextIsRead = false;
      nextIsCompleted = false;
    } else {
      // Interações manuais da Central permanecem preservadas.
      nextIsRead = existing.isRead;
      nextIsCompleted = existing.isCompleted;
    }

    final changed =
        existing.title != incoming.title.value ||
        existing.description != incoming.description.value ||
        existing.priority != incomingPriority ||
        existing.moduleType != incomingModuleType ||
        existing.route != incomingRoute ||
        existing.dueDate != incomingDueDate ||
        existing.occurrenceKey != key ||
        existing.isRead != nextIsRead ||
        existing.isCompleted != nextIsCompleted;

    if (!changed) {
      return false;
    }

    await (update(
      notificationsTable,
    )..where((t) => t.id.equals(incoming.id.value))).write(
      NotificationsTableCompanion(
        title: incoming.title,
        description: incoming.description,
        priority: Value(incomingPriority),
        moduleType: Value(incomingModuleType),
        route: Value(incomingRoute),
        dueDate: Value(incomingDueDate),
        occurrenceKey: Value(key),

        isRead: Value(nextIsRead),
        isCompleted: Value(nextIsCompleted),

        // Não alteramos createdAt durante um upsert.
        // A data original da notificação deve permanecer preservada.
      ),
    );

    return true;
  }

  Future<void> markAsRead(String id) => attachedDatabase.localMutations.run(
    () async => (update(notificationsTable)..where((t) => t.id.equals(id)))
        .write(const NotificationsTableCompanion(isRead: Value(true))),
  );

  Future<void> markAsCompleted(String id) =>
      attachedDatabase.localMutations.run(
        () async =>
            (update(notificationsTable)..where((t) => t.id.equals(id))).write(
              const NotificationsTableCompanion(
                isRead: Value(true),
                isCompleted: Value(true),
              ),
            ),
      );

  Future<void> deleteNotification(String id) =>
      attachedDatabase.localMutations.run(
        () async =>
            (delete(notificationsTable)..where((t) => t.id.equals(id))).go(),
      );

  Future<bool> isDismissed(String id, String occurrenceKey) async =>
      await (select(notificationDismissals)..where(
            (t) =>
                t.notificationId.equals(id) &
                t.occurrenceKey.equals(occurrenceKey),
          ))
          .getSingleOrNull() !=
      null;

  /// The dismissal, local removal and outbox intent commit together, before I/O.
  Future<void> dismissNotification(
    String id,
    String ownerUid,
  ) => attachedDatabase.transaction(() async {
    final existing = await getNotificationById(id);
    // Repeating a dismissal of an already absent card is a no-op.
    if (existing == null) return;
    final key =
        existing.occurrenceKey ??
        NotificationOccurrence.key(
          id: id,
          moduleType: existing.moduleType,
          dueDate: existing.dueDate,
        );
    if (key == null) {
      throw UnsupportedError('Notification occurrence contract unavailable');
    }
    if (!await isDismissed(id, key)) {
      await attachedDatabase.transactionWithSync(
        ownerUid: ownerUid,
        collection: 'notifications',
        docId: id,
        operationType: 'delete',
        payloadJson: jsonEncode({'occurrenceKey': key}),
        localOperation: () async {
          await into(notificationDismissals).insert(
            NotificationDismissalsCompanion.insert(
              notificationId: id,
              occurrenceKey: key,
              dismissedAt: DateTime.now(),
            ),
          );
          await deleteNotification(id);
        },
      );
    } else {
      await deleteNotification(id);
    }
  }, admission: attachedDatabase.localMutations.capture(expectedUid: ownerUid));

  bool _sameLocalDay(DateTime? a, DateTime? b) {
    if (a == null || b == null) return a == b;
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }
}
