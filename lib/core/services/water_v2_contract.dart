import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/remote_send_permit.dart';

abstract final class WaterV2Queue {
  static const collection = 'water_v2';
  static const increment = 'increment_water';
  static bool isWater(SyncQueueTableData row) =>
      row.collection.trim().toLowerCase() == collection ||
      const {
        'increment_water',
        'reconcile_water',
      }.contains(row.operationType.trim().toLowerCase());
}

abstract final class WaterV2Validation {
  static const maxRevision = 9007199254740991;
  static final uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );
  static void require(bool value) {
    if (!value) throw const FormatException('WATER_INVALID_CONTRACT');
  }

  static bool exact(Map<String, dynamic> map, Set<String> keys) =>
      map.length == keys.length && map.keys.every(keys.contains);
  static bool integer(Object? value, int min, int max) =>
      value is int && value >= min && value <= max;
  static bool day(String value) {
    final parsed = DateTime.tryParse('${value}T00:00:00.000Z');
    return RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value) &&
        parsed != null &&
        parsed.year >= 1 &&
        parsed.toIso8601String() == '${value}T00:00:00.000Z';
  }

  static Map<String, dynamic> object(String json) {
    final value = jsonDecode(json);
    require(value is Map<String, dynamic>);
    return value as Map<String, dynamic>;
  }

  static bool identity(Map<String, dynamic> value) {
    if (value['mutationId'] is! String ||
        !uuid.hasMatch(value['mutationId']) ||
        value['healthDay'] is! String ||
        !day(value['healthDay']) ||
        value['deltaMl'] is! int ||
        value['deltaMl'] != 250 ||
        value['occurredAt'] is! String ||
        !RegExp(
          r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$',
        ).hasMatch(value['occurredAt']) ||
        !integer(value['timeZoneOffsetMinutes'], -840, 840))
      return false;
    final utc = DateTime.tryParse(value['occurredAt']);
    return utc != null &&
        utc.isUtc &&
        utc.toIso8601String() == value['occurredAt'] &&
        utc
                .add(Duration(minutes: value['timeZoneOffsetMinutes'] as int))
                .toIso8601String()
                .substring(0, 10) ==
            value['healthDay'];
  }
}

abstract final class WaterV2Fingerprint {
  static String calculate({
    required String mutationId,
    required String healthDay,
    required int deltaMl,
    required String occurredAt,
    required int timeZoneOffsetMinutes,
  }) => sha256
      .convert(
        utf8.encode(
          jsonEncode([
            2,
            mutationId,
            healthDay,
            deltaMl,
            occurredAt,
            timeZoneOffsetMinutes,
          ]),
        ),
      )
      .toString();
}

/// All request identity is copied from a durable row, never the retry clock.
final class WaterV2IncrementRequest {
  WaterV2IncrementRequest.fromIntent(WaterV2Intent intent)
    : ownerUid = intent.ownerUid,
      mutationId = intent.mutationId,
      healthDay = intent.healthDay,
      deltaMl = intent.deltaMl,
      occurredAt = intent.occurredAtUtc,
      timeZoneOffsetMinutes = intent.timeZoneOffsetMinutes,
      originEpoch = intent.originEpoch ?? '' {
    WaterV2Validation.require(
      ownerUid.isNotEmpty &&
          ownerUid == ownerUid.trim() &&
          ownerUid.length <= 128,
    );
    WaterV2Validation.require(
      WaterV2Validation.uuid.hasMatch(mutationId) &&
          WaterV2Validation.uuid.hasMatch(originEpoch),
    );
    final utc = DateTime.tryParse(occurredAt);
    WaterV2Validation.require(
      WaterV2Validation.day(healthDay) &&
          deltaMl == 250 &&
          WaterV2Validation.integer(timeZoneOffsetMinutes, -840, 840) &&
          RegExp(
            r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$',
          ).hasMatch(occurredAt) &&
          utc != null &&
          utc.isUtc &&
          utc.toIso8601String() == occurredAt,
    );
    final local = utc!.add(Duration(minutes: timeZoneOffsetMinutes));
    WaterV2Validation.require(
      local.toIso8601String().substring(0, 10) == healthDay,
    );
  }
  final String ownerUid, mutationId, healthDay, occurredAt;
  final String originEpoch;
  final int deltaMl, timeZoneOffsetMinutes;
  Map<String, dynamic> toJson() => {
    'operation': WaterV2Queue.increment,
    'version': 2,
    'mutationId': mutationId,
    'healthDay': healthDay,
    'deltaMl': deltaMl,
    'occurredAt': occurredAt,
    'timeZoneOffsetMinutes': timeZoneOffsetMinutes,
    'originEpoch': originEpoch,
  };
  String get fingerprint => WaterV2Fingerprint.calculate(
    mutationId: mutationId,
    healthDay: healthDay,
    deltaMl: deltaMl,
    occurredAt: occurredAt,
    timeZoneOffsetMinutes: timeZoneOffsetMinutes,
  );
  bool matches(WaterV2Intent row) =>
      row.ownerUid == ownerUid &&
      row.mutationId == mutationId &&
      row.healthDay == healthDay &&
      row.deltaMl == deltaMl &&
      row.occurredAtUtc == occurredAt &&
      row.timeZoneOffsetMinutes == timeZoneOffsetMinutes &&
      row.originEpoch == originEpoch;
  bool matchesQueue(SyncQueueTableData row) {
    if (row.ownerUid != ownerUid ||
        row.collection != WaterV2Queue.collection ||
        row.operationType != WaterV2Queue.increment ||
        row.docId != mutationId)
      return false;
    final payload = WaterV2Validation.object(row.payloadJson);
    final expected = toJson();
    return WaterV2Validation.exact(payload, expected.keys.toSet()) &&
        expected.entries.every(
          (entry) =>
              payload[entry.key].runtimeType == entry.value.runtimeType &&
              payload[entry.key] == entry.value,
        );
  }
}

/// A validated response remains bound to the exact increment request.
final class WaterV2IncrementSuccess {
  WaterV2IncrementSuccess._(
    this.request,
    this.epoch,
    this.revision,
    this.waterIntakeMl,
    this.alreadyApplied,
    this.effectiveCreditMl,
    this.appliedRevision,
    this.remotePermit,
  );
  final RemoteSendPermit remotePermit;
  final WaterV2IncrementRequest request;
  String get operation => WaterV2Queue.increment;
  int get version => 2;
  String get healthDay => request.healthDay;
  final String epoch;
  final int revision, waterIntakeMl, effectiveCreditMl, appliedRevision;
  final bool alreadyApplied;
  factory WaterV2IncrementSuccess.parse(
    String body,
    WaterV2IncrementRequest request, {
    required RemoteSendPermit permit,
  }) {
    permit.requireCurrent();
    final m = WaterV2Validation.object(body);
    WaterV2Validation.require(
      WaterV2Validation.exact(m, const {
            'success',
            'operation',
            'version',
            'healthDay',
            'epoch',
            'revision',
            'waterIntakeMl',
            'alreadyApplied',
            'effectiveCreditMl',
            'appliedRevision',
          }) &&
          m['success'] == true &&
          m['operation'] == WaterV2Queue.increment &&
          m['version'] is int &&
          m['version'] == 2 &&
          m['healthDay'] == request.healthDay &&
          m['epoch'] == request.originEpoch &&
          m['alreadyApplied'] is bool &&
          WaterV2Validation.integer(
            m['revision'],
            1,
            WaterV2Validation.maxRevision,
          ) &&
          WaterV2Validation.integer(
            m['appliedRevision'],
            1,
            WaterV2Validation.maxRevision,
          ) &&
          WaterV2Validation.integer(m['waterIntakeMl'], 0, 1000000) &&
          WaterV2Validation.integer(m['effectiveCreditMl'], 0, 250),
    );
    final revision = m['revision'] as int;
    final applied = m['appliedRevision'] as int;
    final total = m['waterIntakeMl'] as int;
    final credit = m['effectiveCreditMl'] as int;
    final replay = m['alreadyApplied'] as bool;
    WaterV2Validation.require(
      applied <= revision &&
          (replay || applied == revision) &&
          total >= credit &&
          (credit == 250 || total == 1000000),
    );
    return WaterV2IncrementSuccess._(
      request,
      m['epoch'] as String,
      revision,
      total,
      replay,
      credit,
      applied,
      permit,
    );
  }
}

final class WaterV2ReconcileRequest {
  WaterV2ReconcileRequest({
    required this.ownerUid,
    required this.healthDay,
    required this.expectedEpoch,
    required this.expectedRevision,
    required List<String> pendingMutationIds,
  }) : pendingMutationIds = List.unmodifiable(pendingMutationIds) {
    WaterV2Validation.require(
      ownerUid.isNotEmpty &&
          ownerUid == ownerUid.trim() &&
          ownerUid.length <= 128 &&
          WaterV2Validation.day(healthDay) &&
          WaterV2Validation.uuid.hasMatch(expectedEpoch) &&
          WaterV2Validation.integer(
            expectedRevision,
            0,
            WaterV2Validation.maxRevision,
          ) &&
          this.pendingMutationIds.length <= 100 &&
          this.pendingMutationIds.toSet().length ==
              this.pendingMutationIds.length &&
          this.pendingMutationIds.every(WaterV2Validation.uuid.hasMatch),
    );
  }
  final String ownerUid, healthDay, expectedEpoch;
  final int expectedRevision;
  final List<String> pendingMutationIds;
  Map<String, dynamic> toJson() => {
    'operation': 'reconcile_water',
    'version': 2,
    'healthDay': healthDay,
    'pendingMutationIds': pendingMutationIds,
    'expectedEpoch': expectedEpoch,
    'expectedRevision': expectedRevision,
  };
}

final class WaterV2RecognizedIdentity {
  const WaterV2RecognizedIdentity._(
    this.mutationId,
    this.healthDay,
    this.deltaMl,
    this.occurredAt,
    this.timeZoneOffsetMinutes,
    this.fingerprint,
    this.effectiveCreditMl,
    this.appliedRevision,
  );
  final String mutationId, healthDay, occurredAt, fingerprint;
  final int deltaMl, timeZoneOffsetMinutes, effectiveCreditMl, appliedRevision;
  bool matches(WaterV2IncrementRequest local) =>
      mutationId == local.mutationId &&
      healthDay == local.healthDay &&
      deltaMl == local.deltaMl &&
      occurredAt == local.occurredAt &&
      timeZoneOffsetMinutes == local.timeZoneOffsetMinutes &&
      fingerprint == local.fingerprint;
}

/// The local immutable identities captured before HTTP, bound to one query.
final class WaterV2ReconcilePlan {
  WaterV2ReconcilePlan(
    this.request,
    List<WaterV2IncrementRequest> intents,
    Map<String, int> queueIds,
  ) : intents = List.unmodifiable(intents),
      queueIds = Map.unmodifiable(queueIds) {
    WaterV2Validation.require(
      intents.length == request.pendingMutationIds.length &&
          queueIds.length == intents.length &&
          queueIds.values.toSet().length == intents.length &&
          intents.every((r) => (queueIds[r.mutationId] ?? 0) > 0) &&
          intents.map((r) => r.mutationId).toSet().length == intents.length &&
          intents.every(
            (r) =>
                request.pendingMutationIds.contains(r.mutationId) &&
                r.ownerUid == request.ownerUid &&
                r.healthDay == request.healthDay &&
                r.originEpoch == request.expectedEpoch,
          ),
    );
  }
  final WaterV2ReconcileRequest request;
  final List<WaterV2IncrementRequest> intents;
  final Map<String, int> queueIds;
}

/// Complete receipt evidence, bound to its original remote admission.
final class WaterV2ReconcileSuccess {
  WaterV2ReconcileSuccess._(
    this.request,
    this.epoch,
    this.revision,
    this.waterIntakeMl,
    this.recognized,
    this.unrecognizedMutationIds,
    this.remotePermit,
  );
  final WaterV2ReconcileRequest request;
  final RemoteSendPermit remotePermit;
  String get operation => 'reconcile_water';
  int get version => 2;
  String get healthDay => request.healthDay;
  final String epoch;
  final int revision, waterIntakeMl;
  final List<WaterV2RecognizedIdentity> recognized;
  final List<String> unrecognizedMutationIds;
  factory WaterV2ReconcileSuccess.parse(
    String body,
    WaterV2ReconcileRequest request, {
    required RemoteSendPermit permit,
  }) {
    permit.requireCurrent();
    final m = WaterV2Validation.object(body);
    WaterV2Validation.require(
      WaterV2Validation.exact(m, const {
            'success',
            'operation',
            'version',
            'healthDay',
            'epoch',
            'revision',
            'waterIntakeMl',
            'complete',
            'recognized',
            'unrecognizedMutationIds',
          }) &&
          m['success'] == true &&
          m['operation'] == 'reconcile_water' &&
          m['version'] is int &&
          m['version'] == 2 &&
          m['healthDay'] == request.healthDay &&
          m['epoch'] == request.expectedEpoch &&
          WaterV2Validation.integer(
            m['revision'],
            request.expectedRevision,
            WaterV2Validation.maxRevision,
          ) &&
          WaterV2Validation.integer(m['waterIntakeMl'], 0, 1000000) &&
          m['complete'] == true &&
          m['recognized'] is List &&
          m['unrecognizedMutationIds'] is List,
    );
    final ids = <String>{};
    final recognized = <WaterV2RecognizedIdentity>[];
    final total = m['waterIntakeMl'] as int;
    for (final value in m['recognized'] as List) {
      WaterV2Validation.require(value is Map<String, dynamic>);
      final row = value as Map<String, dynamic>;
      WaterV2Validation.require(
        WaterV2Validation.exact(row, const {
              'mutationId',
              'healthDay',
              'deltaMl',
              'occurredAt',
              'timeZoneOffsetMinutes',
              'fingerprint',
              'effectiveCreditMl',
              'appliedRevision',
            }) &&
            WaterV2Validation.identity(row) &&
            row['healthDay'] == request.healthDay &&
            row['fingerprint'] is String &&
            RegExp(r'^[0-9a-f]{64}$').hasMatch(row['fingerprint']) &&
            row['fingerprint'] ==
                WaterV2Fingerprint.calculate(
                  mutationId: row['mutationId'],
                  healthDay: row['healthDay'],
                  deltaMl: row['deltaMl'],
                  occurredAt: row['occurredAt'],
                  timeZoneOffsetMinutes: row['timeZoneOffsetMinutes'],
                ) &&
            request.pendingMutationIds.contains(row['mutationId']) &&
            ids.add(row['mutationId'] as String) &&
            WaterV2Validation.integer(row['effectiveCreditMl'], 0, 250) &&
            WaterV2Validation.integer(
              row['appliedRevision'],
              1,
              m['revision'] as int,
            ) &&
            total >= (row['effectiveCreditMl'] as int) &&
            (row['effectiveCreditMl'] == 250 || total == 1000000),
      );
      recognized.add(
        WaterV2RecognizedIdentity._(
          row['mutationId'] as String,
          row['healthDay'] as String,
          row['deltaMl'] as int,
          row['occurredAt'] as String,
          row['timeZoneOffsetMinutes'] as int,
          row['fingerprint'] as String,
          row['effectiveCreditMl'] as int,
          row['appliedRevision'] as int,
        ),
      );
    }
    final missing = <String>[];
    for (final id in m['unrecognizedMutationIds'] as List) {
      WaterV2Validation.require(
        id is String && request.pendingMutationIds.contains(id) && ids.add(id),
      );
      missing.add(id as String);
    }
    WaterV2Validation.require(ids.length == request.pendingMutationIds.length);
    return WaterV2ReconcileSuccess._(
      request,
      m['epoch'] as String,
      m['revision'] as int,
      total,
      List.unmodifiable(recognized),
      List.unmodifiable(missing),
      permit,
    );
  }
}
