import 'dart:async';
import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';
import 'package:life_os/core/database/local_mutation_gate.dart';
import 'package:life_os/core/database/remote_send_permit.dart';
import 'package:life_os/core/services/water_v2_goal.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/services/water_v2_contract.dart';
import 'package:life_os/core/services/water_v2_remote_data_source.dart';
import 'package:life_os/core/services/water_v2_sync_processor.dart';
import 'package:life_os/features/health/data/local/water_v2_local_store.dart';
import 'package:life_os/features/health/data/local/water_v2_tables.dart';

enum WaterAdmissionState {
  disabled,
  waiting,
  ready,
  offline,
  legacy,
  ineligible,
  deleting,
}

/// Session-scoped coordinator. All durable consumption stays in Drift/outbox.
class WaterV2Controller {
  WaterV2Controller(
    this.db,
    this.remote,
    this.processor,
    this.currentUid, {
    DateTime Function()? now,
    this.afterCommit,
  }) : now = now ?? DateTime.now;
  final AppDatabase db;
  final WaterV2RemoteDataSource remote;
  final WaterV2SyncProcessor processor;
  final String? Function() currentUid;
  final DateTime Function() now;
  final Future<bool> Function()? afterCommit;
  final _events = StreamController<WaterAdmissionState>.broadcast();
  WaterAdmissionState state = WaterAdmissionState.disabled;
  Stream<WaterAdmissionState> get states => _events.stream;
  bool _disposed = false;
  bool _revoked = false;
  String? _civilClockKey;
  Future<void>? _refresh;
  bool get isEnabled => remote.isEnabled;
  void _set(WaterAdmissionState value) {
    if (_disposed) return;
    state = value;
    _events.add(value);
  }

  static String dayOf(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  void _current(String uid) {
    if (_disposed || currentUid() != uid) throw StateError('SESSION_STOPPED');
  }

  Future<WaterV2DailyState?> _state(String uid, String day) =>
      (db.select(db.waterV2DailyStates)
            ..where((t) => t.ownerUid.equals(uid) & t.healthDay.equals(day)))
          .getSingleOrNull();

  Future<void> _localDay(
    String uid,
    String day,
    LocalMutationTicket ticket, {
    bool notifyCivilDay = false,
  }) async {
    await db.transaction(
      () async {
        _current(uid);
        if (await _state(uid, day) != null) {
          final health = await (db.select(
            db.healthEntries,
          )..where((t) => t.docId.equals(day))).getSingleOrNull();
          if (health == null) throw StateError('WATER_PROJECTION_REQUIRED');
          if (notifyCivilDay) {
            // Signal Drift watchers after offline timezone/date changes, without
            // rewriting a total or acknowledging any pending consumption.
            await (db.update(db.healthEntries)
                  ..where((t) => t.docId.equals(day)))
                .write(HealthEntriesCompanion(docId: Value(day)));
          }
          return;
        }
        final prior =
            await (db.select(db.waterV2DailyStates)
                  ..where((t) => t.ownerUid.equals(uid))
                  ..orderBy([(t) => OrderingTerm.desc(t.healthDay)])
                  ..limit(1))
                .getSingleOrNull();
        final preference = await (db.select(
          db.waterV2Preferences,
        )..where((t) => t.ownerUid.equals(uid))).getSingleOrNull();
        if (prior == null ||
            (day.compareTo(prior.healthDay) < 0 &&
                (preference?.epoch != prior.epoch ||
                    preference?.initialHealthDay == null ||
                    day.compareTo(preference!.initialHealthDay!) < 0)))
          throw StateError('WATER_STATE_REQUIRED');
        final health = await (db.select(
          db.healthEntries,
        )..where((t) => t.docId.equals(day))).getSingleOrNull();
        // A legacy total is never a V2 baseline, including an old local zero row.
        if (health != null && health.waterIntakeMl != 0)
          throw StateError('WATER_MIGRATION_NOT_READY');
        await WaterV2LocalStore(db).persistConfirmedState(
          ownerUid: uid,
          healthDay: day,
          epoch: prior.epoch,
          revision: 0,
          confirmedWaterIntakeMl: 0,
          reconciledAtUtc: DateTime.fromMillisecondsSinceEpoch(
            now().millisecondsSinceEpoch,
            isUtc: true,
          ).toIso8601String(),
          admission: ticket,
        );
        if (health == null)
          await db
              .into(db.healthEntries)
              .insert(HealthEntriesCompanion.insert(docId: day, date: now()));
      },
      admission: ticket,
      waitForReopen: false,
    );
  }

  Future<void> refresh() {
    final running = _refresh;
    if (running != null) return running;
    late final Future<void> task;
    task = _refreshDay().whenComplete(() {
      if (identical(_refresh, task)) _refresh = null;
    });
    return _refresh = task;
  }

  Future<void> _refreshDay() async {
    if (!isEnabled) {
      _set(WaterAdmissionState.disabled);
      return;
    }
    if (_revoked) {
      _set(WaterAdmissionState.deleting);
      return;
    }
    final uid = currentUid();
    if (uid == null) return;
    final instant = now(), day = dayOf(instant);
    late final LocalMutationTicket ticket;
    late final RemoteSendPermit permit;
    try {
      ticket = db.localMutations.capture(expectedUid: uid);
      permit = remote.capturePermit(
        uid,
        () => !_disposed && currentUid() == uid,
      );
    } catch (_) {
      return;
    }
    try {
      final key = '$day|${instant.timeZoneOffset.inMinutes}';
      final changed = _civilClockKey != key;
      await _localDay(uid, day, ticket, notifyCivilDay: changed);
      _civilClockKey = key;
      _set(WaterAdmissionState.offline);
    } catch (_) {
      _set(WaterAdmissionState.waiting);
    }
    try {
      final result = await remote.bootstrap(
        uid,
        instant.timeZoneOffset.inMinutes,
        permit,
      );
      permit.requireCurrent();
      if (result.value == null) {
        if (result.error?.code == 'ACCOUNT_DELETION_BLOCKED') {
          _revoked = true;
          _set(WaterAdmissionState.deleting);
        }
        return;
      }
      final snapshot = result.value!;
      if (snapshot.state != 'READY') {
        _set(
          snapshot.state == 'LEGACY'
              ? WaterAdmissionState.legacy
              : WaterAdmissionState.ineligible,
        );
        return;
      }
      if (snapshot.healthDay != day)
        throw const FormatException('WATER_DAY_MISMATCH');
      final store = WaterV2LocalStore(db);
      final pending = await store.readIntents(ownerUid: uid, healthDay: day);
      if (pending.any(
        (i) => i.localStatus != WaterV2IntentStatus.receiptConfirmed,
      )) {
        final reconciled = await processor.reconcileDay(
          uid,
          day,
          canSend: () => !_disposed && currentUid() == uid,
        );
        if (!reconciled.isSuccess) return;
      } else {
        await db.transactionWithCommitGuard(
          () async {
            permit.requireCurrent();
            final rows = await store.readIntents(ownerUid: uid, healthDay: day);
            if (rows.any(
              (i) => i.localStatus != WaterV2IntentStatus.receiptConfirmed,
            ))
              throw StateError('WATER_RECONCILIATION_REQUIRED');
            await store.persistConfirmedState(
              ownerUid: uid,
              healthDay: day,
              epoch: snapshot.epoch!,
              revision: snapshot.revision!,
              confirmedWaterIntakeMl: snapshot.waterIntakeMl!,
              reconciledAtUtc: DateTime.fromMillisecondsSinceEpoch(
                now().millisecondsSinceEpoch,
                isUtc: true,
              ).toIso8601String(),
              admission: ticket,
            );
            final old = await (db.select(
              db.healthEntries,
            )..where((t) => t.docId.equals(day))).getSingleOrNull();
            if (old == null) {
              await db
                  .into(db.healthEntries)
                  .insert(
                    HealthEntriesCompanion.insert(
                      docId: day,
                      date: instant,
                      waterIntakeMl: Value(snapshot.waterIntakeMl!),
                    ),
                  );
            } else {
              await (db.update(
                db.healthEntries,
              )..where((t) => t.docId.equals(day))).write(
                HealthEntriesCompanion(
                  waterIntakeMl: Value(snapshot.waterIntakeMl!),
                ),
              );
            }
          },
          admission: ticket,
          waitForReopen: false,
          validateBeforeCommit: permit.requireCurrent,
        );
      }
      await db.transactionWithCommitGuard(
        () async {
          final old = await (db.select(
            db.waterV2Preferences,
          )..where((t) => t.ownerUid.equals(uid))).getSingleOrNull();
          if (old != null && old.epoch != snapshot.epoch)
            throw StateError('WATER_EPOCH_CONFLICT');
          if (old != null && old.initialHealthDay != snapshot.initialHealthDay)
            throw StateError('WATER_SNAPSHOT_CONFLICT');
          if (old != null &&
              old.revision == snapshot.goalRevision &&
              old.goalMl != snapshot.goalMl)
            throw StateError('WATER_SNAPSHOT_CONFLICT');
          if (old == null || old.revision <= snapshot.goalRevision!) {
            await db
                .into(db.waterV2Preferences)
                .insertOnConflictUpdate(
                  WaterV2PreferencesCompanion.insert(
                    ownerUid: uid,
                    epoch: Value(snapshot.epoch),
                    initialHealthDay: Value(snapshot.initialHealthDay),
                    goalMl: Value(snapshot.goalMl!),
                    revision: Value(snapshot.goalRevision!),
                  ),
                );
          }
        },
        admission: ticket,
        validateBeforeCommit: permit.requireCurrent,
      );
      _current(uid);
      _set(WaterAdmissionState.ready);
    } catch (_) {
      /* Durable state/outbox survives; next lifecycle tick retries. */
    }
  }

  Future<void> addWater() async {
    if (!isEnabled ||
        {
          WaterAdmissionState.deleting,
          WaterAdmissionState.legacy,
          WaterAdmissionState.ineligible,
        }.contains(state))
      throw StateError('WATER_REGISTRATION_UNAVAILABLE');
    final uid = currentUid();
    if (uid == null) throw StateError('SESSION_STOPPED');
    final ticket = db.localMutations.capture(expectedUid: uid);
    final instant = now(), day = dayOf(instant), id = const Uuid().v4();
    final occurred = DateTime.fromMillisecondsSinceEpoch(
      instant.millisecondsSinceEpoch,
      isUtc: true,
    ).toIso8601String();
    await _localDay(uid, day, ticket);
    await db.transaction(
      () async {
        _current(uid);
        final confirmed = await _state(uid, day);
        if (confirmed == null) throw StateError('WATER_STATE_REQUIRED');
        final store = WaterV2LocalStore(db);
        final rows = await store.readIntents(ownerUid: uid, healthDay: day);
        if (rows
                .where(
                  (r) => r.localStatus != WaterV2IntentStatus.receiptConfirmed,
                )
                .length >=
            100)
          throw StateError('WATER_RECONCILIATION_LIMIT');
        final intent = await store.insertIntent(
          WaterV2IntentInput(
            ownerUid: uid,
            mutationId: id,
            healthDay: day,
            deltaMl: 250,
            occurredAtUtc: occurred,
            timeZoneOffsetMinutes: instant.timeZoneOffset.inMinutes,
            originEpoch: confirmed.epoch,
          ),
          admission: ticket,
        );
        final request = WaterV2IncrementRequest.fromIntent(intent);
        final queue = await db.insertSyncItem(
          ownerUid: uid,
          collection: WaterV2Queue.collection,
          docId: id,
          operationType: WaterV2Queue.increment,
          payloadJson: jsonEncode(request.toJson()),
          createdAt: instant.millisecondsSinceEpoch,
        );
        await (db.update(db.waterV2Intents)
              ..where((t) => t.ownerUid.equals(uid) & t.mutationId.equals(id)))
            .write(WaterV2IntentsCompanion(syncQueueId: Value(queue)));
        final optimistic =
            (confirmed.confirmedWaterIntakeMl +
                    250 +
                    rows
                        .where(
                          (r) =>
                              r.localStatus !=
                              WaterV2IntentStatus.receiptConfirmed,
                        )
                        .fold<int>(0, (total, r) => total + r.deltaMl))
                .clamp(0, 1000000);
        await (db.update(db.healthEntries)..where((t) => t.docId.equals(day)))
            .write(HealthEntriesCompanion(waterIntakeMl: Value(optimistic)));
        _current(uid);
      },
      admission: ticket,
      waitForReopen: false,
    );
    // Persistence is complete. A caller leaving the screen cannot cancel the intent.
    _kickSync();
  }

  Future<int> readGoal() async {
    final uid = currentUid();
    if (uid == null) return 3000;
    final row = await (db.select(
      db.waterV2Preferences,
    )..where((t) => t.ownerUid.equals(uid))).getSingleOrNull();
    final pending =
        await (db.select(db.syncQueueTable)
              ..where(
                (t) =>
                    t.ownerUid.equals(uid) &
                    t.collection.equals(WaterV2Queue.collection) &
                    t.operationType.equals('set_water_goal') &
                    t.status.equals(SyncQueuePersistenceStatus.pending),
              )
              ..orderBy([(t) => OrderingTerm.desc(t.id)]))
            .get();
    return pending.isEmpty
        ? row?.goalMl ?? 3000
        : WaterV2GoalRequest.fromQueue(uid, pending.first).goalMl;
  }

  Stream<int> watchGoal() {
    final uid = currentUid();
    if (uid == null) return Stream.value(3000);
    return db
        .customSelect(
          'SELECT revision AS value FROM water_v2_preferences WHERE owner_uid=? '
          'UNION ALL SELECT id AS value FROM sync_queue_table WHERE owner_uid=?',
          variables: [Variable.withString(uid), Variable.withString(uid)],
          readsFrom: {db.waterV2Preferences, db.syncQueueTable},
        )
        .watch()
        .asyncMap((_) => readGoal())
        .distinct();
  }

  Future<void> setGoal(int goalMl) async {
    if (!isEnabled ||
        !WaterV2GoalRequest.validGoal(goalMl) ||
        !{
          WaterAdmissionState.ready,
          WaterAdmissionState.offline,
        }.contains(state))
      throw StateError('WATER_REGISTRATION_UNAVAILABLE');
    final uid = currentUid();
    if (uid == null) throw StateError('SESSION_STOPPED');
    final ticket = db.localMutations.capture(expectedUid: uid),
        id = const Uuid().v4();
    await db.transaction(
      () async {
        _current(uid);
        final preference = await (db.select(
          db.waterV2Preferences,
        )..where((t) => t.ownerUid.equals(uid))).getSingleOrNull();
        if (preference?.epoch == null) throw StateError('WATER_STATE_REQUIRED');
        final request = WaterV2GoalRequest(uid, id, preference!.epoch!, goalMl);
        await db.insertSyncItem(
          ownerUid: uid,
          collection: WaterV2Queue.collection,
          docId: id,
          operationType: 'set_water_goal',
          payloadJson: jsonEncode(request.toJson()),
          createdAt: now().millisecondsSinceEpoch,
        );
        _current(uid);
      },
      admission: ticket,
      waitForReopen: false,
    );
    _kickSync();
  }

  void _kickSync() {
    final action = afterCommit;
    if (action == null) return;
    // Scheduling can throw synchronously during provider/session disposal too.
    // A saved intent remains successful locally and is never recreated on retry.
    unawaited(Future<bool>.sync(action).then<void>((_) {}, onError: (_) {}));
  }

  void dispose() {
    _disposed = true;
    unawaited(_events.close());
  }
}
