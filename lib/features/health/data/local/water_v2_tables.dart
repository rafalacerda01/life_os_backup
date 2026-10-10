import 'package:drift/drift.dart';

/// A confirmed snapshot, never a copy of the legacy healthEntries total.
@DataClassName('WaterV2DailyState')
class WaterV2DailyStates extends Table {
  TextColumn get ownerUid => text()();
  TextColumn get healthDay => text()();
  TextColumn get epoch => text()();
  IntColumn get revision => integer()();
  IntColumn get confirmedWaterIntakeMl => integer()();

  /// Canonical UTC text retains milliseconds and records snapshot freshness.
  TextColumn get reconciledAtUtc => text()();

  @override
  Set<Column> get primaryKey => {ownerUid, healthDay};

  @override
  List<String> get customConstraints => [
    'CHECK (length(owner_uid) BETWEEN 1 AND 128 AND owner_uid = trim(owner_uid))',
    "CHECK (length(health_day) = 10 AND health_day GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]')",
    "CHECK (epoch GLOB '[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-4[0-9a-f][0-9a-f][0-9a-f]-[89ab][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]')",
    "CHECK (typeof(revision) = 'integer' AND revision BETWEEN 0 AND 9007199254740991)",
    "CHECK (typeof(confirmed_water_intake_ml) = 'integer' AND confirmed_water_intake_ml BETWEEN 0 AND 1000000)",
  ];
}

abstract final class WaterV2IntentStatus {
  static const notSent = 'not_sent';
  static const unreconciled = 'unreconciled';
  static const receiptConfirmed = 'receipt_confirmed';
}

/// Durable identity lives independently of SyncQueue retention and local IDs.
@DataClassName('WaterV2Intent')
class WaterV2Intents extends Table {
  TextColumn get ownerUid => text()();
  TextColumn get mutationId => text()();
  TextColumn get healthDay => text()();
  IntColumn get deltaMl => integer()();
  // Drift dateTime rounds to seconds; TEXT preserves the exact replay/fingerprint.
  TextColumn get occurredAtUtc => text()();
  IntColumn get timeZoneOffsetMinutes => integer()();

  /// Null means unprovisioned/quarantined, never permission to adopt an epoch.
  TextColumn get originEpoch => text().nullable()();
  TextColumn get localStatus =>
      text().withDefault(const Constant(WaterV2IntentStatus.notSent))();

  /// Reserved logical link. No FK: succeeded queue rows have a shorter lifetime
  /// than durable identities. This round neither enqueues nor assigns this link.
  IntColumn get syncQueueId => integer().nullable()();

  @override
  Set<Column> get primaryKey => {ownerUid, mutationId};

  @override
  List<String> get customConstraints => [
    'CHECK (length(owner_uid) BETWEEN 1 AND 128 AND owner_uid = trim(owner_uid))',
    "CHECK (mutation_id GLOB '[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-4[0-9a-f][0-9a-f][0-9a-f]-[89ab][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]')",
    "CHECK (length(health_day) = 10 AND health_day GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]')",
    "CHECK (typeof(delta_ml) = 'integer' AND delta_ml = 250)",
    "CHECK (typeof(time_zone_offset_minutes) = 'integer' AND time_zone_offset_minutes BETWEEN -840 AND 840)",
    "CHECK (origin_epoch IS NULL OR origin_epoch GLOB '[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-4[0-9a-f][0-9a-f][0-9a-f]-[89ab][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]')",
    "CHECK (local_status IN ('not_sent', 'unreconciled', 'receipt_confirmed'))",
    "CHECK (sync_queue_id IS NULL OR (typeof(sync_queue_id) = 'integer' AND sync_queue_id > 0))",
  ];
}
