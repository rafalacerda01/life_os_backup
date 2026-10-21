import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/local_mutation_gate.dart';
import 'package:life_os/core/database/remote_send_permit.dart';
import 'water_v2_contract.dart';

final class WaterV2GoalRequest {
  WaterV2GoalRequest(this.ownerUid, this.mutationId, this.epoch, this.goalMl) {
    WaterV2Validation.require(
      ownerUid.isNotEmpty &&
          WaterV2Validation.uuid.hasMatch(mutationId) &&
          WaterV2Validation.uuid.hasMatch(epoch) &&
          validGoal(goalMl),
    );
  }
  final String ownerUid, mutationId, epoch;
  final int goalMl;
  static bool validGoal(Object? value) =>
      value is int && value >= 250 && value <= 10000 && value % 250 == 0;
  Map<String, dynamic> toJson() => {
    'operation': 'set_water_goal',
    'version': 2,
    'mutationId': mutationId,
    'originEpoch': epoch,
    'goalMl': goalMl,
  };
  factory WaterV2GoalRequest.fromQueue(String uid, SyncQueueTableData row) {
    final m = WaterV2Validation.object(row.payloadJson);
    WaterV2Validation.require(
      row.ownerUid == uid &&
          row.collection == WaterV2Queue.collection &&
          row.operationType == 'set_water_goal' &&
          row.docId == m['mutationId'] &&
          WaterV2Validation.exact(m, {
            'operation',
            'version',
            'mutationId',
            'originEpoch',
            'goalMl',
          }) &&
          m['operation'] == 'set_water_goal' &&
          m['version'] == 2 &&
          m['mutationId'] is String &&
          m['originEpoch'] is String &&
          validGoal(m['goalMl']),
    );
    return WaterV2GoalRequest(
      uid,
      m['mutationId'],
      m['originEpoch'],
      m['goalMl'],
    );
  }
}

final class WaterV2GoalSuccess {
  WaterV2GoalSuccess._(this.request, this.goalMl, this.revision);
  final WaterV2GoalRequest request;
  final int goalMl, revision;
  factory WaterV2GoalSuccess.parse(String body, WaterV2GoalRequest request) {
    final m = WaterV2Validation.object(body);
    WaterV2Validation.require(
      WaterV2Validation.exact(m, {
            'success',
            'operation',
            'version',
            'mutationId',
            'requestedGoalMl',
            'epoch',
            'appliedRevision',
            'goalMl',
            'goalRevision',
          }) &&
          m['success'] == true &&
          m['operation'] == 'set_water_goal' &&
          m['version'] == 2 &&
          m['mutationId'] == request.mutationId &&
          m['requestedGoalMl'] == request.goalMl &&
          m['epoch'] == request.epoch &&
          WaterV2GoalRequest.validGoal(m['goalMl']) &&
          WaterV2Validation.integer(
            m['goalRevision'],
            1,
            WaterV2Validation.maxRevision,
          ) &&
          WaterV2Validation.integer(
            m['appliedRevision'],
            1,
            m['goalRevision'] is int ? m['goalRevision'] : 0,
          ) &&
          (m['appliedRevision'] != m['goalRevision'] ||
              m['goalMl'] == request.goalMl),
    );
    return WaterV2GoalSuccess._(request, m['goalMl'], m['goalRevision']);
  }
}

/// Preference ACK and outbox ACK share the SQLite commit and session gate.
Future<void> acknowledgeWaterGoal(
  AppDatabase db,
  SyncQueueTableData item,
  WaterV2GoalSuccess result,
  LocalMutationTicket ticket,
  RemoteSendPermit permit,
) async {
  await db.transactionWithCommitGuard(
    () async {
      permit.requireCurrent();
      final row = await (db.select(
        db.syncQueueTable,
      )..where((t) => t.id.equals(item.id))).getSingle();
      final request = WaterV2GoalRequest.fromQueue(
        result.request.ownerUid,
        row,
      );
      if (jsonEncode(request.toJson()) != jsonEncode(result.request.toJson()))
        throw StateError('WATER_QUEUE_CONFLICT');
      final old = await (db.select(
        db.waterV2Preferences,
      )..where((t) => t.ownerUid.equals(request.ownerUid))).getSingleOrNull();
      if (old == null || old.epoch != request.epoch)
        throw StateError('WATER_EPOCH_CONFLICT');
      if (old.revision == result.revision && old.goalMl != result.goalMl)
        throw StateError('WATER_SNAPSHOT_CONFLICT');
      if (old.revision < result.revision)
        await (db.update(
          db.waterV2Preferences,
        )..where((t) => t.ownerUid.equals(request.ownerUid))).write(
          WaterV2PreferencesCompanion(
            goalMl: Value(result.goalMl),
            revision: Value(result.revision),
          ),
        );
      await db.markSyncItemAsSucceeded(item.id, request.ownerUid);
    },
    admission: ticket,
    validateBeforeCommit: permit.requireCurrent,
  );
}
