import 'package:drift/drift.dart';
import '../network/generational_http_transport.dart';
import '../network/generational_http_store.dart';
import 'dart:async';
import 'dart:convert';
import 'trusted_account_access.dart';
import 'package:crypto/crypto.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'package:life_os/core/database/app_database.dart';

import 'sync_operation_result.dart';
import 'legacy_water_queue.dart';
import 'water_v2_contract.dart';
import '../database/remote_send_permit.dart';
import 'package:life_os/features/notifications/domain/models/notification_occurrence.dart';
import 'package:life_os/features/notifications/domain/models/notification_model.dart';

abstract interface class SyncRemoteDataSource {
  Future<SyncOperationResult> process(String uid, SyncQueueTableData item);
}

/// Allows a manager to pass its captured processing generation to producers.
abstract interface class SessionBoundSyncRemoteDataSource
    implements SyncRemoteDataSource {
  Future<SyncOperationResult> processForSession(
    String uid,
    SyncQueueTableData item, {
    required bool Function() canSend,
  });
}

/// Classification uses only the original operation contract, never its payload
/// or attempt metadata. The same record remains recognizable after restart.
abstract final class LegacyStudyInfoOperation {
  static const holdCode = 'STUDY_INFO_LEGACY_HOLD';

  static bool isBlocked(SyncQueueTableData item) =>
      item.collection.trim() == 'study_info' &&
      item.docId.trim() == 'main' &&
      const {
        'create',
        'update',
      }.contains(item.operationType.trim().toLowerCase());
}

typedef SyncAppCheckTokenProvider = Future<String?> Function();

/// A persisted domain failure is a local HOLD, not another send attempt.
/// Match the operation family as well as the code; unrelated 409s stay terminal.
abstract final class StudyStateHoldOperation {
  static String? forBackendOperation(Object? operation) => switch (operation) {
    'apply_study_review' => 'STUDY_REVIEW_STATE_INVALID',
    'delete_subject' => 'STUDY_REVIEW_QUEUE_STATE_INVALID',
    _ => null,
  };

  static bool isReview(SyncQueueTableData item) =>
      item.collection.trim() == 'review_queue' &&
      item.operationType.trim().toLowerCase() == 'update';

  static bool isSubjectDelete(SyncQueueTableData item) =>
      item.collection.trim() == 'subjects' &&
      item.operationType.trim().toLowerCase() == 'delete';

  static bool matches(SyncQueueTableData item, String? code) =>
      code != null &&
      ((isReview(item) && code == forBackendOperation('apply_study_review')) ||
          (isSubjectDelete(item) &&
              code == forBackendOperation('delete_subject')));

  static bool isHeld(SyncQueueTableData item) =>
      item.status == SyncQueuePersistenceStatus.pending &&
      matches(item, item.lastErrorCode);

  // Older transports lost the backend code. Do not infer which remote effects
  // occurred, requeue the row or treat it as a failed creation.
  static bool isHistoricalRejected(SyncQueueTableData item) =>
      item.status == SyncQueuePersistenceStatus.rejected &&
      (isReview(item) || isSubjectDelete(item));
}

class FirestoreSyncRemoteDataSource
    implements SessionBoundSyncRemoteDataSource {
  static final RegExp _uuidV4Pattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    caseSensitive: false,
  );

  final Set<String>? allowedCollections;
  final GenerationalHttpTransport? trustedTransport;
  static final Object _httpQueueRow = Object();
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;
  final http.Client Function() _clientFactory;
  final Future<String?> Function(User user, bool forceRefresh)?
  _idTokenProvider;
  final SyncAppCheckTokenProvider _appCheckTokenProvider;
  final Duration _requestTimeout;
  final RemoteSendPermit Function(String uid)? _captureRemoteSend;
  final Future<void> Function()? beforeNotificationDelete;

  FirestoreSyncRemoteDataSource(
    this._firestore,
    this._auth, {
    this.beforeNotificationDelete,
    this.trustedTransport,
    this.allowedCollections,
    RemoteSendPermit Function(String uid)? captureRemoteSend,
    http.Client Function()? clientFactory,
    Future<String?> Function(User user, bool forceRefresh)? idTokenProvider,
    SyncAppCheckTokenProvider? appCheckTokenProvider,
    Duration requestTimeout = const Duration(seconds: 15),
  }) : _clientFactory = clientFactory ?? http.Client.new,
       // ignore: prefer_initializing_formals
       _captureRemoteSend = captureRemoteSend,
       // ignore: prefer_initializing_formals
       _idTokenProvider = idTokenProvider,
       _appCheckTokenProvider =
           appCheckTokenProvider ??
           (() => FirebaseAppCheck.instance.getToken()),
       // ignore: prefer_initializing_formals
       _requestTimeout = requestTimeout;

  static const String _backendSyncUrl = String.fromEnvironment(
    'LIFE_OS_SYNC_BACKEND_URL',
    defaultValue: 'https://life-os-backend-gray.vercel.app/api/sync',
  );

  static Uri get backendSyncUri => Uri.parse(_backendSyncUrl);

  @override
  Future<SyncOperationResult> process(String uid, SyncQueueTableData item) =>
      processForSession(uid, item, canSend: () => true);

  @override
  Future<SyncOperationResult> processForSession(
    String uid,
    SyncQueueTableData item, {
    required bool Function() canSend,
  }) => runZoned(
    () => _processBound(uid, item, canSend: canSend),
    zoneValues: {_httpQueueRow: item},
  );

  Future<SyncOperationResult> _processBound(
    String uid,
    SyncQueueTableData item, {
    required bool Function() canSend,
  }) async {
    final permit = RemoteSendPermit(
      () => canSend() && _auth.currentUser?.uid == uid,
    );
    final collection = item.collection.trim();
    if (allowedCollections != null && !allowedCollections!.contains(collection)) {
      return const SyncOperationResult.retryable(code: 'SYNC_FAMILY_CLOSED', preserveQueueState: true);
    }
    final docId = item.docId.trim();
    final operationType = item.operationType.trim().toLowerCase();

    // Explicit V2 work never falls through to generic Firestore writes.
    if (WaterV2Queue.isWater(item)) {
      return const SyncOperationResult.retryable(code: 'WATER_V2_DISABLED');
    }

    // Defense in depth for callers outside SyncManager; no SDK/HTTP or false ACK.
    if (LegacyWaterQueue.isBlocked(item)) {
      return const SyncOperationResult.retryable(code: 'LEGACY_WATER_BLOCKED');
    }

    // Also protect direct callers: no SDK access, payload decode, or HTTP fallback.
    if (LegacyStudyInfoOperation.isBlocked(item)) {
      return const SyncOperationResult.retryable(
        code: LegacyStudyInfoOperation.holdCode,
      );
    }

    if (StudyStateHoldOperation.isHeld(item)) {
      return SyncOperationResult.retryable(code: item.lastErrorCode);
    }

    if (collection.isEmpty || docId.isEmpty) {
      return const SyncOperationResult.invalidPayload(
        message: 'Collection ou docId inválidos.',
      );
    }

    if (!{
      'create',
      'update',
      'delete',
      'batch_delete',
    }.contains(operationType)) {
      return const SyncOperationResult.unsupportedOperation(
        message: 'OperationType não suportado.',
      );
    }

    try {
      if (trustedTransport == null && TrustedAccountAccess.localSessionClosed) {
        return const SyncOperationResult.retryable(
          code: 'TRUSTED_LOCAL_SESSION_CLOSED',
        );
      }
      if (trustedTransport == null)
        await TrustedAccountAccess.ensureReady(
          _auth,
          _firestore,
          uid,
          allowBootstrap: false,
        );
      permit.requireCurrent();
      if (trustedTransport != null &&
          !(({'tasks', 'habits'}.contains(collection) &&
                  {'create', 'update', 'delete'}.contains(operationType)) ||
              {'transactions', 'medications'}.contains(collection) &&
                  {'create', 'delete'}.contains(operationType) ||
              collection == 'goals' && {'create','update','delete'}.contains(operationType) ||
              collection == 'subjects' && operationType == 'create' ||
              collection == 'review_queue' &&
                  {'create', 'update'}.contains(operationType) ||
              {'study_activity', 'study_progress_reset'}.contains(collection) &&
                  operationType == 'create' ||
              collection == 'checkins' && operationType == 'update' ||
              collection == 'notifications' && operationType == 'delete' ||
              collection == 'batch' && operationType == 'batch_delete')) {
        return const SyncOperationResult.retryable(
          code: 'HTTP_CUSTODY_ROUTE_CLOSED',
        );
      }
      if (collection == 'checkins' && operationType == 'update') {
        final data = _decodePayload(item.payloadJson);
        final revision = data['localRowId'];
        if (revision is! int || revision <= 0) {
          return const SyncOperationResult.retryable(
            code: 'CHECKIN_LOCAL_REVISION_REQUIRED',
            preserveQueueState: true,
          );
        }
        final transport = trustedTransport;
        if (transport == null) {
          return const SyncOperationResult.retryable(
            code: 'HTTP_CUSTODY_ROUTE_CLOSED',
            preserveQueueState: true,
          );
        }
        final payload = <String, dynamic>{
          'operation': 'upsert_checkin',
          'checkInId': docId,
          'energy': data['energy'],
          'focus': data['focus'],
          'motivation': data['motivation'],
        };
        return _postToSyncBackend(
          uid,
          permit,
          payload,
          validateDomainResponse: (response) {
            if (response['success'] != true ||
                response['operation'] != 'upsert_checkin' ||
                response['checkInId'] != docId ||
                response['energy'] != data['energy'] ||
                response['focus'] != data['focus'] ||
                response['motivation'] != data['motivation']) {
              throw const HttpCustodyException('CHECKIN_ACK_INVALID');
            }
          },
          acknowledgeDomain: () async {
            final db = transport.store.database,
                table = db.checkInTable,
                q = db.syncQueueTable;
            final newer =
                await (db.select(q)
                      ..where(
                        (t) =>
                            t.ownerUid.equals(uid) &
                            t.collection.equals('checkins') &
                            t.docId.equals(docId) &
                            t.id.isBiggerThanValue(item.id),
                      )
                      ..limit(1))
                    .get();
            if (newer.isNotEmpty) return;
            await (db.update(table)..where(
                  (t) =>
                      t.id.equals(docId) &
                      t.rowId.equals(revision) &
                      t.isSynced.equals(false),
                ))
                .write(const CheckInTableCompanion(isSynced: Value(true)));
          },
        );
      }
      if (collection == 'notifications' && operationType == 'delete') {
        if (item.ownerUid?.trim() != uid || _auth.currentUser?.uid != uid) {
          return const SyncOperationResult.retryable(code: 'SESSION_STOPPED');
        }
        final expectedKey = _decodePayload(item.payloadJson)['occurrenceKey'];
        if (!NotificationOccurrence.isKeyForId(expectedKey, docId)) {
          return const SyncOperationResult.invalidPayload(
            message: 'Notification delete requires its occurrenceKey',
          );
        }
        if (trustedTransport != null) {
          permit.requireCurrent();
          await beforeNotificationDelete?.call();
          permit.requireCurrent();
          return _postToSyncBackend(
            uid,
            permit,
            {
              'operation': 'delete_notification',
              'notificationId': docId,
              'occurrenceKey': expectedKey,
            },
            validateDomainResponse: (response) {
              if (response['success'] != true ||
                  response['operation'] != 'delete_notification' ||
                  response['notificationId'] != docId ||
                  response['occurrenceKey'] != expectedKey ||
                  !{
                    'DELETED',
                    'ABSENT',
                    'OBSOLETE',
                  }.contains(response['outcome'])) {
                throw const HttpCustodyException(
                  'NOTIFICATION_DELETE_ACK_INVALID',
                );
              }
            },
          );
        }
        final sessionPermit = _captureOperationPermit(uid, permit);
        try {
          sessionPermit.requireCurrent();
          await beforeNotificationDelete?.call();
          final ref = _firestore
              .collection('users')
              .doc(uid)
              .collection('notifications')
              .doc(docId);
          // No await between final admission and starting the transaction.
          sessionPermit.requireCurrent();
          final confirmed = await _firestore.runTransaction<bool>((
            transaction,
          ) async {
            // Firestore retries this callback; retain the original admission.
            // This also checks immediately before the first remote read.
            sessionPermit.requireCurrent();
            final snapshot = await transaction.get(ref);
            sessionPermit.requireCurrent();
            // A cached/pending local snapshot cannot confirm a remote no-op.
            if (!_isServerConfirmed(snapshot)) return false;
            if (!snapshot.exists) return true;
            final remote = NotificationModel.fromFirestore(snapshot);
            final remoteKey = NotificationOccurrence.key(
              id: docId,
              moduleType: remote.moduleType,
              dueDate: remote.dueDate,
            );
            if (remoteKey == null) {
              throw const FormatException(
                'Remote notification has no occurrence contract',
              );
            }
            // A different occurrence makes this old operation logically obsolete.
            if (remoteKey == expectedKey) {
              sessionPermit.requireCurrent();
              transaction.delete(ref);
            }
            return true;
          });
          sessionPermit.requireCurrent();
          if (!confirmed) {
            return const SyncOperationResult.retryable(
              code: 'FIRESTORE_RESULT_UNCONFIRMED',
            );
          }
          return const SyncOperationResult.success();
        } catch (_) {
          // A failed await must not turn canceled work into a permanent reject.
          sessionPermit.requireCurrent();
          rethrow;
        }
      }
      // ----------------------------------------------------------------------
      // CREATE DE HÁBITO
      // Obrigatoriamente passa pelo backend para enforcement de quota.
      // ----------------------------------------------------------------------
      if (collection == 'habits' && operationType == 'create') {
        return _createHabitServerSide(
          expectedUid: uid,
          item: item,
          permit: permit,
        );
      }

      if (collection == 'habits' && operationType == 'update') {
        return _updateHabitServerSide(
          expectedUid: uid,
          item: item,
          permit: permit,
        );
      }

      if (collection == 'tasks' && operationType == 'create') {
        return _createTaskServerSide(
          expectedUid: uid,
          item: item,
          permit: permit,
        );
      }

      if (collection == 'tasks' && operationType == 'update') {
        return _updateTaskServerSide(
          expectedUid: uid,
          item: item,
          permit: permit,
        );
      }

      if (collection == 'tasks' && operationType == 'delete') {
        return _deleteTaskServerSide(
          expectedUid: uid,
          item: item,
          permit: permit,
        );
      }

      // ----------------------------------------------------------------------
      // CREATE DE GOALS
      // Obrigatoriamente passa pelo backend para enforcement de quota.
      // ----------------------------------------------------------------------

      if (collection == 'goals' && operationType == 'create') {
        return _createGoalServerSide(
          expectedUid: uid,
          item: item,
          permit: permit,
        );
      }

      if (collection == 'goals' && operationType == 'update' && trustedTransport != null) {
        final data = _decodePayload(item.payloadJson), value=data['currentValue'];
        if (data.keys.any((key)=>!const {'currentValue','lastReset'}.contains(key)) || value is! int || value < 0 || value > 9007199254740991 ||
            (data.containsKey('lastReset') && (data['lastReset'] is! String || DateTime.tryParse(data['lastReset'] as String)==null))) {
          throw const FormatException('Invalid goal update');
        }
        return _postToSyncBackend(uid,permit,{'operation':'update_goal','goalId':docId,'currentValue':value,if(data.containsKey('lastReset'))'lastReset':data['lastReset']},
          validateDomainResponse:(response){
            if(response['success']!=true || response['operation']!='update_goal' || response['goalId']!=docId || response['currentValue']!=value || !const {'UPDATED','ABSENT','DELETED'}.contains(response['outcome'])) throw const HttpCustodyException('GOAL_ACK_INVALID');
          });
      }
      if (collection == 'goals' && operationType == 'delete') {
        return _deleteGoalServerSide(
          expectedUid: uid,
          item: item,
          permit: permit,
        );
      }

      // ----------------------------------------------------------------------
      // CREATE DE SUBJECTS
      // Obrigatoriamente passa pelo backend para enforcement de quota.
      // ----------------------------------------------------------------------

      if (collection == 'subjects' && operationType == 'create') {
        return _createSubjectServerSide(
          expectedUid: uid,
          item: item,
          permit: permit,
        );
      }

      if (collection == 'subjects' && operationType == 'delete') {
        return _deleteSubjectServerSide(
          expectedUid: uid,
          item: item,
          permit: permit,
        );
      }

      if (collection == 'study_activity' && operationType == 'create') {
        return _applyStudyActivityServerSide(
          expectedUid: uid,
          item: item,
          permit: permit,
        );
      }

      if (collection == 'study_progress_reset' && operationType == 'create') {
        return _applyStudyProgressResetServerSide(
          expectedUid: uid,
          item: item,
          permit: permit,
        );
      }

      if (collection == 'review_queue' && operationType == 'create') {
        return await _createReviewCardServerSide(
          expectedUid: uid,
          item: item,
          permit: permit,
        );
      }

      if (collection == 'review_queue' && operationType == 'update') {
        return _applyStudyReviewServerSide(
          expectedUid: uid,
          item: item,
          permit: permit,
        );
      }

      // ----------------------------------------------------------------------
      // CREATE DE MEDICATIONS
      // Obrigatoriamente passa pelo backend para enforcement de quota.
      // ----------------------------------------------------------------------

      if (collection == 'medications' && operationType == 'create') {
        return _createMedicationServerSide(
          expectedUid: uid,
          item: item,
          permit: permit,
        );
      }

      if (collection == 'medications' && operationType == 'delete') {
        return _deleteMedicationServerSide(
          expectedUid: uid,
          item: item,
          permit: permit,
        );
      }

      // ----------------------------------------------------------------------
      // CREATE DE TRANSACTIONS
      // Obrigatoriamente passa pelo backend para enforcement de quota.
      // ----------------------------------------------------------------------

      if (collection == 'transactions' && operationType == 'create') {
        return _createTransactionServerSide(
          expectedUid: uid,
          item: item,
          permit: permit,
        );
      }

      if (collection == 'transactions' && operationType == 'delete') {
        return _deleteTransactionServerSide(
          expectedUid: uid,
          item: item,
          permit: permit,
        );
      }
      // ----------------------------------------------------------------------
      // DELETE DE HÁBITO
      // A operação batch_delete do hábito também passa pelo backend,
      // pois precisa manter habitsCount consistente.
      // ----------------------------------------------------------------------
      if (collection == 'batch' && operationType == 'batch_delete') {
        return _deleteHabitServerSide(
          expectedUid: uid,
          item: item,
          permit: permit,
        );
      }

      // ----------------------------------------------------------------------
      // OPERAÇÕES FIRESTORE NORMAIS
      // Updates competitivos de Task/Habit são tratados acima pelo backend.
      // ----------------------------------------------------------------------
      if (collection == 'focus_logs' &&
          operationType == 'create' &&
          !_uuidV4Pattern.hasMatch(docId)) {
        return const SyncOperationResult.invalidPayload(
          message: 'Documento de foco inválido.',
        );
      }

      final documentRef = _firestore
          .collection('users')
          .doc(uid)
          .collection(collection)
          .doc(docId);

      if (collection == 'focus_logs' && operationType == 'create') {
        final data = _decodePayload(item.payloadJson);
        await documentRef.set(_prepareFocusLogCreatePayload(data));
        return const SyncOperationResult.success();
      }

      if (collection == 'study_info' &&
          (operationType == 'create' || operationType == 'update')) {
        // main was held before reaching any SDK access. Other IDs retain
        // their existing definitive validation error.
        return const SyncOperationResult.invalidPayload(
          message: 'Documento de informações de estudo inválido.',
        );
      }

      switch (operationType) {
        case 'create':
        case 'update':
          final data = _decodePayload(item.payloadJson);

          if (collection == 'health_info') {
            await documentRef.set(
              _prepareHealthPayload(data),
              SetOptions(merge: true),
            );
            return const SyncOperationResult.success();
          }

          if (operationType == 'create') {
            await documentRef.set(data);
          } else {
            await documentRef.update(
              collection == 'goals' ? _prepareGoalUpdatePayload(data) : data,
            );
          }

          return const SyncOperationResult.success();

        case 'delete':
          await documentRef.delete();

          return const SyncOperationResult.success();

        case 'batch_delete':
          return const SyncOperationResult.unsupportedOperation(
            message: 'batch_delete não suportado para esta coleção.',
          );
      }

      return const SyncOperationResult.unsupportedOperation(
        message: 'OperationType não suportado.',
      );
    } on TrustedAccountPending catch (error) {
      // Preserve the queue without an ACK or a remote write while closed.
      return SyncOperationResult.retryable(code: error.code);
    } on FirebaseException catch (error) {
      if (collection == 'health_info' &&
          (error.code == 'permission-denied' ||
              error.code == 'unauthenticated')) {
        return SyncOperationResult.retryable(code: error.code.toUpperCase());
      }

      if (operationType == 'update' && error.code == 'not-found') {
        return SyncOperationResult.invalidPayload(
          message:
              'FIRESTORE_NOT_FOUND: '
              '${error.message ?? 'Documento não encontrado para atualização.'}',
        );
      }

      return _mapFirebaseError(error);
    } on RemoteSessionStopped {
      return const SyncOperationResult.retryable(code: 'SESSION_STOPPED');
    } on TimeoutException {
      return const SyncOperationResult.retryable(code: 'SYNC_TIMEOUT');
    } on FormatException catch (error) {
      return SyncOperationResult.invalidPayload(message: error.message);
    } catch (error) {
      return SyncOperationResult.retryable(
        message: error.toString(),
        code: 'UNEXPECTED_SYNC_ERROR',
      );
    }
  }

  Map<String, dynamic> _prepareFocusLogCreatePayload(
    Map<String, dynamic> data,
  ) {
    if (!_hasExactFields(data, const {
      'targetId',
      'targetType',
      'durationSeconds',
      'timestamp',
    })) {
      throw const FormatException('Payload de foco inválido.');
    }

    final targetId = data['targetId'];
    final targetType = data['targetType'];
    final durationSeconds = data['durationSeconds'];
    final timestamp = data['timestamp'];
    final parsedTimestamp = timestamp is String
        ? DateTime.tryParse(timestamp)
        : null;
    if (targetId is! String ||
        targetId.trim().isEmpty ||
        targetId.length > 128 ||
        (targetType != 'TASK' && targetType != 'SUBJECT') ||
        durationSeconds is! int ||
        durationSeconds <= 0 ||
        parsedTimestamp == null ||
        !parsedTimestamp.isUtc ||
        !timestamp.endsWith('Z')) {
      throw const FormatException('Payload de foco inválido.');
    }

    return {
      'targetId': targetId,
      'targetType': targetType,
      'durationSeconds': durationSeconds,
      'timestamp': Timestamp.fromDate(parsedTimestamp),
    };
  }

  // v1 is prospective. Legacy queue rows must never acquire a new identity,
  // timestamp, receipt or Client SDK fallback merely because they are retried.
  Future<SyncOperationResult> _createReviewCardServerSide({
    required String expectedUid,
    required SyncQueueTableData item,
    required RemoteSendPermit permit,
  }) async {
    final Map<String, dynamic> data;
    try {
      data = _decodePayload(item.payloadJson);
    } on FormatException {
      return const SyncOperationResult.retryable(
        code: 'REVIEW_CREATE_LEGACY_UNVERIFIED',
      );
    }
    if (data['creationProtocolVersion'] is! int ||
        data['creationProtocolVersion'] != 1) {
      return const SyncOperationResult.retryable(
        code: 'REVIEW_CREATE_LEGACY_UNVERIFIED',
      );
    }
    if (item.ownerUid != expectedUid || !permit.isCurrent) {
      return const SyncOperationResult.retryable(code: 'SESSION_STOPPED');
    }
    const fields = {
      'creationProtocolVersion',
      'cardId',
      'subjectId',
      'question',
      'answer',
      'createdAt',
    };
    final id = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$');
    final cardId = data['cardId'];
    final subjectId = data['subjectId'];
    final createdAt = data['createdAt'];
    if (!_hasExactFields(data, fields) ||
        cardId is! String ||
        !id.hasMatch(cardId) ||
        cardId != item.docId ||
        subjectId is! String ||
        !id.hasMatch(subjectId) ||
        !_reviewText(data['question']) ||
        !_reviewText(data['answer']) ||
        createdAt is! String ||
        !_reviewUtc(createdAt) ||
        !_wellFormedReviewText(expectedUid)) {
      return const SyncOperationResult.invalidPayload(
        message: 'Payload de criação de flashcard inválido.',
      );
    }
    final payload = <String, dynamic>{
      'operation': 'create_review_card',
      'version': 1,
      'cardId': cardId,
      'subjectId': subjectId,
      'question': data['question'],
      'answer': data['answer'],
      'createdAt': createdAt,
    };
    if (utf8.encode(jsonEncode(payload)).length > 512 * 1024) {
      return const SyncOperationResult.invalidPayload(
        code: 'REVIEW_CREATE_PAYLOAD_TOO_LARGE',
      );
    }
    final frame = <int>[];
    for (final value in <String>[
      'review-create-v1',
      expectedUid,
      cardId,
      subjectId,
      data['question'] as String,
      data['answer'] as String,
      createdAt,
    ]) {
      final bytes = utf8.encode(value);
      frame
        ..addAll(ascii.encode('${bytes.length}:'))
        ..addAll(bytes);
    }
    return _postToSyncBackend(
      expectedUid,
      permit,
      payload,
      reviewCreateFingerprint: sha256.convert(frame).toString(),
      reviewCreateCardId: cardId,
    );
  }

  bool _wellFormedReviewText(String text) {
    final units = text.codeUnits;
    for (var i = 0; i < units.length; i++) {
      final unit = units[i];
      if (unit >= 0xd800 && unit <= 0xdbff) {
        if (++i >= units.length || units[i] < 0xdc00 || units[i] > 0xdfff) {
          return false;
        }
      } else if (unit >= 0xdc00 && unit <= 0xdfff) {
        return false;
      }
    }
    return true;
  }

  bool _reviewText(Object? text) =>
      text is String && text.trim().isNotEmpty && _wellFormedReviewText(text);

  bool _reviewUtc(String text) {
    if (!RegExp(
      r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}(\d{3})?Z$',
    ).hasMatch(text))
      return false;
    final date = DateTime.tryParse(text);
    return date != null &&
        date.year >= 1 &&
        date.year <= 9999 &&
        date.isUtc &&
        date.toIso8601String() == text;
  }

  bool _validReviewCreateAck(
    String body,
    String uid,
    String cardId,
    String fingerprint,
  ) {
    try {
      final data = jsonDecode(body);
      return data is Map<String, dynamic> &&
          _hasExactFields(data, const {
            'success',
            'operation',
            'version',
            'uid',
            'operationId',
            'fingerprint',
            'outcome',
            'effectsCommitted',
          }) &&
          data['success'] == true &&
          data['operation'] == 'create_review_card' &&
          data['version'] is int &&
          data['version'] == 1 &&
          data['uid'] == uid &&
          data['operationId'] == cardId &&
          data['fingerprint'] == fingerprint &&
          (data['outcome'] == 'APPLIED' || data['outcome'] == 'REPLAYED') &&
          data['effectsCommitted'] == true;
    } on FormatException {
      return false;
    }
  }

  bool _hasExactFields(Map<String, dynamic> data, Set<String> fields) {
    return data.length == fields.length && data.keys.every(fields.contains);
  }

  Timestamp _parseQueuedTimestamp(Object? value, {required String fieldName}) {
    final parsed = value is String ? DateTime.tryParse(value) : null;
    if (parsed == null) {
      throw FormatException('$fieldName inválida.');
    }
    return Timestamp.fromDate(parsed);
  }

  Map<String, dynamic> _prepareGoalUpdatePayload(Map<String, dynamic> data) {
    if (data.isEmpty ||
        data.keys.any((key) => key != 'currentValue' && key != 'lastReset')) {
      throw const FormatException('Payload de atualização de meta inválido.');
    }

    final currentValue = data['currentValue'];
    if (data.containsKey('currentValue') && currentValue is! int) {
      throw const FormatException('Progresso da meta inválido.');
    }

    final prepared = Map<String, dynamic>.from(data);
    if (data.containsKey('lastReset')) {
      final rawLastReset = data['lastReset'];
      final parsedLastReset = rawLastReset is String
          ? DateTime.tryParse(rawLastReset)
          : null;
      if (parsedLastReset == null) {
        throw const FormatException('Data de reset da meta inválida.');
      }
      prepared['lastReset'] = Timestamp.fromDate(parsedLastReset);
    }

    return prepared;
  }

  Future<SyncOperationResult> _createTransactionServerSide({
    required RemoteSendPermit permit,
    required String expectedUid,
    required SyncQueueTableData item,
  }) async {
    final data = _decodePayload(item.payloadJson);

    final title = data['title'];
    final amount = data['amount'];
    final type = data['type'];
    final category = data['category'];
    final date = data['date'];

    if (title is! String ||
        amount is! num ||
        type is! String ||
        category is! String ||
        date is! String) {
      return const SyncOperationResult.invalidPayload(
        message: 'Payload de criação de transação inválido.',
      );
    }

    return _postToSyncBackend(expectedUid, permit, {
      'operation': 'create_transaction',
      'transactionId': item.docId,
      'title': title,
      'amount': amount.toDouble(),
      'type': type,
      'category': category,
      'date': date,
    });
  }

  Future<SyncOperationResult> _deleteTransactionServerSide({
    required RemoteSendPermit permit,
    required String expectedUid,
    required SyncQueueTableData item,
  }) async {
    return _postToSyncBackend(expectedUid, permit, {
      'operation': 'delete_transaction',
      'transactionId': item.docId,
    });
  }

  Future<SyncOperationResult> _createMedicationServerSide({
    required RemoteSendPermit permit,
    required String expectedUid,
    required SyncQueueTableData item,
  }) async {
    final data = _decodePayload(item.payloadJson);

    final name = data['name'];
    final startDate = data['startDate'];
    final durationDays = data['durationDays'];
    final endDate = data['endDate'];

    if (name is! String ||
        startDate is! String ||
        (durationDays != null && durationDays is! int) ||
        (endDate != null && endDate is! String)) {
      return const SyncOperationResult.invalidPayload(
        message: 'Payload de criação de medicamento inválido.',
      );
    }

    return _postToSyncBackend(expectedUid, permit, {
      'operation': 'create_medication',
      'medicationId': item.docId,
      'name': name,
      'startDate': startDate,
      'durationDays': durationDays,
      'endDate': endDate,
    });
  }

  Future<SyncOperationResult> _deleteMedicationServerSide({
    required RemoteSendPermit permit,
    required String expectedUid,
    required SyncQueueTableData item,
  }) async {
    return _postToSyncBackend(expectedUid, permit, {
      'operation': 'delete_medication',
      'medicationId': item.docId,
    });
  }

  Future<SyncOperationResult> _createSubjectServerSide({
    required RemoteSendPermit permit,
    required String expectedUid,
    required SyncQueueTableData item,
  }) async {
    final data = _decodePayload(item.payloadJson);

    final title = data['title'];
    final hasExam = data['hasExam'];
    final examDate = data['examDate'];

    if (title is! String ||
        hasExam is! bool ||
        (examDate != null && examDate is! String)) {
      return const SyncOperationResult.invalidPayload(
        message: 'Payload de criação de matéria inválido.',
      );
    }

    return _postToSyncBackend(expectedUid, permit, {
      'operation': 'create_subject',
      'subjectId': item.docId,
      'title': title,
      'hasExam': hasExam,
      'examDate': examDate,
    });
  }

  Future<SyncOperationResult> _deleteSubjectServerSide({
    required RemoteSendPermit permit,
    required String expectedUid,
    required SyncQueueTableData item,
  }) async {
    return _postToSyncBackend(expectedUid, permit, {
      'operation': 'delete_subject',
      'subjectId': item.docId,
    });
  }

  Future<SyncOperationResult> _applyStudyActivityServerSide({
    required RemoteSendPermit permit,
    required String expectedUid,
    required SyncQueueTableData item,
  }) async {
    final data = _decodePayload(item.payloadJson);
    if (!_uuidV4Pattern.hasMatch(item.docId) ||
        !_hasExactFields(data, const {
          'subjectId',
          'progressDelta',
          'occurredAt',
          'timeZoneOffsetMinutes',
        })) {
      return const SyncOperationResult.invalidPayload(
        message: 'Payload de atividade de estudo inválido.',
      );
    }

    final subjectId = data['subjectId'];
    final progressDelta = data['progressDelta'];
    final occurredAt = data['occurredAt'];
    final timeZoneOffsetMinutes = data['timeZoneOffsetMinutes'];
    final parsedOccurredAt = occurredAt is String
        ? DateTime.tryParse(occurredAt)
        : null;
    final delta = progressDelta is num ? progressDelta.toDouble() : double.nan;

    if ((subjectId != null &&
            (subjectId is! String ||
                subjectId.trim().isEmpty ||
                subjectId.length > 128 ||
                subjectId.contains('/'))) ||
        !delta.isFinite ||
        delta <= 0 ||
        delta > 1 ||
        parsedOccurredAt == null ||
        timeZoneOffsetMinutes is! int ||
        timeZoneOffsetMinutes < -840 ||
        timeZoneOffsetMinutes > 840) {
      return const SyncOperationResult.invalidPayload(
        message: 'Payload de atividade de estudo inválido.',
      );
    }

    return _postToSyncBackend(expectedUid, permit, {
      'operation': 'apply_study_activity',
      'mutationId': item.docId,
      'subjectId': subjectId,
      'progressDelta': delta,
      'occurredAt': occurredAt,
      'timeZoneOffsetMinutes': timeZoneOffsetMinutes,
    });
  }

  Future<SyncOperationResult> _applyStudyProgressResetServerSide({
    required RemoteSendPermit permit,
    required String expectedUid,
    required SyncQueueTableData item,
  }) async {
    final data = _decodePayload(item.payloadJson);
    final occurredAt = data['occurredAt'];
    final parsedOccurredAt = occurredAt is String
        ? DateTime.tryParse(occurredAt)
        : null;
    if (!_uuidV4Pattern.hasMatch(item.docId) ||
        !_hasExactFields(data, const {'occurredAt'}) ||
        parsedOccurredAt == null ||
        !parsedOccurredAt.isUtc ||
        !occurredAt.endsWith('Z')) {
      return const SyncOperationResult.invalidPayload(
        message: 'Payload de reset de progresso inválido.',
      );
    }

    return _postToSyncBackend(expectedUid, permit, {
      'operation': 'apply_study_progress_reset',
      'mutationId': item.docId,
      'occurredAt': occurredAt,
    });
  }

  Future<SyncOperationResult> _applyStudyReviewServerSide({
    required RemoteSendPermit permit,
    required String expectedUid,
    required SyncQueueTableData item,
  }) async {
    final data = _decodePayload(item.payloadJson);
    final subjectId = data['subjectId'];
    final lastReviewed = data['lastReviewed'];
    final timeZoneOffsetMinutes = data['timeZoneOffsetMinutes'];
    final parsedLastReviewed = lastReviewed is String
        ? DateTime.tryParse(lastReviewed)
        : null;
    if (item.docId.trim().isEmpty ||
        item.docId.length > 128 ||
        item.docId.contains('/') ||
        !_hasExactFields(data, const {
          'subjectId',
          'lastReviewed',
          'timeZoneOffsetMinutes',
        }) ||
        subjectId is! String ||
        subjectId.trim().isEmpty ||
        subjectId.length > 128 ||
        subjectId.contains('/') ||
        parsedLastReviewed == null ||
        !parsedLastReviewed.isUtc ||
        !lastReviewed.endsWith('Z') ||
        timeZoneOffsetMinutes is! int ||
        timeZoneOffsetMinutes < -840 ||
        timeZoneOffsetMinutes > 840) {
      return const SyncOperationResult.invalidPayload(
        message: 'Payload de revisão de estudo inválido.',
      );
    }

    return _postToSyncBackend(expectedUid, permit, {
      'operation': 'apply_study_review',
      'cardId': item.docId,
      'subjectId': subjectId,
      'occurredAt': lastReviewed,
      'timeZoneOffsetMinutes': timeZoneOffsetMinutes,
    });
  }

  Future<SyncOperationResult> _createGoalServerSide({
    required RemoteSendPermit permit,
    required String expectedUid,
    required SyncQueueTableData item,
  }) async {
    final data = _decodePayload(item.payloadJson);

    final title = data['title'];
    final period = data['period'];
    final targetValue = data['targetValue'];
    final createdAt = data['createdAt'];

    if (title is! String ||
        period is! String ||
        targetValue is! int ||
        createdAt is! String) {
      return const SyncOperationResult.invalidPayload(
        message: 'Payload de criação de meta inválido.',
      );
    }

    return _postToSyncBackend(expectedUid, permit, {
      'operation': 'create_goal',
      'goalId': item.docId,
      'title': title,
      'period': period,
      'targetValue': targetValue,
      'createdAt': createdAt,
    });
  }

  Future<SyncOperationResult> _deleteGoalServerSide({
    required RemoteSendPermit permit,
    required String expectedUid,
    required SyncQueueTableData item,
  }) async {
    return _postToSyncBackend(expectedUid, permit, {
      'operation': 'delete_goal',
      'goalId': item.docId,
    });
  }

  Future<SyncOperationResult> _createTaskServerSide({
    required RemoteSendPermit permit,
    required String expectedUid,
    required SyncQueueTableData item,
  }) async {
    final data = _decodePayload(item.payloadJson);

    final title = data['title'];
    final priority = data['priority'];
    final date = data['date'];

    if (title is! String || priority is! String || date is! String) {
      return const SyncOperationResult.invalidPayload(
        message: 'Payload de criação de tarefa inválido.',
      );
    }

    return _postToSyncBackend(expectedUid, permit, {
      'operation': 'create_task',
      'taskId': item.docId,
      'title': title,
      'priority': priority,
      'date': date,
    });
  }

  Future<SyncOperationResult> _updateTaskServerSide({
    required RemoteSendPermit permit,
    required String expectedUid,
    required SyncQueueTableData item,
  }) async {
    final data = _decodePayload(item.payloadJson);
    final isCompleted = data['isCompleted'];

    if (data.length != 1 || isCompleted is! bool) {
      return const SyncOperationResult.invalidPayload(
        message: 'Payload de atualização de tarefa inválido.',
      );
    }

    return _postToSyncBackend(expectedUid, permit, {
      'operation': 'update_task',
      'taskId': item.docId,
      'isCompleted': isCompleted,
    });
  }

  Future<SyncOperationResult> _deleteTaskServerSide({
    required RemoteSendPermit permit,
    required String expectedUid,
    required SyncQueueTableData item,
  }) async {
    return _postToSyncBackend(expectedUid, permit, {
      'operation': 'delete_task',
      'taskId': item.docId,
    });
  }

  Future<SyncOperationResult> _createHabitServerSide({
    required RemoteSendPermit permit,
    required String expectedUid,
    required SyncQueueTableData item,
  }) async {
    final data = _decodePayload(item.payloadJson);

    final title = data['title'];
    final completedDates = data['completedDates'];

    if (title is! String || completedDates is! List) {
      return const SyncOperationResult.invalidPayload(
        message: 'Payload de criação de hábito inválido.',
      );
    }

    return _postToSyncBackend(expectedUid, permit, {
      'operation': 'create_habit',
      'habitId': item.docId,
      'title': title,
      'completedDates': completedDates,
    });
  }

  Future<SyncOperationResult> _updateHabitServerSide({
    required RemoteSendPermit permit,
    required String expectedUid,
    required SyncQueueTableData item,
  }) async {
    final data = _decodePayload(item.payloadJson);
    final completedDates = data['completedDates'];
    final competitiveCompletionId = data['competitiveCompletionId'];

    if (completedDates is! List ||
        !completedDates.every((date) => date is String)) {
      return const SyncOperationResult.invalidPayload(
        message: 'Payload de atualização de hábito inválido.',
      );
    }

    if (competitiveCompletionId != null) {
      if (data.length != 2 ||
          competitiveCompletionId is! String ||
          !_uuidV4Pattern.hasMatch(competitiveCompletionId)) {
        return const SyncOperationResult.invalidPayload(
          message: 'Payload de conclusão competitiva inválido.',
        );
      }

      return _postToSyncBackend(expectedUid, permit, {
        'operation': 'update_habit_completion',
        'habitId': item.docId,
        'completedDates': completedDates,
        'competitiveCompletionId': competitiveCompletionId,
      });
    }

    if (data.length != 1) {
      return const SyncOperationResult.invalidPayload(
        message: 'Payload de atualização de hábito inválido.',
      );
    }

    return _postToSyncBackend(expectedUid, permit, {
      'operation': 'update_habit',
      'habitId': item.docId,
      'completedDates': completedDates,
    });
  }

  Future<SyncOperationResult> _deleteHabitServerSide({
    required RemoteSendPermit permit,
    required String expectedUid,
    required SyncQueueTableData item,
  }) async {
    final data = _decodePayload(item.payloadJson);
    final deletes = data['deletes'];

    if (deletes is! List || deletes.isEmpty) {
      return const SyncOperationResult.invalidPayload(
        message: 'Payload de exclusão de hábito inválido.',
      );
    }

    final hasHabitDelete = deletes.any(
      (entry) =>
          entry is Map &&
          entry['collection'] == 'habits' &&
          entry['docId'] == item.docId,
    );

    if (!hasHabitDelete) {
      return const SyncOperationResult.invalidPayload(
        message: 'Payload não contém a exclusão do hábito esperado.',
      );
    }

    return _postToSyncBackend(expectedUid, permit, {
      'operation': 'delete_habit',
      'habitId': item.docId,
    });
  }

  /// Compose account admission with the manager's captured execution generation.
  /// Capture once before preflight and retain it across transaction/HTTP retries.
  RemoteSendPermit _captureOperationPermit(
    String expectedUid,
    RemoteSendPermit operationPermit,
  ) => (_captureRemoteSend?.call(expectedUid) ?? RemoteSendPermit(() => false))
      .and(() => operationPermit.isCurrent);

  Future<SyncOperationResult> _postToSyncBackend(
    String expectedUid,
    RemoteSendPermit operationPermit,
    Map<String, dynamic> payload, {
    String? reviewCreateFingerprint,
    String? reviewCreateCardId,
    void Function(Map<String, dynamic>)? validateDomainResponse,
    Future<void> Function()? acknowledgeDomain,
  }) async {
    final transport = trustedTransport;
    if (transport != null) {
      var committed = false;
      try {
        operationPermit.requireCurrent();
        final row = Zone.current[_httpQueueRow] as SyncQueueTableData?;
        if (row == null ||
            row.ownerUid != expectedUid ||
            transport.store.identity.uid != expectedUid)
          throw const HttpCustodyException('HTTP_QUEUE_BINDING_REQUIRED');
        final intent = await transport.store.prepare(
          stableKey: 'sync/${row.id}',
          route: 'sync',
          body: payload,
          syncRow: row,
        );
        operationPermit.requireCurrent();
        await transport.send(
          intent,
          acknowledgeDomain: acknowledgeDomain,
          validateResponse: (response) {
            validateDomainResponse?.call(response);
            if (reviewCreateFingerprint != null &&
                !_validReviewCreateAck(
                  jsonEncode(response),
                  expectedUid,
                  reviewCreateCardId!,
                  reviewCreateFingerprint,
                )) {
              throw const HttpCustodyException('REVIEW_CREATE_ACK_INVALID');
            }
          },
        );
        committed = true;
        operationPermit.requireCurrent();
        return const SyncOperationResult.success(acknowledgedByTransport: true);
      } catch (error) {
        if (committed || error is HttpCustodyException && error.acknowledged) {
          return const SyncOperationResult.success(
            acknowledgedByTransport: true,
            sessionStopped: true,
          );
        }
        return SyncOperationResult.retryable(
          code: error is HttpCustodyException
              ? error.code
              : error is StateError &&
                    error.message == 'HTTP_LEGACY_INTENT_REVIEW_REQUIRED'
              ? 'HTTP_LEGACY_INTENT_REVIEW_REQUIRED'
              : 'HTTP_CUSTODY_PENDING',
          preserveQueueState: true,
          sessionStopped:
              !transport.lease.isCurrent ||
              error is RemoteSessionStopped ||
              error is HttpCustodyException &&
                  error.code == 'HTTP_SESSION_CHANGED',
        );
      }
    }
    http.Client? client;
    try {
      // All backend operations share prepared-session admission; direct
      // Firestore paths retain their existing contracts.
      final permit = _captureOperationPermit(expectedUid, operationPermit);
      permit.requireCurrent();
      final token = await _getIdToken(
        expectedUid: expectedUid,
        forceRefresh: false,
      );

      permit.requireCurrent();
      if (token == null || token.trim().isEmpty) {
        return const SyncOperationResult.retryable(
          code: 'AUTHENTICATION_REQUIRED',
        );
      }

      String? rawAppCheckToken;
      try {
        rawAppCheckToken = await _appCheckTokenProvider();
      } catch (_) {
        return const SyncOperationResult.retryable(code: 'APP_CHECK_REQUIRED');
      }

      permit.requireCurrent();
      final appCheckToken = rawAppCheckToken?.trim();
      if (appCheckToken == null || appCheckToken.isEmpty) {
        return const SyncOperationResult.retryable(code: 'APP_CHECK_REQUIRED');
      }

      final requestClient = _clientFactory();
      client = requestClient;
      Future<http.Response> send(String idToken) {
        final url = Uri.parse(_backendSyncUrl);
        final headers = {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $idToken',
          'X-Firebase-AppCheck': appCheckToken,
        };
        final body = jsonEncode(payload);
        // No await between this check and starting the HTTP request.
        permit.requireCurrent();
        return requestClient
            .post(url, headers: headers, body: body)
            .timeout(_requestTimeout);
      }

      var response = await send(token);
      permit.requireCurrent();

      if (response.statusCode == 401) {
        final backendCode = _extractBackendCode(response.body);
        if (_isAppCheckCode(backendCode)) {
          return SyncOperationResult.retryable(code: backendCode);
        }

        final refreshedToken = await _getIdToken(
          expectedUid: expectedUid,
          forceRefresh: true,
        );

        permit.requireCurrent();
        if (refreshedToken == null || refreshedToken.trim().isEmpty) {
          return const SyncOperationResult.retryable(
            code: 'AUTHENTICATION_REQUIRED',
          );
        }

        response = await send(refreshedToken);
        permit.requireCurrent();
      }

      if (response.statusCode >= 200 && response.statusCode < 300) {
        if (reviewCreateFingerprint != null &&
            !_validReviewCreateAck(
              response.body,
              expectedUid,
              reviewCreateCardId!,
              reviewCreateFingerprint,
            )) {
          return const SyncOperationResult.retryable(
            code: 'REVIEW_CREATE_ACK_INVALID',
          );
        }
        return const SyncOperationResult.success();
      }

      if (response.statusCode == 401) {
        final backendCode = _extractBackendCode(response.body);
        if (_isAppCheckCode(backendCode)) {
          return SyncOperationResult.retryable(code: backendCode);
        }

        return const SyncOperationResult.retryable(
          code: 'AUTHENTICATION_REQUIRED',
        );
      }

      if (reviewCreateFingerprint != null) {
        const recoveryStatuses = <String, int>{
          'REVIEW_CREATE_LEGACY_UNVERIFIED': 409,
          'REVIEW_CREATE_FINGERPRINT_CONFLICT': 409,
          'REVIEW_CREATE_RECEIPT_INVALID': 503,
          'REVIEW_CREATE_ROOT_UNAVAILABLE': 503,
          'REVIEW_CREATE_SUBJECT_UNAVAILABLE': 409,
          'REVIEW_CREATE_SUBJECT_TOMBSTONED': 409,
          'REVIEW_CREATE_STATE_INVALID': 503,
          'REVIEW_CREATE_UNCONFIRMED': 500,
          'ACCOUNT_DELETION_BLOCKED': 503,
        };
        final code = _extractBackendCode(response.body);
        if (code != null && recoveryStatuses[code] == response.statusCode) {
          return SyncOperationResult.retryable(code: code);
        }
      }

      if (response.statusCode == 403) {
        final backendCode = _extractBackendCode(response.body);

        if (_isQuotaExceededCode(backendCode)) {
          return const SyncOperationResult.quotaExceeded();
        }

        return SyncOperationResult.permissionDenied();
      }

      if (response.statusCode == 400) {
        return SyncOperationResult.invalidPayload(
          message: _extractBackendMessage(response.body),
        );
      }

      if (response.statusCode == 404) {
        final backendCode = _extractBackendCode(response.body);
        if (_isMissingSyncResourceCode(backendCode)) {
          return SyncOperationResult.invalidPayload(
            message: _extractBackendMessage(response.body),
          );
        }

        return SyncOperationResult.retryable(
          message: _extractBackendMessage(response.body),
          code: backendCode ?? 'BACKEND_404',
        );
      }

      if (response.statusCode == 409) {
        final backendCode = _extractBackendCode(response.body);
        final backendMessage = _extractBackendMessage(response.body);
        if (backendCode != null &&
            backendCode ==
                StudyStateHoldOperation.forBackendOperation(
                  payload['operation'],
                )) {
          return SyncOperationResult.retryable(code: backendCode);
        }

        return SyncOperationResult.invalidPayload(
          message: backendCode == null
              ? backendMessage
              : '$backendCode: $backendMessage',
        );
      }

      if (response.statusCode == 412) {
        final backendCode = _extractBackendCode(response.body);

        if (_isMigrationRequiredCode(backendCode)) {
          return SyncOperationResult.retryable(
            message: _extractBackendMessage(response.body),
            code: backendCode,
          );
        }

        return SyncOperationResult.invalidPayload(
          message: _extractBackendMessage(response.body),
        );
      }

      if (response.statusCode == 429 || response.statusCode >= 500) {
        return SyncOperationResult.retryable(
          message: _extractBackendMessage(response.body),
          code: 'BACKEND_${response.statusCode}',
        );
      }

      return SyncOperationResult.retryable(
        message: _extractBackendMessage(response.body),
        code: 'BACKEND_${response.statusCode}',
      );
    } on RemoteSessionStopped {
      return const SyncOperationResult.retryable(code: 'SESSION_STOPPED');
    } on http.ClientException {
      return const SyncOperationResult.retryable(code: 'NETWORK_ERROR');
    } on TimeoutException {
      return const SyncOperationResult.retryable(code: 'SYNC_TIMEOUT');
    } catch (_) {
      // Token/client exceptions may contain credentials; never persist them.
      return const SyncOperationResult.retryable(code: 'REMOTE_SEND_FAILED');
    } finally {
      client?.close();
    }
  }

  Future<String?> _getIdToken({
    required String expectedUid,
    required bool forceRefresh,
  }) async {
    final user = _auth.currentUser;

    if (user == null || user.uid != expectedUid) {
      return null;
    }

    final provider = _idTokenProvider;

    if (provider != null) {
      return provider(user, forceRefresh);
    }

    return user.getIdToken(forceRefresh);
  }

  String _extractBackendMessage(String body) {
    try {
      final decoded = jsonDecode(body);

      if (decoded is Map && decoded['error'] is String) {
        return decoded['error'] as String;
      }
    } catch (_) {
      // Usa o fallback abaixo.
    }

    return 'Falha na sincronização server-side.';
  }

  String? _extractBackendCode(String body) {
    try {
      final decoded = jsonDecode(body);

      if (decoded is Map) {
        final code = decoded['code'];

        if (code is String && code.trim().isNotEmpty) {
          return code.trim();
        }
      }
    } catch (_) {
      // Usa o fallback abaixo.
    }

    return null;
  }

  bool _isAppCheckCode(String? code) {
    return code == 'APP_CHECK_REQUIRED' || code == 'APP_CHECK_INVALID';
  }

  bool _isMissingSyncResourceCode(String? code) {
    return code == 'TASK_NOT_FOUND' || code == 'HABIT_NOT_FOUND';
  }

  bool _isQuotaExceededCode(String? code) {
    if (code == null) {
      return false;
    }

    return RegExp(r'^[A-Z][A-Z0-9_]*_QUOTA_EXCEEDED$').hasMatch(code);
  }

  bool _isMigrationRequiredCode(String? code) {
    if (code == null) {
      return false;
    }

    return RegExp(r'^[A-Z][A-Z0-9_]*_MIGRATION_REQUIRED$').hasMatch(code);
  }

  Map<String, dynamic> _decodePayload(String payloadJson) {
    final decoded = jsonDecode(payloadJson);

    if (decoded is! Map) {
      throw const FormatException(
        'Payload de sincronização deve ser um objeto JSON.',
      );
    }

    return Map<String, dynamic>.from(decoded);
  }

  Map<String, dynamic> _prepareHealthPayload(Map<String, dynamic> payload) {
    final data = Map<String, dynamic>.from(payload);
    final rawDate = data['date'];

    if (rawDate == null || rawDate is Timestamp) {
      return data;
    }

    if (rawDate is String) {
      final parsedDate = DateTime.tryParse(rawDate);

      if (parsedDate != null) {
        data['date'] = Timestamp.fromDate(parsedDate);
        return data;
      }
    }

    throw const FormatException('Data de saúde inválida.');
  }

  bool _isServerConfirmed(DocumentSnapshot<Map<String, dynamic>> snapshot) =>
      !snapshot.metadata.isFromCache && !snapshot.metadata.hasPendingWrites;

  SyncOperationResult _mapFirebaseError(FirebaseException error) {
    switch (error.code) {
      case 'permission-denied':
        if (error.plugin == 'cloud_firestore') {
          // Rules do not identify R5 as the cause. A denied/unknown write is
          // unconfirmed, not acknowledged; SyncManager owns controlled backoff.
          return const SyncOperationResult.retryable(
            code: 'FIRESTORE_PERMISSION_UNCONFIRMED',
          );
        }
        return const SyncOperationResult.permissionDenied();

      case 'unauthenticated':
        return const SyncOperationResult.retryable(
          code: 'AUTHENTICATION_REQUIRED',
        );

      case 'invalid-argument':
      case 'failed-precondition':
        return const SyncOperationResult.invalidPayload();

      case 'unavailable':
      case 'deadline-exceeded':
      case 'aborted':
      case 'internal':
        return SyncOperationResult.retryable(
          message: error.message,
          code: error.code.toUpperCase(),
        );

      default:
        return SyncOperationResult.retryable(
          message: error.message,
          code: error.code.toUpperCase(),
        );
    }
  }
}
