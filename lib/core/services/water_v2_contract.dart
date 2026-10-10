import 'dart:convert';

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
      originEpoch = intent.originEpoch {
    WaterV2Validation.require(
      ownerUid.isNotEmpty &&
          ownerUid == ownerUid.trim() &&
          ownerUid.length <= 128,
    );
    WaterV2Validation.require(
      WaterV2Validation.uuid.hasMatch(mutationId) &&
          originEpoch != null &&
          WaterV2Validation.uuid.hasMatch(originEpoch!),
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
  final String? originEpoch;
  final int deltaMl, timeZoneOffsetMinutes;
  Map<String, dynamic> toJson() => {
    'operation': WaterV2Queue.increment,
    'version': 2,
    'mutationId': mutationId,
    'healthDay': healthDay,
    'deltaMl': deltaMl,
    'occurredAt': occurredAt,
    'timeZoneOffsetMinutes': timeZoneOffsetMinutes,
  };
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
  const WaterV2RecognizedIdentity(
    this.mutationId,
    this.effectiveCreditMl,
    this.appliedRevision,
  );
  final String mutationId;
  final int effectiveCreditMl, appliedRevision;
}

/// Membership-only data. Deliberately cannot be used as an increment ACK.
final class WaterV2ReconcileSuccess {
  WaterV2ReconcileSuccess._(
    this.request,
    this.waterIntakeMl,
    this.recognized,
    this.unrecognizedMutationIds,
  );
  final WaterV2ReconcileRequest request;
  String get operation => 'reconcile_water';
  int get version => 2;
  String get healthDay => request.healthDay;
  String get epoch => request.expectedEpoch;
  int get revision => request.expectedRevision;
  final int waterIntakeMl;
  final List<WaterV2RecognizedIdentity> recognized;
  final List<String> unrecognizedMutationIds;
  factory WaterV2ReconcileSuccess.parse(
    String body,
    WaterV2ReconcileRequest request,
  ) {
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
          m['revision'] is int &&
          m['revision'] == request.expectedRevision &&
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
              'effectiveCreditMl',
              'appliedRevision',
            }) &&
            row['mutationId'] is String &&
            request.pendingMutationIds.contains(row['mutationId']) &&
            ids.add(row['mutationId'] as String) &&
            WaterV2Validation.integer(row['effectiveCreditMl'], 0, 250) &&
            WaterV2Validation.integer(
              row['appliedRevision'],
              1,
              request.expectedRevision,
            ) &&
            total >= (row['effectiveCreditMl'] as int) &&
            (row['effectiveCreditMl'] == 250 || total == 1000000),
      );
      recognized.add(
        WaterV2RecognizedIdentity(
          row['mutationId'] as String,
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
      total,
      List.unmodifiable(recognized),
      List.unmodifiable(missing),
    );
  }
}
