import 'package:drift/drift.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/features/notifications/data/tables/notifications_table.dart';

part 'notification_dao.g.dart';

@DriftAccessor(tables: [NotificationsTable])
class NotificationDao extends DatabaseAccessor<AppDatabase>
    with _$NotificationDaoMixin {
  // 🟢 CORREÇÃO: Utilizando o "super.db" exigido pelos lints recentes do Dart
  NotificationDao(super.db);

  Stream<List<NotificationsTableData>> watchAllNotifications() {
    return (select(
      notificationsTable,
    )..orderBy([(t) => OrderingTerm.desc(t.createdAt)])).watch();
  }

  Future<List<NotificationsTableData>> getAllNotifications() =>
      select(notificationsTable).get();

  Future<void> insertNotification(NotificationsTableCompanion entry) =>
      into(notificationsTable).insertOnConflictUpdate(entry);

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
}
