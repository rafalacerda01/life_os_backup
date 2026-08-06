import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/core/utils/app_logger.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/features/notifications/data/daos/notification_dao.dart';
import 'package:life_os/features/notifications/domain/models/notification_model.dart';

final appDatabaseProvider = Provider<AppDatabase>((ref) {
  return AppDatabase();
});

class NotificationsRepository {
  final FirebaseFirestore firestore;
  final NotificationDao? localDao;

  NotificationsRepository({FirebaseFirestore? firestore, this.localDao})
    : firestore = firestore ?? FirebaseFirestore.instance;

  Stream<List<NotificationModel>> getNotificationsStream() {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      return Stream.value([]);
    }

    try {
      return firestore
          .collection('users')
          .doc(user.uid)
          .collection('notifications')
          .orderBy('createdAt', descending: true)
          .snapshots()
          .map(
            (snapshot) => snapshot.docs
                .map((doc) => NotificationModel.fromFirestore(doc))
                .toList(),
          )
          .handleError((error, stackTrace) {
            AppLogger.e('Erro na stream de notificações', error, stackTrace);
            return <NotificationModel>[];
          });
    } catch (e, stack) {
      AppLogger.e('Erro ao inicializar stream de notificações', e, stack);
      return Stream.value([]);
    }
  }

  Stream<List<NotificationModel>> watchLocalNotifications() {
    if (localDao == null) return Stream.value([]);
    return localDao!.watchAllNotifications().map(
      (rows) => rows.map((row) => NotificationModel.fromDrift(row)).toList(),
    );
  }

  Future<void> saveLocalNotification(NotificationModel notification) async {
    if (localDao == null) return;
    await localDao!.insertNotification(
      NotificationModel.toCompanion(notification),
    );
  }

  Future<void> markAsReadLocal(String id) async {
    await localDao?.markAsRead(id);
  }

  Future<void> markAsCompletedLocal(String id) async {
    await localDao?.markAsCompleted(id);
  }

  Future<void> deleteNotification(String id) async {
    if (localDao == null) return;
    await localDao!.deleteNotification(id);
  }
}

final notificationsRepositoryProvider = Provider<NotificationsRepository>((
  ref,
) {
  final db = ref.watch(appDatabaseProvider);
  return NotificationsRepository(
    firestore: FirebaseFirestore.instance,
    localDao: db.notificationDao,
  );
});
