import 'package:drift/drift.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/local_mutation_gate.dart';
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

/// Local-only primitives. No API here acknowledges delivery, updates the legacy
/// projection, changes an intent's status/epoch, or creates a SyncQueue item.
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
