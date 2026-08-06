// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'notification_dao.dart';

// ignore_for_file: type=lint
mixin _$NotificationDaoMixin on DatabaseAccessor<AppDatabase> {
  $NotificationsTableTable get notificationsTable =>
      attachedDatabase.notificationsTable;
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
}
