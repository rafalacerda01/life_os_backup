import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/local_mutation_gate.dart';
import 'package:life_os/core/database/remote_send_permit.dart';
import 'package:life_os/features/health/data/local/water_v2_local_store.dart';

import 'sync_operation_result.dart';
import 'water_v2_remote_data_source.dart';

/// Test-injected infrastructure only. No provider or gesture creates V2 work.
final class WaterV2SyncProcessor {
  WaterV2SyncProcessor.forLocalTests(
    this._db,
    this._remote, {
    DateTime Function()? now,
  }) : _store = WaterV2LocalStore(_db),
       _now = now ?? DateTime.now,
       _lane = _lanes[_db] ??= _WaterV2Lane();
  final AppDatabase _db;
  final WaterV2LocalStore _store;
  final WaterV2RemoteDataSource _remote;
  final DateTime Function() _now;
  // Weak, database-scoped ownership: independent test managers cannot run
  // overlapping attempts for the same durable namespace.
  static final _lanes = Expando<_WaterV2Lane>();
  final _WaterV2Lane _lane;

  Future<SyncOperationResult> process(
    String uid,
    SyncQueueTableData item, {
    required bool Function() canSend,
  }) => _admitted(uid, canSend, (ticket, permit) async {
    final request = await _store.prepareIncrement(
      uid,
      item,
      admission: ticket,
      permit: permit,
    );
    if (request == null) return const SyncOperationResult.success();
    final result = await _remote.increment(request, permit);
    permit.requireCurrent();
    if (result.value == null) return result.error!;
    await _store.acknowledgeIncrement(
      result.value!,
      admission: ticket,
      permit: permit,
      observedAtUtc: _observedAtUtc(),
    );
    return const SyncOperationResult.success();
  });

  /// Explicit test action; no provider, timer or manager automatically calls it.
  Future<SyncOperationResult> reconcileDay(
    String uid,
    String healthDay, {
    required bool Function() canSend,
  }) => _admitted(uid, canSend, (ticket, permit) async {
    final plan = await _store.prepareReconciliation(
      uid,
      healthDay,
      admission: ticket,
      permit: permit,
    );
    if (plan == null) return const SyncOperationResult.success();
    final result = await _remote.reconcile(plan.request, permit);
    permit.requireCurrent();
    if (result.value == null) return result.error!;
    await _store.acknowledgeReconciliation(
      result.value!,
      plan: plan,
      admission: ticket,
      permit: permit,
      observedAtUtc: _observedAtUtc(),
    );
    return const SyncOperationResult.success();
  });

  String _observedAtUtc() => DateTime.fromMillisecondsSinceEpoch(
    _now().millisecondsSinceEpoch,
    isUtc: true,
  ).toIso8601String();

  Future<SyncOperationResult> _admitted(
    String uid,
    bool Function() canSend,
    Future<SyncOperationResult> Function(LocalMutationTicket, RemoteSendPermit)
    action,
  ) async {
    if (!_remote.isEnabled)
      return const SyncOperationResult.retryable(code: 'WATER_V2_DISABLED');
    late final LocalMutationTicket ticket;
    late final RemoteSendPermit permit;
    try {
      ticket = _db.localMutations.capture(expectedUid: uid);
      permit = _remote.capturePermit(uid, canSend);
      permit.requireCurrent();
    } catch (_) {
      return const SyncOperationResult.retryable(code: 'SESSION_STOPPED');
    }
    final preceding = _lane.tail;
    late final Future<SyncOperationResult> operation;
    operation = () async {
      await preceding;
      try {
        // Retain admission captured before waiting: logout cannot revive it.
        permit.requireCurrent();
        return await action(ticket, permit);
      } on RemoteSessionStopped {
        return const SyncOperationResult.retryable(code: 'SESSION_STOPPED');
      } on LocalMutationUnavailable {
        return const SyncOperationResult.retryable(code: 'SESSION_STOPPED');
      } on StateError catch (error) {
        const codes = {
          'WATER_ORIGIN_REQUIRED',
          'WATER_STATE_REQUIRED',
          'WATER_QUEUE_CONFLICT',
          'WATER_MUTATION_CONFLICT',
          'WATER_EPOCH_CONFLICT',
          'WATER_REVISION_REGRESSION',
          'WATER_SNAPSHOT_CONFLICT',
          'WATER_RECONCILIATION_REQUIRED',
          'WATER_RECONCILIATION_LIMIT',
          'WATER_PROJECTION_REQUIRED',
        };
        return SyncOperationResult.retryable(
          code: codes.contains(error.message)
              ? error.message
              : 'WATER_LOCAL_ACK_FAILED',
        );
      } catch (_) {
        return const SyncOperationResult.retryable(
          code: 'WATER_LOCAL_ACK_FAILED',
        );
      }
    }();
    _lane.tail = operation.then<void>((_) {});
    return operation;
  }
}

class _WaterV2Lane {
  Future<void> tail = Future.value();
}
