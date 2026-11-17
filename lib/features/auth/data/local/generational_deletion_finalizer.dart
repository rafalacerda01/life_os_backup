import 'dart:async';

import '../../../../core/database/local_account_session.dart';
import '../../../../core/database/local_database_identity.dart';
import '../../../../core/database/session_database_coordinator.dart';
import '../../../../core/storage/generational_cleanup.dart';
import '../remote/account_deletion_recovery.dart';
import 'account_deletion_cleanup_barrier.dart';
import 'account_deletion_storage_cleanup.dart';
import 'auth_cleanup_barrier.dart';

/// Finalizes only a captured generation. It never consults Firebase Auth or
/// dispatches a remote operation. The caller keeps the feature guards in force.
final class GenerationalDeletionFinalizer {
  GenerationalDeletionFinalizer({
    required this._journal,
    required this._markerStorage,
    required this._sessions,
    required this._databases,
    required this._storageCleanup,
  });

  final GenerationalCleanupJournal _journal;
  final AuthCleanupBarrierStorage _markerStorage;
  final LocalAccountSession _sessions;
  final SessionDatabaseCoordinator _databases;
  final AccountDeletionStorageCleanup _storageCleanup;
  static const _plan = ['drain', 'local_storage'];
  static final _tails = <LocalDatabaseIdentity, Future<void>>{};

  Future<bool> finish(
    LocalDatabaseIdentity identity, {
    RecoveredDeletionProof? proof,
  }) {
    if (!identity.isBound || (proof != null && proof.identity != identity)) {
      throw StateError('DELETION_FINALIZATION_BINDING_MISMATCH');
    }
    final result = (_tails[identity] ?? Future<void>.value()).then(
      (_) => _finish(identity, proof),
    );
    final tail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _tails[identity] = tail;
    unawaited(
      tail.whenComplete(() {
        if (identical(_tails[identity], tail)) _tails.remove(identity);
      }),
    );
    return result;
  }

  Future<bool> _finish(
    LocalDatabaseIdentity identity,
    RecoveredDeletionProof? proof,
  ) async {
    final barrier = AccountDeletionCleanupBarrier(
      _markerStorage,
      identity: identity,
    );
    final marker = await barrier.readForUser(identity.uid);
    var current = await _journal.read(identity);
    if (current?.operationId != null &&
        proof != null &&
        (current!.operationId != proof.operationId ||
            current.markerRevision != proof.markerRevision)) {
      throw StateError('DELETION_FINALIZATION_OPERATION_MISMATCH');
    }
    if (marker == null)
      return current?.operationId != null && current!.isComplete;
    if (marker.identity != identity ||
        marker.phase != AccountDeletionPhase.requested ||
        (proof != null && proof.markerRevision != marker.revision) ||
        (current?.operationId != null &&
            current!.markerRevision != marker.revision)) {
      throw StateError('DELETION_FINALIZATION_MARKER_MISMATCH');
    }

    if (current?.operationId == null) {
      if (proof == null) return false;
      current ??= await _journal.request(identity, plan: _plan);
      current = await _journal.confirmOriginalResponse(current, proof: proof);
    }

    Future<void> drain(
      LocalDatabaseIdentity target,
      Future<void> Function() effect,
    ) async {
      if (await barrier.readForUser(target.uid) != marker) {
        throw StateError('DELETION_FINALIZATION_MARKER_MISMATCH');
      }
      _sessions.clearIfCurrent(target);
      await _databases.destroy(target, effect);
    }

    final completed = await _journal.resume(current!, {
      'drain': (target) => drain(target, () async {}),
      'local_storage': (target) =>
          drain(target, () => _storageCleanup.destroy(target)),
    });
    if (!completed.isComplete || !await barrier.clearIfCurrent(marker)) {
      throw StateError('DELETION_FINALIZATION_MARKER_NOT_CLEARED');
    }
    return true;
  }
}
