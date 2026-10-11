import 'package:drift/drift.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/local_mutation_gate.dart';
import 'package:life_os/core/database/remote_send_permit.dart';
import 'package:life_os/core/services/water_v2_contract.dart';
import 'package:life_os/features/health/data/local/water_v2_tables.dart';

/// Captured values supplied by the future gesture/provisioning integration.
/// This store generates no UUID, reads no legacy total, and performs no network.
final class WaterV2IntentInput {
  const WaterV2IntentInput({
    required this.ownerUid,
    required this.mutationId,
    required this.healthDay,
    required this.deltaMl,
    required this.occurredAtUtc,
    required this.timeZoneOffsetMinutes,
    this.originEpoch,
  });

  final String ownerUid;
  final String mutationId;
  final String healthDay;
  final int deltaMl;
  final String occurredAtUtc;
  final int timeZoneOffsetMinutes;
  final String? originEpoch;
}

/// Local persistence plus distinct increment and reconciliation ACKs. No API creates an intent's
/// queue link, performs network, adopts an epoch, or converts a legacy operation.
final class WaterV2LocalStore {
  const WaterV2LocalStore(this._db);

  final AppDatabase _db;
  static final _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );
  static final _day = RegExp(r'^\d{4}-\d{2}-\d{2}$');
  static final _utc = RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$');

  void _owner(String uid) {
    if (uid.isEmpty ||
        uid.length > 128 ||
        uid != uid.trim() ||
        uid.contains('/') ||
        uid == '.' ||
        uid == '..') {
      throw ArgumentError('WATER_OWNER_INVALID');
    }
    if (_db.identity != null && _db.identity!.uid != uid) {
      throw const LocalMutationUnavailable();
    }
  }

  void _validateDay(String value) {
    final date = DateTime.tryParse('${value}T00:00:00.000Z');
    if (!_day.hasMatch(value) ||
        date == null ||
        date.year < 1 ||
        date.toIso8601String() != '${value}T00:00:00.000Z') {
      throw ArgumentError('WATER_DAY_INVALID');
    }
  }

  DateTime _validateUtc(String value) {
    final date = DateTime.tryParse(value);
    if (!_utc.hasMatch(value) ||
        date == null ||
        !date.isUtc ||
        date.toIso8601String() != value) {
      throw ArgumentError('WATER_TIMESTAMP_INVALID');
    }
    return date;
  }

  void _validateUuid(String value) {
    if (!_uuid.hasMatch(value)) throw ArgumentError('WATER_UUID_INVALID');
  }

  LocalMutationTicket _admit(String ownerUid, LocalMutationTicket? admission) {
    _owner(ownerUid);
    // Validate the requested owner even when a caller supplies an old ticket.
    final current = _db.localMutations.capture(expectedUid: ownerUid);
    return admission ?? current;
  }

  Future<void> _requireEpoch(String ownerUid, String epoch) async {
    final otherState =
        await (_db.select(_db.waterV2DailyStates)
              ..where(
                (t) =>
                    t.ownerUid.equals(ownerUid) & t.epoch.equals(epoch).not(),
              )
              ..limit(1))
            .getSingleOrNull();
    final otherIntent =
        await (_db.select(_db.waterV2Intents)
              ..where(
                (t) =>
                    t.ownerUid.equals(ownerUid) &
                    t.originEpoch.isNotNull() &
                    t.originEpoch.equals(epoch).not(),
              )
              ..limit(1))
            .getSingleOrNull();
    if (otherState != null || otherIntent != null) {
      throw StateError('WATER_EPOCH_CONFLICT');
    }
  }

  Future<WaterV2Intent> insertIntent(
    WaterV2IntentInput intent, {
    LocalMutationTicket? admission,
  }) {
    _validateUuid(intent.mutationId);
    _validateDay(intent.healthDay);
    final instant = _validateUtc(intent.occurredAtUtc);
    if (intent.deltaMl != 250 ||
        intent.timeZoneOffsetMinutes < -840 ||
        intent.timeZoneOffsetMinutes > 840) {
      throw ArgumentError('WATER_INCREMENT_INVALID');
    }
    final local = instant.add(Duration(minutes: intent.timeZoneOffsetMinutes));
    final localDay =
        '${local.year.toString().padLeft(4, '0')}-'
        '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
    if (localDay != intent.healthDay)
      throw ArgumentError('WATER_DAY_OFFSET_MISMATCH');
    if (intent.originEpoch != null) _validateUuid(intent.originEpoch!);
    final ticket = _admit(intent.ownerUid, admission);
    return _db.transaction(
      () async {
        final existing =
            await (_db.select(_db.waterV2Intents)..where(
                  (t) =>
                      t.ownerUid.equals(intent.ownerUid) &
                      t.mutationId.equals(intent.mutationId),
                ))
                .getSingleOrNull();
        if (existing != null) {
          if (existing.healthDay != intent.healthDay ||
              existing.deltaMl != intent.deltaMl ||
              existing.occurredAtUtc != intent.occurredAtUtc ||
              existing.timeZoneOffsetMinutes != intent.timeZoneOffsetMinutes ||
              existing.originEpoch != intent.originEpoch) {
            throw StateError('WATER_MUTATION_CONFLICT');
          }
          // Retry preserves the row, delivery state, original epoch and linkage.
          if (intent.originEpoch != null)
            await _requireEpoch(intent.ownerUid, intent.originEpoch!);
          return existing;
        }
        if (intent.originEpoch != null)
          await _requireEpoch(intent.ownerUid, intent.originEpoch!);
        await _db
            .into(_db.waterV2Intents)
            .insert(
              WaterV2IntentsCompanion.insert(
                ownerUid: intent.ownerUid,
                mutationId: intent.mutationId,
                healthDay: intent.healthDay,
                deltaMl: intent.deltaMl,
                occurredAtUtc: intent.occurredAtUtc,
                timeZoneOffsetMinutes: intent.timeZoneOffsetMinutes,
                originEpoch: Value(intent.originEpoch),
                localStatus: Value(
                  intent.originEpoch == null
                      ? WaterV2IntentStatus.unreconciled
                      : WaterV2IntentStatus.notSent,
                ),
              ),
            );
        return (_db.select(_db.waterV2Intents)..where(
              (t) =>
                  t.ownerUid.equals(intent.ownerUid) &
                  t.mutationId.equals(intent.mutationId),
            ))
            .getSingle();
      },
      admission: ticket,
      waitForReopen: false,
    );
  }

  Future<List<WaterV2Intent>> readIntents({
    required String ownerUid,
    required String healthDay,
  }) {
    _validateDay(healthDay);
    final ticket = _admit(ownerUid, null);
    return _db.transaction(
      () =>
          (_db.select(_db.waterV2Intents)
                ..where(
                  (t) =>
                      t.ownerUid.equals(ownerUid) &
                      t.healthDay.equals(healthDay),
                )
                ..orderBy([
                  (t) => OrderingTerm.asc(t.occurredAtUtc),
                  (t) => OrderingTerm.asc(t.mutationId),
                ]))
              .get(),
      admission: ticket,
      waitForReopen: false,
    );
  }

  /// Caller must supply a trusted, complete remote snapshot in the future.
  /// Persisting a snapshot is neither activation nor an ACK of any local intent.
  Future<WaterV2DailyState> persistConfirmedState({
    required String ownerUid,
    required String healthDay,
    required String epoch,
    required int revision,
    required int confirmedWaterIntakeMl,
    required String reconciledAtUtc,
    LocalMutationTicket? admission,
  }) {
    _validateDay(healthDay);
    _validateUuid(epoch);
    _validateUtc(reconciledAtUtc);
    if (revision < 0 ||
        revision > 9007199254740991 ||
        confirmedWaterIntakeMl < 0 ||
        confirmedWaterIntakeMl > 1000000) {
      throw ArgumentError('WATER_CONFIRMED_STATE_INVALID');
    }
    final ticket = _admit(ownerUid, admission);
    return _db.transaction(
      () async {
        await _requireEpoch(ownerUid, epoch);
        final current =
            await (_db.select(_db.waterV2DailyStates)..where(
                  (t) =>
                      t.ownerUid.equals(ownerUid) &
                      t.healthDay.equals(healthDay),
                ))
                .getSingleOrNull();
        if (current != null) {
          if (revision < current.revision)
            throw StateError('WATER_REVISION_REGRESSION');
          if ((revision == current.revision &&
                  confirmedWaterIntakeMl != current.confirmedWaterIntakeMl) ||
              confirmedWaterIntakeMl < current.confirmedWaterIntakeMl) {
            throw StateError('WATER_SNAPSHOT_CONFLICT');
          }
        }
        await _db
            .into(_db.waterV2DailyStates)
            .insertOnConflictUpdate(
              WaterV2DailyStatesCompanion.insert(
                ownerUid: ownerUid,
                healthDay: healthDay,
                epoch: epoch,
                revision: revision,
                confirmedWaterIntakeMl: confirmedWaterIntakeMl,
                reconciledAtUtc: reconciledAtUtc,
              ),
            );
        return (_db.select(_db.waterV2DailyStates)..where(
              (t) =>
                  t.ownerUid.equals(ownerUid) & t.healthDay.equals(healthDay),
            ))
            .getSingle();
      },
      admission: ticket,
      waitForReopen: false,
    );
  }

  /// Atomically validate the explicit queue link and mark the attempt uncertain
  /// before any network preflight. A lost response must never leave not_sent.
  Future<WaterV2IncrementRequest?> prepareIncrement(
    String ownerUid,
    SyncQueueTableData item, {
    required LocalMutationTicket admission,
    required RemoteSendPermit permit,
  }) {
    final ticket = _admit(ownerUid, admission);
    return _db.transactionWithCommitGuard(
      () async {
        permit.requireCurrent();
        final row =
            await (_db.select(_db.waterV2Intents)..where(
                  (t) =>
                      t.ownerUid.equals(ownerUid) &
                      t.mutationId.equals(item.docId),
                ))
                .getSingleOrNull();
        if (row == null || row.originEpoch == null)
          throw StateError('WATER_ORIGIN_REQUIRED');
        final request = WaterV2IncrementRequest.fromIntent(row);
        final queue = await _linkedQueue(row, request);
        if (queue.id != item.id || !request.matchesQueue(item))
          throw StateError('WATER_QUEUE_CONFLICT');
        final state =
            await (_db.select(_db.waterV2DailyStates)..where(
                  (t) =>
                      t.ownerUid.equals(ownerUid) &
                      t.healthDay.equals(row.healthDay),
                ))
                .getSingleOrNull();
        if (state == null || state.epoch != row.originEpoch)
          throw StateError('WATER_STATE_REQUIRED');
        await _requireEpoch(ownerUid, row.originEpoch!);
        if (row.localStatus == WaterV2IntentStatus.receiptConfirmed &&
            queue.status == SyncQueuePersistenceStatus.succeeded)
          return null;
        if (queue.status != SyncQueuePersistenceStatus.pending ||
            row.localStatus == WaterV2IntentStatus.receiptConfirmed)
          throw StateError('WATER_QUEUE_CONFLICT');
        await (_db.update(_db.waterV2Intents)..where(
              (t) =>
                  t.ownerUid.equals(ownerUid) &
                  t.mutationId.equals(row.mutationId),
            ))
            .write(
              const WaterV2IntentsCompanion(
                localStatus: Value(WaterV2IntentStatus.unreconciled),
              ),
            );
        permit.requireCurrent();
        return request;
      },
      admission: ticket,
      waitForReopen: false,
      validateBeforeCommit: permit.requireCurrent,
    );
  }

  Future<SyncQueueTableData> _linkedQueue(
    WaterV2Intent row,
    WaterV2IncrementRequest request,
  ) async {
    if (row.syncQueueId == null) throw StateError('WATER_QUEUE_CONFLICT');
    final queue = await (_db.select(
      _db.syncQueueTable,
    )..where((t) => t.id.equals(row.syncQueueId!))).getSingleOrNull();
    if (queue == null || !request.matchesQueue(queue))
      throw StateError('WATER_QUEUE_CONFLICT');
    return queue;
  }

  /// Only direct increment evidence is accepted. Reconciliation has its own ACK.
  Future<void> acknowledgeIncrement(
    WaterV2IncrementSuccess success, {
    required LocalMutationTicket admission,
    required RemoteSendPermit permit,
    required String observedAtUtc,
  }) {
    _validateUtc(observedAtUtc);
    // The response retains its original remote admission. A caller cannot
    // revive old evidence by supplying a new permit after aborted logout.
    final boundPermit = success.remotePermit.and(() => permit.isCurrent);
    final request = success.request;
    final ticket = _admit(request.ownerUid, admission);
    return _db.transactionWithCommitGuard(
      () async {
        boundPermit.requireCurrent();
        final row =
            await (_db.select(_db.waterV2Intents)..where(
                  (t) =>
                      t.ownerUid.equals(request.ownerUid) &
                      t.mutationId.equals(request.mutationId),
                ))
                .getSingleOrNull();
        if (row == null ||
            !request.matches(row) ||
            row.originEpoch == null ||
            row.originEpoch != success.epoch)
          throw StateError('WATER_MUTATION_CONFLICT');
        final queue = await _linkedQueue(row, request);
        final prior =
            await (_db.select(_db.waterV2DailyStates)..where(
                  (t) =>
                      t.ownerUid.equals(request.ownerUid) &
                      t.healthDay.equals(request.healthDay),
                ))
                .getSingleOrNull();
        if (prior == null || prior.epoch != success.epoch)
          throw StateError('WATER_EPOCH_CONFLICT');
        if (success.revision < prior.revision)
          throw StateError('WATER_REVISION_REGRESSION');
        if (success.waterIntakeMl < prior.confirmedWaterIntakeMl ||
            (success.revision == prior.revision &&
                success.waterIntakeMl != prior.confirmedWaterIntakeMl))
          throw StateError('WATER_SNAPSHOT_CONFLICT');
        if (row.localStatus == WaterV2IntentStatus.receiptConfirmed &&
            queue.status == SyncQueuePersistenceStatus.succeeded) {
          boundPermit.requireCurrent();
          return; // Replay of an already durable ACK never changes its projection.
        }
        if (row.localStatus != WaterV2IntentStatus.unreconciled ||
            queue.status != SyncQueuePersistenceStatus.pending)
          throw StateError('WATER_QUEUE_CONFLICT');
        final others =
            await (_db.select(_db.waterV2Intents)..where(
                  (t) =>
                      t.ownerUid.equals(request.ownerUid) &
                      t.healthDay.equals(request.healthDay) &
                      t.mutationId.equals(request.mutationId).not(),
                ))
                .get();
        var remainingMl = 0;
        for (final other in others) {
          if (other.originEpoch != success.epoch)
            throw StateError('WATER_EPOCH_CONFLICT');
          if (other.localStatus == WaterV2IntentStatus.receiptConfirmed)
            continue;
          // A snapshot may already include an uncertain operation. Do not guess
          // its membership, discard it, or partially ACK the current operation.
          if (other.localStatus != WaterV2IntentStatus.notSent)
            throw StateError('WATER_RECONCILIATION_REQUIRED');
          final linked = await _linkedQueue(
            other,
            WaterV2IncrementRequest.fromIntent(other),
          );
          if (linked.status != SyncQueuePersistenceStatus.pending ||
              linked.attemptCount != 0)
            throw StateError('WATER_RECONCILIATION_REQUIRED');
          remainingMl += other.deltaMl;
        }
        final health = await (_db.select(
          _db.healthEntries,
        )..where((t) => t.docId.equals(request.healthDay))).getSingleOrNull();
        if (health == null) throw StateError('WATER_PROJECTION_REQUIRED');
        boundPermit.requireCurrent();
        await persistConfirmedState(
          ownerUid: request.ownerUid,
          healthDay: request.healthDay,
          epoch: success.epoch,
          revision: success.revision,
          confirmedWaterIntakeMl: success.waterIntakeMl,
          reconciledAtUtc: observedAtUtc,
          admission: ticket,
        );
        await (_db.update(_db.waterV2Intents)..where(
              (t) =>
                  t.ownerUid.equals(request.ownerUid) &
                  t.mutationId.equals(request.mutationId),
            ))
            .write(
              const WaterV2IntentsCompanion(
                localStatus: Value(WaterV2IntentStatus.receiptConfirmed),
              ),
            );
        await (_db.update(_db.syncQueueTable)..where(
              (t) =>
                  t.id.equals(queue.id) & t.ownerUid.equals(request.ownerUid),
            ))
            .write(
              SyncQueueTableCompanion(
                status: const Value(SyncQueuePersistenceStatus.succeeded),
                isSynced: const Value(true),
                lastErrorCode: const Value(null),
                attemptCount: Value(queue.attemptCount + 1),
                lastAttemptAt: Value(
                  DateTime.parse(observedAtUtc).millisecondsSinceEpoch,
                ),
              ),
            );
        await (_db.update(
          _db.healthEntries,
        )..where((t) => t.docId.equals(request.healthDay))).write(
          HealthEntriesCompanion(
            waterIntakeMl: Value(
              (success.waterIntakeMl + remainingMl).clamp(0, 1000000),
            ),
          ),
        );
        boundPermit.requireCurrent();
      },
      admission: ticket,
      waitForReopen: false,
      validateBeforeCommit: boundPermit.requireCurrent,
    );
  }

  /// Capture one complete local set; never page across different remote snapshots.
  Future<WaterV2ReconcilePlan?> prepareReconciliation(
    String ownerUid,
    String healthDay, {
    required LocalMutationTicket admission,
    required RemoteSendPermit permit,
  }) {
    _validateDay(healthDay);
    final ticket = _admit(ownerUid, admission);
    return _db.transactionWithCommitGuard(
      () async {
        permit.requireCurrent();
        final state =
            await (_db.select(_db.waterV2DailyStates)..where(
                  (t) =>
                      t.ownerUid.equals(ownerUid) &
                      t.healthDay.equals(healthDay),
                ))
                .getSingleOrNull();
        if (state == null) throw StateError('WATER_STATE_REQUIRED');
        await _requireEpoch(ownerUid, state.epoch);
        final rows =
            await (_db.select(_db.waterV2Intents)
                  ..where(
                    (t) =>
                        t.ownerUid.equals(ownerUid) &
                        t.healthDay.equals(healthDay) &
                        t.localStatus
                            .equals(WaterV2IntentStatus.receiptConfirmed)
                            .not(),
                  )
                  ..orderBy([(t) => OrderingTerm.asc(t.syncQueueId)])
                  ..limit(101))
                .get();
        if (rows.length > 100) throw StateError('WATER_RECONCILIATION_LIMIT');
        final intents = <WaterV2IncrementRequest>[];
        final queueIds = <String, int>{};
        for (final row in rows) {
          if (row.originEpoch == null)
            throw StateError('WATER_ORIGIN_REQUIRED');
          if (row.originEpoch != state.epoch)
            throw StateError('WATER_EPOCH_CONFLICT');
          final request = WaterV2IncrementRequest.fromIntent(row);
          final queue = await _linkedQueue(row, request);
          if (queue.status != SyncQueuePersistenceStatus.pending ||
              queue.isSynced)
            throw StateError('WATER_QUEUE_CONFLICT');
          intents.add(request);
          queueIds[row.mutationId] = queue.id;
        }
        permit.requireCurrent();
        if (intents.isEmpty) return null;
        return WaterV2ReconcilePlan(
          WaterV2ReconcileRequest(
            ownerUid: ownerUid,
            healthDay: healthDay,
            expectedEpoch: state.epoch,
            expectedRevision: state.revision,
            pendingMutationIds: intents.map((r) => r.mutationId).toList(),
          ),
          intents,
          queueIds,
        );
      },
      admission: ticket,
      validateBeforeCommit: permit.requireCurrent,
    );
  }

  /// Full identity evidence for a complete set, with no partial confirmation.
  Future<void> acknowledgeReconciliation(
    WaterV2ReconcileSuccess success, {
    required WaterV2ReconcilePlan plan,
    required LocalMutationTicket admission,
    required RemoteSendPermit permit,
    required String observedAtUtc,
  }) {
    _validateUtc(observedAtUtc);
    if (!identical(success.request, plan.request))
      throw StateError('WATER_MUTATION_CONFLICT');
    final request = plan.request;
    final ticket = _admit(request.ownerUid, admission);
    final boundPermit = success.remotePermit.and(() => permit.isCurrent);
    return _db.transactionWithCommitGuard(
      () async {
        boundPermit.requireCurrent();
        final prior =
            await (_db.select(_db.waterV2DailyStates)..where(
                  (t) =>
                      t.ownerUid.equals(request.ownerUid) &
                      t.healthDay.equals(request.healthDay),
                ))
                .getSingleOrNull();
        if (prior == null || prior.epoch != success.epoch)
          throw StateError('WATER_EPOCH_CONFLICT');
        if (success.revision < prior.revision)
          throw StateError('WATER_REVISION_REGRESSION');
        if (success.waterIntakeMl < prior.confirmedWaterIntakeMl ||
            (success.revision == prior.revision &&
                success.waterIntakeMl != prior.confirmedWaterIntakeMl))
          throw StateError('WATER_SNAPSHOT_CONFLICT');
        await _requireEpoch(request.ownerUid, success.epoch);
        final rows =
            await (_db.select(_db.waterV2Intents)..where(
                  (t) =>
                      t.ownerUid.equals(request.ownerUid) &
                      t.healthDay.equals(request.healthDay),
                ))
                .get();
        final expected = {for (final r in plan.intents) r.mutationId: r};
        final actual = {for (final r in rows) r.mutationId: r};
        final recognized = {
          for (final r in success.recognized) r.mutationId: r,
        };
        final toConfirm =
            <({WaterV2Intent intent, SyncQueueTableData queue})>[];
        // Every originally queried identity and link must still be present and intact.
        for (final captured in plan.intents) {
          final row = actual[captured.mutationId];
          if (row == null ||
              !captured.matches(row) ||
              row.syncQueueId != plan.queueIds[row.mutationId])
            throw StateError('WATER_MUTATION_CONFLICT');
          final receipt = recognized[row.mutationId];
          if (receipt != null && !receipt.matches(captured))
            throw StateError('WATER_MUTATION_CONFLICT');
        }
        var remainingMl = 0;
        for (final row in rows) {
          if (row.originEpoch == null)
            throw StateError('WATER_ORIGIN_REQUIRED');
          if (row.originEpoch != success.epoch)
            throw StateError('WATER_EPOCH_CONFLICT');
          final receipt = recognized[row.mutationId];
          if (receipt == null &&
              row.localStatus == WaterV2IntentStatus.receiptConfirmed) {
            if (expected.containsKey(row.mutationId))
              throw StateError('WATER_RECONCILIATION_REQUIRED');
            continue; // Previously confirmed identities are already part of the base.
          }
          final local = WaterV2IncrementRequest.fromIntent(row);
          final queue = await _linkedQueue(row, local);
          if (receipt != null) {
            // Recompute against the reread Drift row, not only the wire fields.
            if (!receipt.matches(local))
              throw StateError('WATER_MUTATION_CONFLICT');
            if (row.localStatus == WaterV2IntentStatus.receiptConfirmed) {
              if (queue.status == SyncQueuePersistenceStatus.succeeded &&
                  queue.isSynced)
                continue;
              throw StateError('WATER_QUEUE_CONFLICT');
            }
            if (queue.status != SyncQueuePersistenceStatus.pending ||
                queue.isSynced)
              throw StateError('WATER_QUEUE_CONFLICT');
            toConfirm.add((intent: row, queue: queue));
          } else {
            // Missing is not proof of never sent. Only still not_sent/attempt=0
            // can be projected, including an intact new gesture during HTTP.
            if (row.localStatus != WaterV2IntentStatus.notSent ||
                queue.attemptCount != 0)
              throw StateError('WATER_RECONCILIATION_REQUIRED');
            if (queue.status != SyncQueuePersistenceStatus.pending ||
                queue.isSynced)
              throw StateError('WATER_QUEUE_CONFLICT');
            remainingMl += row.deltaMl;
          }
        }
        final health = await (_db.select(
          _db.healthEntries,
        )..where((t) => t.docId.equals(request.healthDay))).getSingleOrNull();
        if (health == null) throw StateError('WATER_PROJECTION_REQUIRED');
        boundPermit.requireCurrent();
        if (toConfirm.isEmpty &&
            success.recognized.isNotEmpty &&
            prior.revision == success.revision &&
            prior.confirmedWaterIntakeMl == success.waterIntakeMl)
          return;
        await persistConfirmedState(
          ownerUid: request.ownerUid,
          healthDay: request.healthDay,
          epoch: success.epoch,
          revision: success.revision,
          confirmedWaterIntakeMl: success.waterIntakeMl,
          reconciledAtUtc: observedAtUtc,
          admission: ticket,
        );
        for (final entry in toConfirm) {
          await (_db.update(_db.waterV2Intents)..where(
                (t) =>
                    t.ownerUid.equals(request.ownerUid) &
                    t.mutationId.equals(entry.intent.mutationId),
              ))
              .write(
                const WaterV2IntentsCompanion(
                  localStatus: Value(WaterV2IntentStatus.receiptConfirmed),
                ),
              );
          await (_db.update(_db.syncQueueTable)..where(
                (t) =>
                    t.id.equals(entry.queue.id) &
                    t.ownerUid.equals(request.ownerUid),
              ))
              .write(
                SyncQueueTableCompanion(
                  status: const Value(SyncQueuePersistenceStatus.succeeded),
                  isSynced: const Value(true),
                  lastErrorCode: const Value(null),
                  attemptCount: Value(entry.queue.attemptCount + 1),
                  lastAttemptAt: Value(
                    DateTime.parse(observedAtUtc).millisecondsSinceEpoch,
                  ),
                ),
              );
        }
        await (_db.update(
          _db.healthEntries,
        )..where((t) => t.docId.equals(request.healthDay))).write(
          HealthEntriesCompanion(
            waterIntakeMl: Value(
              (success.waterIntakeMl + remainingMl).clamp(0, 1000000),
            ),
          ),
        );
        boundPermit.requireCurrent();
      },
      admission: ticket,
      validateBeforeCommit: boundPermit.requireCurrent,
    );
  }

  Future<WaterV2DailyState?> readConfirmedState({
    required String ownerUid,
    required String healthDay,
  }) {
    _validateDay(healthDay);
    final ticket = _admit(ownerUid, null);
    return _db.transaction(
      () =>
          (_db.select(_db.waterV2DailyStates)..where(
                (t) =>
                    t.ownerUid.equals(ownerUid) & t.healthDay.equals(healthDay),
              ))
              .getSingleOrNull(),
      admission: ticket,
      waitForReopen: false,
    );
  }
}
