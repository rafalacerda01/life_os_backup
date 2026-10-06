import 'dart:async';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/local_mutation_gate.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/core/database/database_provider.dart';
import 'package:life_os/core/services/sync_manager_provider.dart';
import 'notification_remote_effects_barrier.dart';
export 'notification_remote_effects_barrier.dart';
import 'package:life_os/core/utils/app_logger.dart';
import 'package:life_os/features/notifications/data/daos/notification_dao.dart';
import 'package:life_os/features/notifications/domain/models/notification_model.dart';

/// Repository Offline-First da Central de Notificações.
///
/// A UI lê do Drift. O Firestore é utilizado para sincronização remota.
/// Dispensas usam o Drift e a SyncQueue; demais efeitos preservam seu barrier.
class NotificationsRepository {
  final FirebaseFirestore firestore;
  final FirebaseAuth auth;
  final NotificationDao? localDao;
  final Future<void> Function(String expectedUid, String id)? remoteDelete;
  final NotificationRemoteEffectsBarrier remoteEffects;
  final Future<void> Function()? replayDeletes;

  NotificationsRepository({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
    this.localDao,
    this.remoteDelete,
    this.replayDeletes,
    NotificationRemoteEffectsBarrier? remoteEffects,
  }) : firestore = firestore ?? FirebaseFirestore.instance,
       auth = auth ?? FirebaseAuth.instance,
       remoteEffects = remoteEffects ?? NotificationRemoteEffectsBarrier();

  bool _canSend(String? expectedUid, int generation) =>
      expectedUid != null &&
      expectedUid.isNotEmpty &&
      auth.currentUser?.uid == expectedUid &&
      remoteEffects.isCurrent(generation);

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

  Future<List<NotificationModel>> getLocalNotifications() async {
    final dao = localDao;
    if (dao == null) return const [];

    final rows = await dao.getAllNotifications();
    return rows.map(NotificationModel.fromDrift).toList();
  }

  /// Salva primeiro no Drift e sincroniza em background.
  Future<void> saveLocalNotification(NotificationModel notification) {
    final expectedUid = auth.currentUser?.uid.trim();
    final generation = remoteEffects.generation;
    return remoteEffects.track(() async {
      final dao = localDao;
      if (dao == null) return;

      try {
        final shouldSync = await dao.upsertPreservingState(
          NotificationModel.toCompanion(notification),
        );

        if (shouldSync) {
          final persisted = await dao.getNotificationById(notification.id);
          if (persisted != null && _canSend(expectedUid, generation)) {
            unawaited(
              remoteEffects.track(
                () => _saveToFirestore(
                  expectedUid!,
                  NotificationModel.fromDrift(persisted),
                ),
              ),
            );
          }
        }
      } catch (error, stackTrace) {
        AppLogger.e('Erro ao salvar notificação localmente', error, stackTrace);
        rethrow;
      }
    });
  }

  Future<void> markAsReadLocal(String id) {
    final expectedUid = auth.currentUser?.uid.trim();
    final generation = remoteEffects.generation;
    return remoteEffects.track(() async {
      final dao = localDao;
      if (dao == null) return;

      await dao.markAsRead(id);
      if (_canSend(expectedUid, generation)) {
        unawaited(
          remoteEffects.track(
            () => _updateFirestoreState(expectedUid!, id, {'isRead': true}),
          ),
        );
      }
    });
  }

  Future<void> markAsCompletedLocal(String id) {
    final expectedUid = auth.currentUser?.uid.trim();
    final generation = remoteEffects.generation;
    return remoteEffects.track(() async {
      final dao = localDao;
      if (dao == null) return;

      await dao.markAsCompleted(id);
      if (_canSend(expectedUid, generation)) {
        unawaited(
          remoteEffects.track(
            () => _updateFirestoreState(expectedUid!, id, {
              'isRead': true,
              'isCompleted': true,
            }),
          ),
        );
      }
    });
  }

  /// User action: dismiss only the current occurrence, durably and offline.
  Future<void> deleteNotification(String id) {
    final expectedUid = auth.currentUser?.uid.trim();
    final generation = remoteEffects.generation;
    return remoteEffects.track(() async {
      final dao = localDao;
      if (dao == null) return;
      if (!_canSend(expectedUid, generation)) {
        throw const LocalMutationUnavailable();
      }
      await dao.dismissNotification(id, expectedUid!);
      if (_canSend(expectedUid, generation)) {
        // Queue processing has its own session fence and never gates logout.
        unawaited(
          replayDeletes?.call().catchError((Object _, StackTrace _) {}),
        );
      }
    });
  }

  /// Derived invalid state/category disabled, without a user dismissal.
  Future<void> deleteDerivedNotification(String id) {
    final expectedUid = auth.currentUser?.uid.trim();
    final generation = remoteEffects.generation;
    return remoteEffects.track(() async {
      final dao = localDao;
      if (dao == null) return;
      await dao.deleteNotification(id);
      if (_canSend(expectedUid, generation)) {
        unawaited(
          remoteEffects.track(() => _deleteFromFirestore(expectedUid!, id)),
        );
      }
    });
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
      final admission = dao.attachedDatabase.localMutations.capture(
        expectedUid: user.uid,
      );
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

        await dao.upsertPreservingState(
          NotificationModel.toCompanion(merged),
          admission: admission,
        );
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

  Future<void> _saveToFirestore(
    String expectedUid,
    NotificationModel notification,
  ) async {
    if (auth.currentUser?.uid != expectedUid) return;

    try {
      await firestore
          .collection('users')
          .doc(expectedUid)
          .collection('notifications')
          .doc(notification.id)
          .set(notification.toFirestore(), SetOptions(merge: true));
    } catch (_) {
      AppLogger.e('Erro ao sincronizar notificação com Firebase');
    }
  }

  Future<void> _updateFirestoreState(
    String expectedUid,
    String id,
    Map<String, Object?> data,
  ) async {
    if (auth.currentUser?.uid != expectedUid) return;

    try {
      if (await localDao?.getNotificationById(id) == null) return;
      if (auth.currentUser?.uid != expectedUid) return;
      await firestore
          .collection('users')
          .doc(expectedUid)
          .collection('notifications')
          .doc(id)
          .set({
            ...data,
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
    } catch (_) {
      AppLogger.e('Erro ao sincronizar estado da notificação');
    }
  }

  Future<void> _deleteFromFirestore(String expectedUid, String id) async {
    if (auth.currentUser?.uid != expectedUid) return;

    try {
      final override = remoteDelete;
      if (override != null) {
        await override(expectedUid, id);
        return;
      }
      await firestore
          .collection('users')
          .doc(expectedUid)
          .collection('notifications')
          .doc(id)
          .delete();
    } catch (_) {
      AppLogger.e('Erro ao excluir notificação do Firebase');
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
    remoteEffects: ref.watch(notificationRemoteEffectsBarrierProvider),
    replayDeletes: () async {
      await ref.read(syncManagerProvider).processPendingItems();
    },
  );
});
