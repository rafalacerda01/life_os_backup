// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'notification_dao.dart';

// ignore_for_file: type=lint
mixin _$NotificationDaoMixin on DatabaseAccessor<AppDatabase> {
  $NotificationsTableTable get notificationsTable =>
      attachedDatabase.notificationsTable;
  $NotificationDismissalsTable get notificationDismissals =>
      attachedDatabase.notificationDismissals;
  $SyncQueueTableTable get syncQueueTable => attachedDatabase.syncQueueTable;
  NotificationDaoManager get managers => NotificationDaoManager(this);
}

class NotificationDaoManager {
  final _$NotificationDaoMixin _db;
  NotificationDaoManager(this._db);
  $$NotificationsTableTableTableManager get notificationsTable =>
      $$NotificationsTableTableTableManager(
        _db.attachedDatabase,
        _db.notificationsTable,
      );
  $$NotificationDismissalsTableTableManager get notificationDismissals =>
      $$NotificationDismissalsTableTableManager(
        _db.attachedDatabase,
        _db.notificationDismissals,
      );
  $$SyncQueueTableTableTableManager get syncQueueTable =>
      $$SyncQueueTableTableTableManager(
        _db.attachedDatabase,
        _db.syncQueueTable,
      );
}
