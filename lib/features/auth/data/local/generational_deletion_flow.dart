import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../../core/database/local_account_session.dart';
import '../../../../core/database/local_database_identity.dart';
import '../../../../core/database/local_mutation_gate.dart';
import '../../../../core/database/session_database_coordinator.dart';
import '../../../../core/services/emulator_account_runtime.dart';
import '../../../../core/services/native_notification_registry.dart';
import '../../../../core/services/sync_manager.dart';
import '../remote/account_remote_data_source.dart';
import '../remote/account_deletion_recovery.dart';
import 'account_deletion_cleanup_barrier.dart';
import 'auth_cleanup_barrier.dart';
import 'generational_deletion_finalizer.dart';

enum GenerationalDeletionResolution {
  absent,
  preparationRecoverable,
  pending,
  retryReadOnly,
  assisted,
  completed,
}

/// Isolated integration entry. It does not open the notifier or Android routes.
final class GenerationalDeletionFlow {
  GenerationalDeletionFlow({
    required this._runtime,
    required this._secureStorage,
    required this._sessions,
    required this._databases,
    required this._finalizer,
  });

  final EmulatorAccountRuntime _runtime;
  final FlutterSecureStorage _secureStorage;
  final LocalAccountSession _sessions;
  final SessionDatabaseCoordinator _databases;
  final GenerationalDeletionFinalizer _finalizer;
  static const _wait = Duration(seconds: 20);
  static final _dispatching = <LocalDatabaseIdentity>{};

  Future<void> dispatch({
    required SyncManager sync,
    required Future<void> Function(User) reauthenticate,
  }) async {
    final lease = _sessions.capture();
    if (!_dispatching.add(lease.identity)) {
      throw StateError('LOCAL_DELETION_ALREADY_IN_PROGRESS');
    }
    try {
      await _dispatch(lease, sync, reauthenticate);
    } finally {
      _dispatching.remove(lease.identity);
    }
  }

  Future<void> _dispatch(
    LocalAccountLease lease,
    SyncManager sync,
    Future<void> Function(User) reauthenticate,
  ) async {
    final identity = lease.identity;
    final database = _databases.requirePrepared();
    final auth = _runtime.auth;
    final user = auth.currentUser;
    if (database.identity != identity ||
        !sync.isForDatabase(database) ||
        user == null ||
        user.uid != identity.uid) {
      throw StateError('LOCAL_DELETION_BINDING_INVALID');
    }
    final recovery = _runtime.deletionRecovery(identity, _secureStorage);
    final barrier = AccountDeletionCleanupBarrier(
      SecureAuthCleanupBarrierStorage(_secureStorage),
      identity: identity,
    );
    if (await barrier.readForUser(identity.uid) != null)
      throw StateError('ACCOUNT_DELETE_UNCONFIRMED');
    lease.requireCurrent();
    await reauthenticate(user).timeout(_wait);
    lease.requireCurrent();

    var changed = false;
    var sealed = false;
    var markerAttempted = false;
    final initialAuth = Completer<void>();
    void invalidateAuth() {
      changed = true;
      if (!initialAuth.isCompleted) initialAuth.complete();
    }

    final subscription = auth.authStateChanges().listen(
      (observed) {
        if (initialAuth.isCompleted || observed?.uid != identity.uid)
          changed = true;
        if (!initialAuth.isCompleted) initialAuth.complete();
      },
      onError: (Object _) => invalidateAuth(),
      onDone: invalidateAuth,
    );

    void requireCurrent() {
      if (changed ||
          auth.currentUser?.uid != identity.uid ||
          !(sealed ? _sessions.isClearedAfter(lease) : lease.isCurrent)) {
        throw StateError('LOCAL_DELETION_SESSION_CHANGED');
      }
    }

    try {
      await initialAuth.future.timeout(_wait);
      requireCurrent();
      LocalMutationQuiescence? activeQuiescence;
      try {
        if (!await sync.prepareForSessionDetach(identity.uid).timeout(_wait)) {
          throw StateError('LOCAL_DELETION_SYNC_NOT_DRAINED');
        }
        requireCurrent();
        final quiescence = database.localMutations.beginQuiesce(identity.uid);
        activeQuiescence = quiescence;
        await quiescence.drain().timeout(_wait);
        requireCurrent();
        final revision = await recovery.reserveDispatch();
        requireCurrent();
        markerAttempted = true;
        final marker = await barrier.request(
          identity.uid,
          reusePending: false,
          reservedRevision: revision,
        );
        final remote = GenerationalAccountRemoteDataSource(
          baseUri: _runtime.baseUri,
          client: _runtime.client,
          appCheckToken: _runtime.appCheckToken,
        );
        await remote.submit(
          identity: identity,
          fenceDispatch: () => recovery.fenceDispatch(marker),
          user: auth.currentUser!,
          requireCurrent: requireCurrent,
          beforeSend: () async {
            requireCurrent();
            quiescence.finish(signOutConfirmed: false, keepSealed: true);
            _sessions.clearIfCurrent(identity);
            sealed = true;
            await NativeNotificationEffectGate.run(() async {});
          },
        );
      } finally {
        activeQuiescence?.finish(
          signOutConfirmed: false,
          keepSealed: markerAttempted || changed || !lease.isCurrent,
        );
        if (markerAttempted && lease.isCurrent)
          _sessions.clearIfCurrent(identity);
        if (!markerAttempted && lease.isCurrent && !changed)
          sync.resumeForPreparedSession(identity.uid);
      }
    } finally {
      await subscription.cancel();
    }
  }

  Future<bool> recoverAndFinalize(LocalDatabaseIdentity identity) async =>
      await resolve(identity) == GenerationalDeletionResolution.completed;

  Future<bool> resetUnsent(LocalDatabaseIdentity identity) async {
    if (!_dispatching.add(identity)) return false;
    try {
      return await _runtime
          .deletionRecovery(identity, _secureStorage)
          .resetUnsent();
    } finally {
      _dispatching.remove(identity);
    }
  }

  Future<GenerationalDeletionResolution> resolve(
    LocalDatabaseIdentity identity,
  ) async {
    final recovery = _runtime.deletionRecovery(identity, _secureStorage);
    if (await _finalizer.finish(identity))
      return GenerationalDeletionResolution.completed;
    final barrier = AccountDeletionCleanupBarrier(
      SecureAuthCleanupBarrierStorage(_secureStorage),
      identity: identity,
    );
    final marker = await barrier.readForUser(identity.uid);
    switch (await recovery.preparation(marker)) {
      case DeletionPreparation.absent:
        return GenerationalDeletionResolution.absent;
      case DeletionPreparation.unsent:
        return GenerationalDeletionResolution.preparationRecoverable;
      case DeletionPreparation.inconsistent:
        return GenerationalDeletionResolution.assisted;
      case DeletionPreparation.fenced:
        final result = await recovery.recover();
        final proof = result.proof;
        if (proof != null && await _finalizer.finish(identity, proof: proof)) {
          return GenerationalDeletionResolution.completed;
        }
        return switch (result.state) {
          DeletionRecoveryState.pending =>
            GenerationalDeletionResolution.pending,
          DeletionRecoveryState.unavailable =>
            GenerationalDeletionResolution.retryReadOnly,
          _ => GenerationalDeletionResolution.assisted,
        };
    }
  }
}
