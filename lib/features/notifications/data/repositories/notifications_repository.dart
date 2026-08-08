import 'dart:async';
import 'package:life_os/core/database/app_database.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/core/database/database_provider.dart';
import 'package:life_os/core/utils/app_logger.dart';
import 'package:life_os/features/notifications/data/daos/notification_dao.dart';
import 'package:life_os/features/notifications/domain/models/notification_model.dart';

/// Repository Offline-First da Central de Notificações.
///
/// A UI lê do Drift. O Firestore é utilizado para sincronização remota.
/// A implementação aproveita o cache/offline queue do próprio SDK do
/// Firestore, sem criar uma segunda Sync Queue paralela.
class NotificationsRepository {
  final FirebaseFirestore firestore;
  final FirebaseAuth auth;
  final NotificationDao? localDao;

  NotificationsRepository({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
    this.localDao,
  }) : firestore = firestore ?? FirebaseFirestore.instance,
       auth = auth ?? FirebaseAuth.instance;

  Stream<List<NotificationModel>> getNotificationsStream() {
    final user = auth.currentUser;

    if (user == null) {
      return Stream.value(const <NotificationModel>[]);
    }

    return firestore
        .collection('users')
        .doc(user.uid)
        .collection('notifications')
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map(
          (snapshot) =>
              snapshot.docs.map(NotificationModel.fromFirestore).toList(),
        )
        .handleError((error, stackTrace) {
          AppLogger.e(
            'Erro na stream remota de notificações',
            error,
            stackTrace,
          );
        });
  }

  /// Fonte da verdade para a UI: banco local.
  Stream<List<NotificationModel>> watchLocalNotifications() {
    final dao = localDao;
    if (dao == null) {
      return Stream.value(const <NotificationModel>[]);
    }

    return dao.watchAllNotifications().map(
      (rows) => rows.map(NotificationModel.fromDrift).toList(),
    );
  }

  Future<NotificationModel?> getLocalNotification(String id) async {
    final dao = localDao;
    if (dao == null) return null;

    final row = await dao.getNotificationById(id);

    if (row == null) return null;

    return NotificationModel.fromDrift(row);
  }

  /// Salva primeiro no Drift e sincroniza em background.
  Future<void> saveLocalNotification(NotificationModel notification) async {
    final dao = localDao;
    if (dao == null) return;

    try {
      final shouldSync = await dao.upsertPreservingState(
        NotificationModel.toCompanion(notification),
      );

      if (shouldSync) {
        unawaited(_saveToFirestore(notification));
      }
    } catch (error, stackTrace) {
      AppLogger.e('Erro ao salvar notificação localmente', error, stackTrace);
      rethrow;
    }
  }

  Future<void> markAsReadLocal(String id) async {
    final dao = localDao;
    if (dao == null) return;

    await dao.markAsRead(id);
    unawaited(_updateFirestoreState(id, {'isRead': true}));
  }

  Future<void> markAsCompletedLocal(String id) async {
    final dao = localDao;
    if (dao == null) return;

    await dao.markAsCompleted(id);
    unawaited(
      _updateFirestoreState(id, {
        'isRead': true,
        'isCompleted': true,
        'priority': 'completed',
      }),
    );
  }

  Future<void> deleteNotification(String id) async {
    final dao = localDao;
    if (dao == null) return;

    await dao.deleteNotification(id);
    unawaited(_deleteFromFirestore(id));
  }

  /// Hidrata o Drift a partir da nuvem sem destruir o estado local do usuário.
  ///
  /// isRead/isCompleted são monotônicos no modelo atual: a UI só transforma
  /// false -> true. Por isso usamos OR durante a hidratação.
  Future<void> syncNotificationsFromFirebaseToLocal() async {
    final user = auth.currentUser;
    final dao = localDao;
    if (user == null || dao == null) return;

    try {
      final snapshot = await firestore
          .collection('users')
          .doc(user.uid)
          .collection('notifications')
          .get();

      for (final doc in snapshot.docs) {
        final remote = NotificationModel.fromFirestore(doc);
        final local = await dao.getNotificationById(remote.id);

        final merged = remote.copyWith(
          isRead: local?.isRead == true || remote.isRead,
          isCompleted: local?.isCompleted == true || remote.isCompleted,
          createdAt: local?.createdAt ?? remote.createdAt,
        );

        await dao.upsertPreservingState(NotificationModel.toCompanion(merged));
      }

      AppLogger.i('SYNC Notificações: hidratação concluída.');
    } catch (error, stackTrace) {
      // O Drift continua sendo utilizável offline.
      AppLogger.e(
        'SYNC Notificações: erro ao hidratar do Firebase',
        error,
        stackTrace,
      );
    }
  }

  Future<void> _saveToFirestore(NotificationModel notification) async {
    final user = auth.currentUser;
    if (user == null) return;

    try {
      await firestore
          .collection('users')
          .doc(user.uid)
          .collection('notifications')
          .doc(notification.id)
          .set(notification.toFirestore(), SetOptions(merge: true));
    } catch (error, stackTrace) {
      AppLogger.e(
        'Erro ao sincronizar notificação com Firebase',
        error,
        stackTrace,
      );
    }
  }

  Future<void> _updateFirestoreState(
    String id,
    Map<String, Object?> data,
  ) async {
    final user = auth.currentUser;
    if (user == null) return;

    try {
      await firestore
          .collection('users')
          .doc(user.uid)
          .collection('notifications')
          .doc(id)
          .set({
            ...data,
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
    } catch (error, stackTrace) {
      AppLogger.e(
        'Erro ao sincronizar estado da notificação',
        error,
        stackTrace,
      );
    }
  }

  Future<void> _deleteFromFirestore(String id) async {
    final user = auth.currentUser;
    if (user == null) return;

    try {
      await firestore
          .collection('users')
          .doc(user.uid)
          .collection('notifications')
          .doc(id)
          .delete();
    } catch (error, stackTrace) {
      AppLogger.e('Erro ao excluir notificação do Firebase', error, stackTrace);
    }
  }
}

final notificationsRepositoryProvider = Provider<NotificationsRepository>((
  ref,
) {
  final db = ref.watch(databaseProvider);
  return NotificationsRepository(
    firestore: FirebaseFirestore.instance,
    auth: FirebaseAuth.instance,
    localDao: db.notificationDao,
  );
});
