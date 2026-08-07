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
    final existing = await getNotificationById(incoming.id);

    if (existing == null) {
      await into(notificationsTable).insert(incoming);
      return true;
    }

    final incomingDueDate = incoming.dueDate.present
        ? incoming.dueDate.value
        : null;

    final sameEventDay = _sameLocalDay(existing.dueDate, incomingDueDate);
    final incomingPriority = existing.isCompleted
        ? 'completed'
        : (incoming.priority.present
              ? incoming.priority.value
              : existing.priority);

    final changed =
        existing.title != incoming.title.value ||
        existing.description != incoming.description.value ||
        existing.priority != incomingPriority ||
        existing.moduleType != incoming.moduleType.value ||
        existing.route != incoming.route.value ||
        existing.dueDate != incomingDueDate ||
        (!sameEventDay && (existing.isRead || existing.isCompleted));

    if (!changed) return false;

    await (update(
      notificationsTable,
    )..where((t) => t.id.equals(incoming.id))).write(
      NotificationsTableCompanion(
        title: incoming.title,
        description: incoming.description,
        priority: Value(incomingPriority),
        moduleType: incoming.moduleType,
        route: incoming.route,
        dueDate: incoming.dueDate,
        // Se o evento mudou de dia, o estado pertence ao evento antigo.
        // Para o mesmo evento, preservamos o estado do usuário.
        isRead: Value(sameEventDay ? existing.isRead : false),
        isCompleted: Value(sameEventDay ? existing.isCompleted : false),
        // createdAt é a data de criação da notificação e não deve ser
        // reescrita a cada varredura do Engine.
        createdAt: Value(existing.createdAt),
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
