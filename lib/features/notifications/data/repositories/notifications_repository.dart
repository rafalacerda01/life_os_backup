import 'package:life_os/core/services/generational_read_policy.dart';
import 'dart:async';
import 'package:life_os/core/database/local_account_session.dart';
import 'package:life_os/core/services/firebase_auth_provider.dart';
import 'package:life_os/core/services/emulator_account_runtime.dart';
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
import 'package:life_os/features/notifications/domain/models/notification_occurrence.dart';
import 'package:life_os/features/notifications/domain/services/notification_module_reconciler.dart';

/// Repository Offline-First da Central de Notificações.
///
/// A UI lê do Drift. O Firestore é utilizado para sincronização remota.
/// Dispensas usam o Drift e a SyncQueue; demais efeitos preservam seu barrier.
class NotificationsRepository implements NotificationDerivationStore {
  final LocalAccountLease? sessionLease;
  final bool readAndDismissOnly;
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
    this.sessionLease,
    this.readAndDismissOnly = false,
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
    if (readAndDismissOnly) throw StateError('NOTIFICATION_SDK_LISTENER_CLOSED');
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

  @override
  Future<List<NotificationModel>> getLocalNotifications() async {
    final dao = localDao;
    if (dao == null) return const [];

    final rows = await dao.getAllNotifications();
    return rows.map(NotificationModel.fromDrift).toList();
  }

  /// Salva primeiro no Drift e sincroniza em background.
  @override
  Future<void> saveLocalNotification(NotificationModel notification) {
    if (readAndDismissOnly) throw StateError('NOTIFICATION_WRITER_CLOSED');
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
    if (readAndDismissOnly) throw StateError('NOTIFICATION_WRITER_CLOSED');
    final expectedUid = auth.currentUser?.uid.trim();
    final generation = remoteEffects.generation;
    return remoteEffects.track(() async {
      final dao = localDao;
      if (dao == null) return;

      final occurrenceKey = await dao.markAsRead(id);
      if (occurrenceKey != null && _canSend(expectedUid, generation)) {
        unawaited(
          remoteEffects.track(
            () => _updateFirestoreState(
              expectedUid!,
              generation,
              id,
              occurrenceKey,
              {'isRead': true},
            ),
          ),
        );
      }
    });
  }

  Future<void> markAsCompletedLocal(String id) {
    if (readAndDismissOnly) throw StateError('NOTIFICATION_WRITER_CLOSED');
    final expectedUid = auth.currentUser?.uid.trim();
    final generation = remoteEffects.generation;
    return remoteEffects.track(() async {
      final dao = localDao;
      if (dao == null) return;

      final occurrenceKey = await dao.markAsCompleted(id);
      if (occurrenceKey != null && _canSend(expectedUid, generation)) {
        unawaited(
          remoteEffects.track(
            () => _updateFirestoreState(
              expectedUid!,
              generation,
              id,
              occurrenceKey,
              {'isRead': true, 'isCompleted': true},
            ),
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
  @override
  Future<void> deleteDerivedNotification(String id) {
    if (readAndDismissOnly) throw StateError('NOTIFICATION_WRITER_CLOSED');
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
      await GenerationalReadPolicy.verify(identity:dao.attachedDatabase.identity,lease:sessionLease,auth:auth,store:firestore,expectedUid:user.uid);
      final snapshot = await firestore
          .collection('users')
          .doc(user.uid)
          .collection('notifications')
          .get(
            GenerationalReadPolicy.options(
              dao.attachedDatabase.identity,
              firestore,
            ),
          );
      if (dao.attachedDatabase.identity?.generation != null &&
          !GenerationalReadPolicy.accepts(
            dao.attachedDatabase.identity,
            fromCache: snapshot.metadata.isFromCache,
            pendingWrites: snapshot.metadata.hasPendingWrites,
          )) {
        throw StateError('GENERATIONAL_SNAPSHOT_UNCONFIRMED');
      }

      await GenerationalReadPolicy.verify(identity:dao.attachedDatabase.identity,lease:sessionLease,auth:auth,store:firestore,expectedUid:user.uid);
      Future<void> mergeSnapshot() async {
      for (final doc in snapshot.docs) {
        final remote = NotificationModel.fromFirestore(doc);
        await dao.upsertFromRemote(
          NotificationModel.toCompanion(remote),
          admission: admission,
        );
      }

      }
      if (dao.attachedDatabase.identity?.generation != null) {
        await dao.attachedDatabase.transactionWithCommitGuard(mergeSnapshot,admission:admission,waitForReopen:false,validateBeforeCommit:()=>GenerationalReadPolicy.requireCurrent(identity:dao.attachedDatabase.identity,lease:sessionLease,auth:auth,expectedUid:user.uid));
      } else {
        // The historical unbound store retains per-row merge concurrency.
        // This branch grants no admission to the always-bound local runtime.
        await mergeSnapshot();
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
    int generation,
    String id,
    String occurrenceKey,
    Map<String, Object?> data,
  ) async {
    if (!_canSend(expectedUid, generation)) return;

    try {
      final reference = firestore
          .collection('users')
          .doc(expectedUid)
          .collection('notifications')
          .doc(id);
      await firestore.runTransaction<void>((transaction) async {
        if (!_canSend(expectedUid, generation)) return;
        final snapshot = await transaction.get(reference);
        if (!snapshot.exists) return;
        final remote = snapshot.data();
        final moduleType = remote?['moduleType'];
        final dueDate = remote?['dueDate'];
        if (moduleType is! String || dueDate is! Timestamp) return;
        final remoteKey = NotificationOccurrence.key(
          id: id,
          moduleType: moduleType,
          dueDate: dueDate.toDate(),
        );
        if (remoteKey != occurrenceKey || !_canSend(expectedUid, generation)) {
          return;
        }
        // Only remote state is touched: SDK retries re-read identity and fences.
        transaction.update(reference, {
          ...data,
          'updatedAt': FieldValue.serverTimestamp(),
        });
      });
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
    firestore: ref.watch(firebaseFirestoreProvider),
    auth: ref.watch(firebaseAuthProvider),
    localDao: db.notificationDao,
    sessionLease:ref.watch(localAccountSessionProvider).identity==null?null:ref.read(localAccountSessionProvider.notifier).capture(),
    readAndDismissOnly:ref.watch(emulatorAccountRuntimeProvider)!=null,
    remoteEffects: ref.watch(notificationRemoteEffectsBarrierProvider),
    replayDeletes: () async {
      await ref.read(syncManagerProvider).processPendingItems();
    },
  );
});

final localNotificationInboxProvider = StreamProvider.autoDispose((ref)=>ref.watch(notificationsRepositoryProvider).watchLocalNotifications());
