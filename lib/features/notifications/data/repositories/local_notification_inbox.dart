import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/services/notification_preferences.dart';
import 'package:life_os/features/notifications/domain/models/notification_model.dart';
import 'package:life_os/features/notifications/domain/models/notification_occurrence.dart';
import 'package:life_os/features/notifications/domain/services/notification_module_reconciler.dart';

class LocalNotificationInbox implements NotificationDerivationStore {
  LocalNotificationInbox(this._db) {
    if (!_db.isLocalOnly) {
      throw ArgumentError('LOCAL_PROFILE_DATABASE_REQUIRED');
    }
  }

  final AppDatabase _db;

  Future<void> reconcile({DateTime? today}) => _db.transaction(
    () => const NotificationModuleReconciler(propagateErrors: true).sync(
      repository: this,
      db: _db,
      preferences: const NotificationPreferences.enabled(),
      today: today,
    ),
  );

  Stream<List<NotificationModel>> watch() => _db.notificationDao
      .watchAllNotifications()
      .map((rows) => rows.map(NotificationModel.fromDrift).toList());

  @override
  Future<List<NotificationModel>> getLocalNotifications() async =>
      (await _db.notificationDao.getAllNotifications())
          .map(NotificationModel.fromDrift)
          .toList();

  @override
  Future<void> saveLocalNotification(NotificationModel notification) async {
    await _db.notificationDao.upsertPreservingState(
      NotificationModel.toCompanion(notification),
    );
  }

  @override
  Future<void> deleteDerivedNotification(String id) =>
      _db.notificationDao.deleteNotification(id);

  Future<void> markAsRead(NotificationModel card) =>
      _actOnCurrent(card, () => _db.notificationDao.markAsRead(card.id));

  Future<void> markAsCompleted(NotificationModel card) =>
      _actOnCurrent(card, () => _db.notificationDao.markAsCompleted(card.id));

  Future<void> dismiss(NotificationModel card) => _actOnCurrent(
    card,
    () => _db.notificationDao.dismissNotification(card.id, _db.identity!.uid),
  );

  Future<void> _actOnCurrent(
    NotificationModel card,
    Future<void> Function() action,
  ) => _db.transaction(() async {
    final expected = NotificationOccurrence.key(
      id: card.id,
      moduleType: card.moduleType,
      dueDate: card.dueDate,
    );
    final row = await _db.notificationDao.getNotificationById(card.id);
    if (expected == null || row?.occurrenceKey != expected) {
      throw StateError('LOCAL_NOTIFICATION_OCCURRENCE_CHANGED');
    }
    await action();
  });
}
