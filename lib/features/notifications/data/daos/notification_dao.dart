import 'package:drift/drift.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/features/notifications/data/tables/notifications_table.dart';

part 'notification_dao.g.dart';

@DriftAccessor(tables: [NotificationsTable])
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
    NotificationsTableCompanion incoming,
  ) async {
    final existing = await getNotificationById(incoming.id.value);

    // Notificação ainda não existe.
    if (existing == null) {
      await into(notificationsTable).insert(incoming);
      return true;
    }

    final incomingPriority = incoming.priority.value;
    final incomingModuleType = incoming.moduleType.value;
    final incomingRoute = incoming.route.value;
    final incomingDueDate = incoming.dueDate.value;

    final sameEventDay = _sameLocalDay(existing.dueDate, incomingDueDate);
    final changed =
        existing.title != incoming.title.value ||
        existing.description != incoming.description.value ||
        existing.priority != incomingPriority ||
        existing.moduleType != incomingModuleType ||
        existing.route != incomingRoute ||
        existing.dueDate != incomingDueDate ||
        (!sameEventDay && (existing.isRead || existing.isCompleted));

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

        // Se o evento é do mesmo dia, preservamos a interação do usuário.
        // Se mudou de dia, trata-se de uma nova ocorrência.
        isRead: Value(sameEventDay ? existing.isRead : false),
        isCompleted: Value(sameEventDay ? existing.isCompleted : false),

        // Não alteramos createdAt durante um upsert.
        // A data original da notificação deve permanecer preservada.
      ),
    );

    return true;
  }

  Future<void> markAsRead(String id) =>
      (update(notificationsTable)..where((t) => t.id.equals(id))).write(
        const NotificationsTableCompanion(isRead: Value(true)),
      );

  Future<void> markAsCompleted(String id) =>
      (update(notificationsTable)..where((t) => t.id.equals(id))).write(
        const NotificationsTableCompanion(
          isCompleted: Value(true),
          priority: Value('completed'),
        ),
      );

  Future<void> deleteNotification(String id) =>
      (delete(notificationsTable)..where((t) => t.id.equals(id))).go();

  bool _sameLocalDay(DateTime? a, DateTime? b) {
    if (a == null || b == null) return a == b;
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }
}
