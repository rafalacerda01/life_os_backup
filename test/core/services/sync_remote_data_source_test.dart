import 'package:life_os/core/services/sync_operation_result.dart';
// ignore_for_file: subtype_of_sealed_class, must_be_immutable

import 'dart:async';
import 'package:life_os/core/database/remote_send_permit.dart';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Value;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:life_os/features/notifications/domain/models/notification_occurrence.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:life_os/core/database/app_database.dart' hide Transaction;
import 'package:life_os/core/services/sync_remote_data_source.dart';

class _RecordingHealthDocumentReference extends Fake
    implements DocumentReference<Map<String, dynamic>> {
  final Map<String, dynamic> storedData = <String, dynamic>{};
  Map<String, dynamic>? lastData;
  Map<Object, Object?>? lastUpdateData;
  SetOptions? lastOptions;
  Object? setError;
  Object? updateError;
  Object? afterSetError;
  int setCalls = 0;
  int updateCalls = 0;

  @override
  Future<void> set(Map<String, dynamic> data, [SetOptions? options]) async {
    setCalls += 1;
    final error = setError;

    if (error != null) {
      throw error;
    }

    lastData = Map<String, dynamic>.from(data);
    lastOptions = options;

    if (options?.merge == true) {
      storedData.addAll(data);
    } else {
      storedData
        ..clear()
        ..addAll(data);
    }
    final after = afterSetError;
    if (after != null) throw after;
  }

  @override
  Future<void> update(Map<Object, Object?> data) async {
    updateCalls += 1;
    final error = updateError;
    if (error != null) throw error;
    lastUpdateData = Map<Object, Object?>.from(data);
    storedData.addAll(data.cast<String, dynamic>());
  }
}

class _RecordingHealthCollectionReference extends Fake
    implements CollectionReference<Map<String, dynamic>> {
  final _RecordingHealthDocumentReference documentReference;
  String? lastDocumentId;

  _RecordingHealthCollectionReference(this.documentReference);

  @override
  DocumentReference<Map<String, dynamic>> doc([String? path]) {
    lastDocumentId = path;
    return documentReference;
  }
}

class _RecordingUserDocumentReference extends Fake
    implements DocumentReference<Map<String, dynamic>> {
  final _RecordingHealthCollectionReference healthCollection;

  _RecordingUserDocumentReference(this.healthCollection);

  @override
  CollectionReference<Map<String, dynamic>> collection(String path) {
    if (path != 'health_info' &&
        path != 'goals' &&
        path != 'study_info' &&
        path != 'review_queue' &&
        path != 'focus_logs') {
      throw UnsupportedError('Unexpected collection: $path');
    }

    return healthCollection;
  }
}

class _RecordingUsersCollectionReference extends Fake
    implements CollectionReference<Map<String, dynamic>> {
  final _RecordingUserDocumentReference userDocumentReference;
  String? lastUserId;

  _RecordingUsersCollectionReference(this.userDocumentReference);

  @override
  DocumentReference<Map<String, dynamic>> doc([String? path]) {
    lastUserId = path;
    return userDocumentReference;
  }
}

class _RecordingFirestore extends Fake implements FirebaseFirestore {
  final _RecordingUsersCollectionReference usersCollection;

  _RecordingFirestore(this.usersCollection);

  @override
  CollectionReference<Map<String, dynamic>> collection(String path) {
    if (path != 'users') {
      throw UnsupportedError('Unexpected collection: $path');
    }

    return usersCollection;
  }
}

class _MemoryDocumentSnapshot extends Fake
    implements DocumentSnapshot<Map<String, dynamic>> {
  final Map<String, dynamic>? values;

  _MemoryDocumentSnapshot(
    this.values, {
    this.id = '',
    this.fromCache = false,
    this.pendingWrites = false,
  });
  @override
  final String id;
  final bool fromCache;
  final bool pendingWrites;
  @override
  SnapshotMetadata get metadata =>
      _MemorySnapshotMetadata(fromCache, pendingWrites);

  @override
  bool get exists => values != null;

  @override
  Map<String, dynamic>? data() =>
      values == null ? null : Map<String, dynamic>.from(values!);
}

class _MemorySnapshotMetadata extends Fake implements SnapshotMetadata {
  @override
  final bool isFromCache;
  @override
  final bool hasPendingWrites;
  _MemorySnapshotMetadata(this.isFromCache, this.hasPendingWrites);
}

class _MemoryDocumentReference extends Fake
    implements DocumentReference<Map<String, dynamic>> {
  final _TransactionalStudyFirestore owner;

  @override
  final String path;

  _MemoryDocumentReference(this.owner, this.path);

  @override
  CollectionReference<Map<String, dynamic>> collection(String path) {
    return _MemoryCollectionReference(owner, '${this.path}/$path');
  }
}

class _MemoryCollectionReference extends Fake
    implements CollectionReference<Map<String, dynamic>> {
  final _TransactionalStudyFirestore owner;

  @override
  final String path;

  _MemoryCollectionReference(this.owner, this.path);

  @override
  DocumentReference<Map<String, dynamic>> doc([String? path]) {
    return _MemoryDocumentReference(owner, '${this.path}/$path');
  }
}

class _MemoryTransaction extends Fake implements Transaction {
  final Map<String, Map<String, dynamic>> workingData;

  int writes = 0;
  bool fromCache = false;
  bool pendingWrites = false;

  _MemoryTransaction(Map<String, Map<String, dynamic>> source)
    : workingData = {
        for (final entry in source.entries)
          entry.key: Map<String, dynamic>.from(entry.value),
      };

  String _path(DocumentReference reference) =>
      (reference as _MemoryDocumentReference).path;

  @override
  Future<DocumentSnapshot<T>> get<T extends Object?>(
    DocumentReference<T> documentReference,
  ) async {
    final values = workingData[_path(documentReference)];
    return _MemoryDocumentSnapshot(
          values,
          id: _path(documentReference).split('/').last,
          fromCache: fromCache,
          pendingWrites: pendingWrites,
        )
        as DocumentSnapshot<T>;
  }

  @override
  Transaction set<T>(
    DocumentReference<T> documentReference,
    T data, [
    SetOptions? options,
  ]) {
    writes += 1;
    final path = _path(documentReference);
    final incoming = Map<String, dynamic>.from(data! as Map);
    final target = options?.merge == true
        ? Map<String, dynamic>.from(workingData[path] ?? const {})
        : <String, dynamic>{};
    _applyFields(target, incoming);
    workingData[path] = target;
    return this;
  }

  @override
  Transaction update(
    DocumentReference documentReference,
    Map<String, dynamic> data,
  ) {
    writes += 1;
    final path = _path(documentReference);
    final current = workingData[path];
    if (current == null) {
      throw FirebaseException(plugin: 'cloud_firestore', code: 'not-found');
    }
    _applyFields(current, data);
    return this;
  }

  @override
  Transaction delete(DocumentReference documentReference) {
    writes += 1;
    workingData.remove(_path(documentReference));
    return this;
  }

  void _applyFields(
    Map<String, dynamic> target,
    Map<String, dynamic> incoming,
  ) {
    for (final entry in incoming.entries) {
      if (entry.value is FieldValue) {
        if (entry.key == 'createdAt') {
          target[entry.key] = Timestamp.fromDate(DateTime.utc(2026, 9, 9, 15));
        } else if (entry.key != 'reviewQueue' && entry.key != 'cardsToReview') {
          throw UnsupportedError('Unexpected transform: ${entry.key}');
        } else {
          target[entry.key] = (target[entry.key] as int? ?? 0) + 1;
        }
      } else {
        target[entry.key] = entry.value;
      }
    }
  }
}

class _TransactionalStudyFirestore extends Fake implements FirebaseFirestore {
  Map<String, Map<String, dynamic>> data = {};
  int transactionCommits = 0;
  int transactionWrites = 0;
  Object? transactionError;
  Object? afterCommitError;
  bool fromCache = false;
  bool pendingWrites = false;

  void seed(String path, Map<String, dynamic> values) {
    data[path] = Map<String, dynamic>.from(values);
  }

  Map<String, dynamic>? read(String path) => data[path];

  @override
  CollectionReference<Map<String, dynamic>> collection(String path) {
    return _MemoryCollectionReference(this, path);
  }

  @override
  Future<T> runTransaction<T>(
    TransactionHandler<T> transactionHandler, {
    Duration timeout = const Duration(seconds: 30),
    int maxAttempts = 5,
  }) async {
    final error = transactionError;
    if (error != null) throw error;
    final transaction = _MemoryTransaction(data)
      ..fromCache = fromCache
      ..pendingWrites = pendingWrites;
    final result = await transactionHandler(transaction);
    data = transaction.workingData;
    transactionCommits += 1;
    transactionWrites += transaction.writes;
    final after = afterCommitError;
    if (after != null) throw after;
    return result;
  }
}

class _FakeFirebaseUser extends Fake implements User {
  @override
  final String uid;

  _FakeFirebaseUser(this.uid);
}

class _FakeFirebaseAuth extends Fake implements FirebaseAuth {
  User? user;

  _FakeFirebaseAuth([this.user]);

  @override
  User? get currentUser => user;
}

class _RecordingHttpClient extends http.BaseClient {
  final Future<http.StreamedResponse> Function(http.BaseRequest request)
  handler;
  bool wasClosed = false;

  _RecordingHttpClient(this.handler);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    return handler(request);
  }

  @override
  void close() {
    wasClosed = true;
    super.close();
  }
}

http.StreamedResponse _jsonResponse(int statusCode, [String body = '{}']) {
  return http.StreamedResponse(
    Stream.value(utf8.encode(body)),
    statusCode,
    headers: const {'content-type': 'application/json'},
  );
}

Future<String?> _validAppCheckToken() async => 'firebase-app-check-token';

SyncQueueTableData createHealthItem({
  required String operationType,
  required Map<String, dynamic> payload,
}) {
  return SyncQueueTableData(
    id: 1,
    ownerUid: 'user-123',
    collection: 'health_info',
    docId: '2026-08-21',
    operationType: operationType,
    payloadJson: jsonEncode(payload),
    createdAt: DateTime.now().millisecondsSinceEpoch,
    isSynced: false,
    status: SyncQueuePersistenceStatus.pending,
    attemptCount: 0,
  );
}

SyncQueueTableData createTaskItem() {
  return SyncQueueTableData(
    id: 2,
    ownerUid: 'user-123',
    collection: 'tasks',
    docId: 'task-1',
    operationType: 'create',
    payloadJson: jsonEncode({
      'title': 'Tarefa',
      'priority': 'HIGH',
      'date': '2026-08-22T10:00:00.000Z',
    }),
    createdAt: DateTime.now().millisecondsSinceEpoch,
    isSynced: false,
    status: SyncQueuePersistenceStatus.pending,
    attemptCount: 0,
  );
}

SyncQueueTableData createTaskUpdateItem({bool isCompleted = true}) {
  return SyncQueueTableData(
    id: 3,
    ownerUid: 'user-123',
    collection: 'tasks',
    docId: 'task-1',
    operationType: 'update',
    payloadJson: jsonEncode({'isCompleted': isCompleted}),
    createdAt: DateTime.now().millisecondsSinceEpoch,
    isSynced: false,
    status: SyncQueuePersistenceStatus.pending,
    attemptCount: 0,
  );
}

SyncQueueTableData createHabitUpdateItem() {
  return SyncQueueTableData(
    id: 4,
    ownerUid: 'user-123',
    collection: 'habits',
    docId: 'habit-1',
    operationType: 'update',
    payloadJson: jsonEncode({
      'completedDates': ['2026-08-23'],
    }),
    createdAt: DateTime.now().millisecondsSinceEpoch,
    isSynced: false,
    status: SyncQueuePersistenceStatus.pending,
    attemptCount: 0,
  );
}

SyncQueueTableData createHabitCompletionItem() {
  return SyncQueueTableData(
    id: 5,
    ownerUid: 'user-123',
    collection: 'habits',
    docId: 'habit-1',
    operationType: 'update',
    payloadJson: jsonEncode({
      'completedDates': ['2026-08-23'],
      'competitiveCompletionId': '7d287d4e-190f-42ab-90a8-a93696f8c462',
    }),
    createdAt: DateTime.now().millisecondsSinceEpoch,
    isSynced: false,
    status: SyncQueuePersistenceStatus.pending,
    attemptCount: 0,
  );
}

SyncQueueTableData createGoalUpdateItem(Map<String, dynamic> payload) {
  return SyncQueueTableData(
    id: 6,
    ownerUid: 'user-123',
    collection: 'goals',
    docId: 'goal-1',
    operationType: 'update',
    payloadJson: jsonEncode(payload),
    createdAt: DateTime.now().millisecondsSinceEpoch,
    isSynced: false,
    status: SyncQueuePersistenceStatus.pending,
    attemptCount: 0,
  );
}

SyncQueueTableData createStudyItem({
  required String collection,
  required String docId,
  required String operationType,
  required Map<String, dynamic> payload,
}) {
  return SyncQueueTableData(
    id: 7,
    ownerUid: 'user-123',
    collection: collection,
    docId: docId,
    operationType: operationType,
    payloadJson: jsonEncode(payload),
    createdAt: DateTime.now().millisecondsSinceEpoch,
    isSynced: false,
    status: SyncQueuePersistenceStatus.pending,
    attemptCount: 0,
  );
}

SyncQueueTableData createStudyActivityItem({
  String mutationId = '7d287d4e-190f-42ab-90a8-a93696f8c462',
  Object? subjectId = 'subject-1',
  Object? progressDelta = .25,
  Object? occurredAt = '2026-09-09T12:00:00.000Z',
  Object? timeZoneOffsetMinutes = -180,
  Map<String, dynamic>? payload,
}) {
  return SyncQueueTableData(
    id: 8,
    ownerUid: 'user-123',
    collection: 'study_activity',
    docId: mutationId,
    operationType: 'create',
    payloadJson: jsonEncode(
      payload ??
          {
            'subjectId': subjectId,
            'progressDelta': progressDelta,
            'occurredAt': occurredAt,
            'timeZoneOffsetMinutes': timeZoneOffsetMinutes,
          },
    ),
    createdAt: DateTime.now().millisecondsSinceEpoch,
    isSynced: false,
    status: SyncQueuePersistenceStatus.pending,
    attemptCount: 0,
  );
}

SyncQueueTableData createStudyProgressResetItem({
  String mutationId = '5a3ccf1f-d43e-4a34-823d-61ed255e568a',
  Object? occurredAt = '2026-09-09T10:00:00.000Z',
  Map<String, dynamic>? payload,
}) {
  return SyncQueueTableData(
    id: 9,
    ownerUid: 'user-123',
    collection: 'study_progress_reset',
    docId: mutationId,
    operationType: 'create',
    payloadJson: jsonEncode(payload ?? {'occurredAt': occurredAt}),
    createdAt: DateTime.now().millisecondsSinceEpoch,
    isSynced: false,
    status: SyncQueuePersistenceStatus.pending,
    attemptCount: 0,
  );
}

void main() {
  late _RecordingHealthDocumentReference healthDoc;
  late _RecordingHealthCollectionReference healthCollection;
  late _RecordingUsersCollectionReference usersCollection;
  late FirestoreSyncRemoteDataSource remote;

  FirestoreSyncRemoteDataSource serverDataSource({
    required FirebaseAuth auth,
    required http.Client Function() clientFactory,
    required Future<String?> Function(User user, bool forceRefresh)
    idTokenProvider,
    required SyncAppCheckTokenProvider appCheckTokenProvider,
  }) {
    return FirestoreSyncRemoteDataSource(
      captureRemoteSend: (_) => RemoteSendPermit(() => true),
      _RecordingFirestore(
        _RecordingUsersCollectionReference(
          _RecordingUserDocumentReference(
            _RecordingHealthCollectionReference(healthDoc),
          ),
        ),
      ),
      auth,
      clientFactory: clientFactory,
      idTokenProvider: idTokenProvider,
      appCheckTokenProvider: appCheckTokenProvider,
    );
  }

  setUp(() {
    healthDoc = _RecordingHealthDocumentReference();
    healthCollection = _RecordingHealthCollectionReference(healthDoc);
    final userDoc = _RecordingUserDocumentReference(healthCollection);
    usersCollection = _RecordingUsersCollectionReference(userDoc);
    final firestore = _RecordingFirestore(usersCollection);

    remote = FirestoreSyncRemoteDataSource(
      captureRemoteSend: (_) => RemoteSendPermit(() => true),
      firestore,
      _FakeFirebaseAuth(),
    );
  });

  SyncQueueTableData focusItem({
    Map<String, dynamic>? payload,
    String docId = '7d287d4e-190f-42ab-90a8-a93696f8c462',
  }) => createStudyItem(
    collection: 'focus_logs',
    docId: docId,
    operationType: 'create',
    payload:
        payload ??
        {
          'targetId': 'task-1',
          'targetType': 'TASK',
          'durationSeconds': 1200,
          'timestamp': '2026-09-24T10:00:00.000Z',
        },
  );

  test('Focus create usa UID esperado e converte timestamp', () async {
    final result = await remote.process('user-a', focusItem());

    expect(result.isSuccess, isTrue);
    expect(usersCollection.lastUserId, 'user-a');
    expect(
      healthCollection.lastDocumentId,
      '7d287d4e-190f-42ab-90a8-a93696f8c462',
    );
    expect(healthDoc.setCalls, 1);
    expect(healthDoc.lastData?.keys.toSet(), {
      'targetId',
      'targetType',
      'durationSeconds',
      'timestamp',
    });
    expect(healthDoc.lastData?['timestamp'], isA<Timestamp>());
    expect(
      (healthDoc.lastData?['timestamp'] as Timestamp).toDate().toUtc(),
      DateTime.utc(2026, 9, 24, 10),
    );
  });

  test('Focus rejeita payloads inválidos sem write', () async {
    final invalid = <Map<String, dynamic>>[
      {
        'targetId': '',
        'targetType': 'TASK',
        'durationSeconds': 1,
        'timestamp': '2026-09-24T10:00:00.000Z',
      },
      {
        'targetId': 'task-1',
        'targetType': 'OTHER',
        'durationSeconds': 1,
        'timestamp': '2026-09-24T10:00:00.000Z',
      },
      {
        'targetId': 'task-1',
        'targetType': 'TASK',
        'durationSeconds': 0,
        'timestamp': '2026-09-24T10:00:00.000Z',
      },
      {
        'targetId': 'task-1',
        'targetType': 'TASK',
        'durationSeconds': 1,
        'timestamp': 'invalid',
      },
      {
        'targetId': 'task-1',
        'targetType': 'TASK',
        'durationSeconds': 1,
        'timestamp': '2026-09-24T10:00:00.000Z',
        'uid': 'user-b',
      },
    ];

    for (final payload in invalid) {
      final result = await remote.process(
        'user-a',
        focusItem(payload: payload),
      );
      expect(result.code, 'INVALID_PAYLOAD');
    }
    final badDoc = await remote.process('user-a', focusItem(docId: 'bad/id'));
    expect(badDoc.code, 'INVALID_PAYLOAD');
    expect(healthDoc.setCalls, 0);
  });

  test(
    'Focus Firestore transitório é retryable e permissão é terminal',
    () async {
      healthDoc.setError = FirebaseException(
        plugin: 'cloud_firestore',
        code: 'unavailable',
      );
      expect((await remote.process('user-a', focusItem())).shouldRetry, isTrue);

      healthDoc.setError = FirebaseException(
        plugin: 'cloud_firestore',
        code: 'permission-denied',
      );
      final denied = await remote.process('user-a', focusItem());
      // Historical title retained: Rules denial is now ambiguous, not terminal.
      expect(denied.isPermanentFailure, isFalse);
      expect(denied.shouldRetry, isTrue);
      expect(denied.code, 'FIRESTORE_PERMISSION_UNCONFIRMED');
    },
  );

  test('health_info update usa set com merge:true', () async {
    final item = createHealthItem(
      operationType: 'update',
      payload: {'mood': 'Radiante', 'date': '2026-08-21T10:00:00.000Z'},
    );

    final result = await remote.process('user-123', item);

    expect(result.isSuccess, isTrue);
    expect(healthDoc.lastData?['mood'], 'Radiante');
    expect(healthDoc.lastData?['date'], isA<Timestamp>());
    expect(healthDoc.lastOptions?.merge, isTrue);
  });

  test('study_info/main legado é preservado sem Client write', () async {
    final result = await remote.process(
      'user-123',
      createStudyItem(
        collection: 'study_info',
        docId: 'main',
        operationType: 'update',
        payload: {'reviewQueue': 2},
      ),
    );

    expect(result.shouldRetry, isTrue);
    expect(result.isSuccess, isFalse);
    expect(result.code, LegacyStudyInfoOperation.holdCode);
    expect(healthDoc.lastOptions, isNull);
    expect(healthDoc.lastData, isNull);
    expect(healthDoc.setCalls, 0);
    expect(healthDoc.updateCalls, 0);
  });

  test('study_info/main com campos históricos fica em HOLD', () async {
    for (final payload in [
      {'progress': .5},
      {'streak': 3},
      {'lastStudyDate': '2026-09-08T10:00:00.000Z'},
      {'reviewQueue': 2, 'progress': .5},
    ]) {
      final result = await remote.process(
        'user-123',
        createStudyItem(
          collection: 'study_info',
          docId: 'main',
          operationType: 'update',
          payload: payload,
        ),
      );
      expect(result.isPermanentFailure, isFalse);
      expect(result.shouldRetry, isTrue);
      expect(result.code, LegacyStudyInfoOperation.holdCode);
      expect(healthDoc.setCalls, 0);
    }
  });

  test(
    'study_info preserva main legado e rejeita outro docId sem write',
    () async {
      for (final item in [
        createStudyItem(
          collection: 'study_info',
          docId: 'other',
          operationType: 'update',
          payload: {'reviewQueue': 1},
        ),
        createStudyItem(
          collection: 'study_info',
          docId: 'main',
          operationType: 'update',
          payload: {'reviewQueue': 1, 'extra': true},
        ),
      ]) {
        final result = await remote.process('user-123', item);
        expect(result.isPermanentFailure, item.docId != 'main');
        expect(result.shouldRetry, item.docId == 'main');
        expect(
          result.code,
          item.docId == 'main'
              ? LegacyStudyInfoOperation.holdCode
              : 'INVALID_PAYLOAD',
        );
      }
      expect(healthDoc.lastData, isNull);
      expect(healthDoc.updateCalls, 0);
    },
  );

  SyncQueueTableData reviewCreateItem(String cardId) => createStudyItem(
    collection: 'review_queue',
    docId: cardId,
    operationType: 'create',
    payload: {
      'subjectId': 'subject-1',
      'question': 'Pergunta',
      'answer': 'Resposta',
      'createdAt': '2026-09-08T10:00:00.000Z',
    },
  );

  SyncQueueTableData reviewUpdateItem(
    String cardId, {
    String subjectId = 'subject-1',
    String lastReviewed = '2026-09-08T10:00:00.000Z',
    Object? timeZoneOffsetMinutes = -180,
    Map<String, dynamic>? payload,
  }) => createStudyItem(
    collection: 'review_queue',
    docId: cardId,
    operationType: 'update',
    payload:
        payload ??
        {
          'subjectId': subjectId,
          'lastReviewed': lastReviewed,
          'timeZoneOffsetMinutes': timeZoneOffsetMinutes,
        },
  );

  void seedReviewState(
    _TransactionalStudyFirestore firestore, {
    List<String> cardIds = const ['card-1'],
    int reviewQueue = 2,
    int cardsToReview = 2,
    double progress = 0.20,
  }) {
    firestore
      ..seed('users/user-123/study_info/main', {
        'reviewQueue': reviewQueue,
        'progress': progress,
      })
      ..seed('users/user-123/subjects/subject-1', {
        'cardsToReview': cardsToReview,
      });
    for (final cardId in cardIds) {
      firestore.seed('users/user-123/review_queue/$cardId', {
        'subjectId': 'subject-1',
        'lastReviewed': null,
      });
    }
  }

  FirestoreSyncRemoteDataSource transactionalStudyRemote(
    _TransactionalStudyFirestore firestore,
  ) => FirestoreSyncRemoteDataSource(
    captureRemoteSend: (_) => RemoteSendPermit(() => true),
    firestore,
    _FakeFirebaseAuth(),
  );

  test(
    'legacy review_queue create remains pending without card/counter writes',
    () async {
      final firestore = _TransactionalStudyFirestore()
        ..seed('users/user-123/subjects/subject-1', {'cardsToReview': 0});
      final result = await transactionalStudyRemote(
        firestore,
      ).process('user-123', reviewCreateItem('card-1'));
      expect(result.isSuccess, isFalse);
      expect(result.shouldRetry, isTrue);
      expect(result.code, 'REVIEW_CREATE_LEGACY_UNVERIFIED');
      expect(firestore.read('users/user-123/review_queue/card-1'), isNull);
      expect(firestore.read('users/user-123/study_info/main'), isNull);
      expect(
        firestore.read('users/user-123/subjects/subject-1')?['cardsToReview'],
        0,
      );
      expect(firestore.transactionCommits, 0);
      expect(firestore.transactionWrites, 0);
    },
  );
  test('legacy replay never increments counters or fabricates ACK', () async {
    final firestore = _TransactionalStudyFirestore()
      ..seed('users/user-123/subjects/subject-1', {'cardsToReview': 0});
    final source = transactionalStudyRemote(firestore),
        item = reviewCreateItem('card-1');
    for (var attempt = 0; attempt < 2; attempt++) {
      final result = await source.process('user-123', item);
      expect(result.isSuccess, isFalse);
      expect(result.shouldRetry, isTrue);
      expect(result.code, 'REVIEW_CREATE_LEGACY_UNVERIFIED');
    }
    expect(firestore.read('users/user-123/study_info/main'), isNull);
    expect(
      firestore.read('users/user-123/subjects/subject-1')?['cardsToReview'],
      0,
    );
    expect(firestore.transactionCommits, 0);
    expect(firestore.transactionWrites, 0);
  });
  test(
    'different legacy cards remain unresolved without counter writes',
    () async {
      final firestore = _TransactionalStudyFirestore()
        ..seed('users/user-123/subjects/subject-1', {'cardsToReview': 0});
      final source = transactionalStudyRemote(firestore);
      for (final id in ['card-1', 'card-2'])
        expect(
          (await source.process('user-123', reviewCreateItem(id))).code,
          'REVIEW_CREATE_LEGACY_UNVERIFIED',
        );
      expect(firestore.read('users/user-123/study_info/main'), isNull);
      expect(
        firestore.read('users/user-123/subjects/subject-1')?['cardsToReview'],
        0,
      );
      expect(firestore.transactionCommits, 0);
      expect(firestore.transactionWrites, 0);
    },
  );
  test(
    'legacy subject absence requires recovery without remote reads or partial writes',
    () async {
      final firestore = _TransactionalStudyFirestore();
      final result = await transactionalStudyRemote(
        firestore,
      ).process('user-123', reviewCreateItem('card-1'));
      expect(result.isPermanentFailure, isFalse);
      expect(result.shouldRetry, isTrue);
      expect(result.code, 'REVIEW_CREATE_LEGACY_UNVERIFIED');
      expect(firestore.data, isEmpty);
      expect(firestore.transactionCommits, 0);
    },
  );
  test(
    'legacy malformed content is preserved for recovery without SDK writes',
    () async {
      final result = await remote.process(
        'user-123',
        createStudyItem(
          collection: 'review_queue',
          docId: 'card-1',
          operationType: 'create',
          payload: {
            'subjectId': '',
            'question': 'Pergunta',
            'answer': 'Resposta',
            'createdAt': 'inválida',
          },
        ),
      );
      expect(result.isPermanentFailure, isFalse);
      expect(result.shouldRetry, isTrue);
      expect(result.code, 'REVIEW_CREATE_LEGACY_UNVERIFIED');
      expect(healthDoc.lastData, isNull);
      expect(healthDoc.updateCalls, 0);
    },
  );

  test('goals update preserva currentValue inteiro', () async {
    final result = await remote.process(
      'user-123',
      createGoalUpdateItem({'currentValue': 3}),
    );

    expect(result.isSuccess, isTrue);
    expect(healthDoc.lastUpdateData, {'currentValue': 3});
    expect(healthDoc.lastUpdateData!['currentValue'], isA<int>());
  });

  test('goals update converte lastReset ISO para Timestamp', () async {
    final result = await remote.process(
      'user-123',
      createGoalUpdateItem({
        'currentValue': 0,
        'lastReset': '2026-09-06T10:00:00.000Z',
      }),
    );

    expect(result.isSuccess, isTrue);
    expect(healthDoc.lastUpdateData!['currentValue'], 0);
    expect(healthDoc.lastUpdateData!['lastReset'], isA<Timestamp>());
    expect(
      (healthDoc.lastUpdateData!['lastReset']! as Timestamp)
          .millisecondsSinceEpoch,
      DateTime.parse('2026-09-06T10:00:00.000Z').millisecondsSinceEpoch,
    );
  });

  test('goals update rejeita lastReset inválido sem escrever', () async {
    final result = await remote.process(
      'user-123',
      createGoalUpdateItem({'currentValue': 0, 'lastReset': 'inválido'}),
    );

    expect(result.isPermanentFailure, isTrue);
    expect(result.code, 'INVALID_PAYLOAD');
    expect(healthDoc.updateCalls, 0);
  });

  test('goals update rejeita campo extra sem escrever', () async {
    final result = await remote.process(
      'user-123',
      createGoalUpdateItem({'currentValue': 3, 'unexpectedField': true}),
    );

    expect(result.isPermanentFailure, isTrue);
    expect(result.code, 'INVALID_PAYLOAD');
    expect(healthDoc.updateCalls, 0);
  });

  test('health_info create com água legada não escreve nem confirma', () async {
    final item = createHealthItem(
      operationType: 'create',
      payload: {'waterIntakeMl': 250, 'date': '2026-08-21T10:00:00.000Z'},
    );

    final result = await remote.process('user-123', item);

    expect(result.isSuccess, isFalse);
    expect(result.shouldRetry, isTrue);
    expect(result.code, 'LEGACY_WATER_BLOCKED');
    expect(healthDoc.setCalls, 0);
    expect(healthDoc.lastData, isNull);
  });

  test('humor seguido de água mantém só o envio permitido', () async {
    await remote.process(
      'user-123',
      createHealthItem(
        operationType: 'update',
        payload: {'mood': 'Radiante', 'date': '2026-08-21T10:00:00.000Z'},
      ),
    );
    await remote.process(
      'user-123',
      createHealthItem(
        operationType: 'update',
        payload: {'waterIntakeMl': 750, 'date': '2026-08-21T10:05:00.000Z'},
      ),
    );

    expect(healthDoc.storedData['mood'], 'Radiante');
    expect(healthDoc.storedData.containsKey('waterIntakeMl'), isFalse);
    expect(healthDoc.setCalls, 1);
  });

  test('água bloqueada não impede o envio posterior de humor', () async {
    await remote.process(
      'user-123',
      createHealthItem(
        operationType: 'update',
        payload: {'waterIntakeMl': 750, 'date': '2026-08-21T10:00:00.000Z'},
      ),
    );
    await remote.process(
      'user-123',
      createHealthItem(
        operationType: 'update',
        payload: {'mood': 'Radiante', 'date': '2026-08-21T10:05:00.000Z'},
      ),
    );

    expect(healthDoc.storedData.containsKey('waterIntakeMl'), isFalse);
    expect(healthDoc.setCalls, 1);
    expect(healthDoc.storedData['mood'], 'Radiante');
  });

  test('ciclo parcial não apaga humor nem água', () async {
    healthDoc.storedData.addAll({'mood': 'Radiante', 'waterIntakeMl': 1000});

    final result = await remote.process(
      'user-123',
      createHealthItem(
        operationType: 'update',
        payload: {
          'menstrualCycle': {
            'isEnabled': true,
            'lastPeriodStart': '2026-08-01T00:00:00.000',
            'cycleLengthDays': 28,
            'periodLengthDays': 5,
          },
          'date': '2026-08-21T10:10:00.000Z',
        },
      ),
    );

    expect(result.isSuccess, isTrue);
    expect(healthDoc.storedData['mood'], 'Radiante');
    expect(healthDoc.storedData['waterIntakeMl'], 1000);
    expect(healthDoc.storedData['menstrualCycle'], isA<Map>());
  });

  test('permission-denied em health_info permanece recuperável', () async {
    healthDoc.setError = FirebaseException(
      plugin: 'cloud_firestore',
      code: 'permission-denied',
      message: 'App Check rejeitou a requisição.',
    );

    final result = await remote.process(
      'user-123',
      createHealthItem(
        operationType: 'update',
        payload: {'mood': 'Radiante', 'date': '2026-08-21T10:00:00.000Z'},
      ),
    );

    expect(result.shouldRetry, isTrue);
    expect(result.code, 'PERMISSION-DENIED');
  });

  test('data inválida de health_info não chega ao Firestore', () async {
    final result = await remote.process(
      'user-123',
      createHealthItem(
        operationType: 'update',
        payload: {'mood': 'Radiante', 'date': 'data-inválida'},
      ),
    );

    expect(result.isPermanentFailure, isTrue);
    expect(healthDoc.lastData, isNull);
  });

  test('item de A com sessão A permite request server-side', () async {
    var requestCount = 0;
    final auth = _FakeFirebaseAuth(_FakeFirebaseUser('user-123'));
    final client = _RecordingHttpClient((request) async {
      requestCount += 1;
      return _jsonResponse(200);
    });
    final dataSource = FirestoreSyncRemoteDataSource(
      captureRemoteSend: (_) => RemoteSendPermit(() => true),
      _RecordingFirestore(
        _RecordingUsersCollectionReference(
          _RecordingUserDocumentReference(
            _RecordingHealthCollectionReference(healthDoc),
          ),
        ),
      ),
      auth,
      clientFactory: () => client,
      appCheckTokenProvider: _validAppCheckToken,
      idTokenProvider: (user, forceRefresh) async {
        expect(user.uid, 'user-123');
        expect(forceRefresh, isFalse);
        return 'token-a';
      },
    );

    final result = await dataSource.process('user-123', createTaskItem());

    expect(result.isSuccess, isTrue);
    expect(requestCount, 1);
    expect(client.wasClosed, isTrue);
  });

  test(
    'request server-side envia Auth e App Check somente em headers',
    () async {
      late Map<String, String> headers;
      late String body;
      final client = _RecordingHttpClient((request) async {
        headers = Map<String, String>.from(request.headers);
        body = await request.finalize().bytesToString();
        return _jsonResponse(200);
      });
      final dataSource = serverDataSource(
        auth: _FakeFirebaseAuth(_FakeFirebaseUser('user-123')),
        clientFactory: () => client,
        idTokenProvider: (_, _) async => 'firebase-id-token',
        appCheckTokenProvider: () async => 'firebase-app-check-token',
      );

      final result = await dataSource.process('user-123', createTaskItem());

      expect(result.isSuccess, isTrue);
      expect(headers['Authorization'], 'Bearer firebase-id-token');
      expect(headers['X-Firebase-AppCheck'], 'firebase-app-check-token');
      expect(body, isNot(contains('firebase-id-token')));
      expect(body, isNot(contains('firebase-app-check-token')));
      expect(client.wasClosed, isTrue);
    },
  );

  test('App Check null falha fechado sem criar client HTTP', () async {
    var clientFactoryCalls = 0;
    final dataSource = serverDataSource(
      auth: _FakeFirebaseAuth(_FakeFirebaseUser('user-123')),
      clientFactory: () {
        clientFactoryCalls += 1;
        return _RecordingHttpClient((_) async => _jsonResponse(200));
      },
      idTokenProvider: (_, _) async => 'firebase-id-token',
      appCheckTokenProvider: () async => null,
    );

    final result = await dataSource.process('user-123', createTaskItem());

    expect(result.shouldRetry, isTrue);
    expect(result.code, 'APP_CHECK_REQUIRED');
    expect(clientFactoryCalls, 0);
  });

  test('App Check vazio falha fechado sem criar client HTTP', () async {
    var clientFactoryCalls = 0;
    final dataSource = serverDataSource(
      auth: _FakeFirebaseAuth(_FakeFirebaseUser('user-123')),
      clientFactory: () {
        clientFactoryCalls += 1;
        return _RecordingHttpClient((_) async => _jsonResponse(200));
      },
      idTokenProvider: (_, _) async => 'firebase-id-token',
      appCheckTokenProvider: () async => '   ',
    );

    final result = await dataSource.process('user-123', createTaskItem());

    expect(result.shouldRetry, isTrue);
    expect(result.code, 'APP_CHECK_REQUIRED');
    expect(clientFactoryCalls, 0);
  });

  test('falha do provider App Check é sanitizada e não chama HTTP', () async {
    const secret = 'APP-CHECK-SEGREDO-XYZ';
    var clientFactoryCalls = 0;
    final dataSource = serverDataSource(
      auth: _FakeFirebaseAuth(_FakeFirebaseUser('user-123')),
      clientFactory: () {
        clientFactoryCalls += 1;
        return _RecordingHttpClient((_) async => _jsonResponse(200));
      },
      idTokenProvider: (_, _) async => 'firebase-id-token',
      appCheckTokenProvider: () async => throw StateError(secret),
    );

    final result = await dataSource.process('user-123', createTaskItem());

    expect(result.shouldRetry, isTrue);
    expect(result.code, 'APP_CHECK_REQUIRED');
    expect(result.code, isNot(contains(secret)));
    expect(result.message ?? '', isNot(contains(secret)));
    expect(clientFactoryCalls, 0);
  });

  test('backend APP_CHECK_REQUIRED não renova Firebase ID Token', () async {
    final forceRefreshCalls = <bool>[];
    final client = _RecordingHttpClient(
      (_) async => _jsonResponse(
        401,
        jsonEncode({
          'code': 'APP_CHECK_REQUIRED',
          'error': 'Verificação necessária.',
        }),
      ),
    );
    final dataSource = serverDataSource(
      auth: _FakeFirebaseAuth(_FakeFirebaseUser('user-123')),
      clientFactory: () => client,
      idTokenProvider: (_, forceRefresh) async {
        forceRefreshCalls.add(forceRefresh);
        return 'firebase-id-token';
      },
      appCheckTokenProvider: _validAppCheckToken,
    );

    final result = await dataSource.process('user-123', createTaskItem());

    expect(result.shouldRetry, isTrue);
    expect(result.code, 'APP_CHECK_REQUIRED');
    expect(forceRefreshCalls, [false]);
    expect(client.wasClosed, isTrue);
  });

  test('backend APP_CHECK_INVALID não renova Firebase ID Token', () async {
    final forceRefreshCalls = <bool>[];
    final client = _RecordingHttpClient(
      (_) async => _jsonResponse(
        401,
        jsonEncode({
          'code': 'APP_CHECK_INVALID',
          'error': 'Verificação inválida.',
        }),
      ),
    );
    final dataSource = serverDataSource(
      auth: _FakeFirebaseAuth(_FakeFirebaseUser('user-123')),
      clientFactory: () => client,
      idTokenProvider: (_, forceRefresh) async {
        forceRefreshCalls.add(forceRefresh);
        return 'firebase-id-token';
      },
      appCheckTokenProvider: _validAppCheckToken,
    );

    final result = await dataSource.process('user-123', createTaskItem());

    expect(result.shouldRetry, isTrue);
    expect(result.code, 'APP_CHECK_INVALID');
    expect(forceRefreshCalls, [false]);
    expect(client.wasClosed, isTrue);
  });

  test('item de A com sessão B não inicia request server-side', () async {
    var clientFactoryCalls = 0;
    var tokenProviderCalls = 0;
    final dataSource = FirestoreSyncRemoteDataSource(
      captureRemoteSend: (_) => RemoteSendPermit(() => true),
      _RecordingFirestore(
        _RecordingUsersCollectionReference(
          _RecordingUserDocumentReference(
            _RecordingHealthCollectionReference(healthDoc),
          ),
        ),
      ),
      _FakeFirebaseAuth(_FakeFirebaseUser('user-456')),
      clientFactory: () {
        clientFactoryCalls += 1;
        return _RecordingHttpClient((request) async => _jsonResponse(200));
      },
      appCheckTokenProvider: _validAppCheckToken,
      idTokenProvider: (user, forceRefresh) async {
        tokenProviderCalls += 1;
        return 'token-b';
      },
    );

    final result = await dataSource.process('user-123', createTaskItem());

    expect(result.shouldRetry, isTrue);
    expect(result.code, 'SESSION_STOPPED');
    expect(clientFactoryCalls, 0);
    expect(tokenProviderCalls, 0);
  });

  test('troca de A para B após 401 impede refresh e segundo request', () async {
    var requestCount = 0;
    final tokenUsers = <String>[];
    final forceRefreshCalls = <bool>[];
    final authorizations = <String?>[];
    final auth = _FakeFirebaseAuth(_FakeFirebaseUser('user-123'));
    final client = _RecordingHttpClient((request) async {
      requestCount += 1;
      authorizations.add(request.headers['authorization']);
      auth.user = _FakeFirebaseUser('user-456');
      return _jsonResponse(401);
    });
    final dataSource = FirestoreSyncRemoteDataSource(
      captureRemoteSend: (_) => RemoteSendPermit(() => true),
      _RecordingFirestore(
        _RecordingUsersCollectionReference(
          _RecordingUserDocumentReference(
            _RecordingHealthCollectionReference(healthDoc),
          ),
        ),
      ),
      auth,
      clientFactory: () => client,
      appCheckTokenProvider: _validAppCheckToken,
      idTokenProvider: (user, forceRefresh) async {
        tokenUsers.add(user.uid);
        forceRefreshCalls.add(forceRefresh);
        return user.uid == 'user-123' ? 'token-a' : 'token-b';
      },
    );

    final result = await dataSource.process('user-123', createTaskItem());

    expect(result.shouldRetry, isTrue);
    expect(result.code, 'SESSION_STOPPED');
    expect(requestCount, 1);
    expect(tokenUsers, ['user-123']);
    expect(forceRefreshCalls, [false]);
    expect(authorizations, ['Bearer token-a']);
    expect(client.wasClosed, isTrue);
  });

  test('HTTP 401 renova token e repete a requisição somente uma vez', () async {
    var requestCount = 0;
    var appCheckTokenCalls = 0;
    final forceRefreshCalls = <bool>[];
    final authorizations = <String?>[];
    final appCheckHeaders = <String?>[];
    final client = _RecordingHttpClient((request) async {
      requestCount += 1;
      authorizations.add(request.headers['authorization']);
      appCheckHeaders.add(request.headers['x-firebase-appcheck']);
      return _jsonResponse(requestCount == 1 ? 401 : 200);
    });
    final dataSource = FirestoreSyncRemoteDataSource(
      captureRemoteSend: (_) => RemoteSendPermit(() => true),
      _RecordingFirestore(
        _RecordingUsersCollectionReference(
          _RecordingUserDocumentReference(
            _RecordingHealthCollectionReference(healthDoc),
          ),
        ),
      ),
      _FakeFirebaseAuth(_FakeFirebaseUser('user-123')),
      clientFactory: () => client,
      appCheckTokenProvider: () async {
        appCheckTokenCalls += 1;
        return 'firebase-app-check-token';
      },
      idTokenProvider: (user, forceRefresh) async {
        expect(user.uid, 'user-123');
        forceRefreshCalls.add(forceRefresh);
        return forceRefresh ? 'fresh-token' : 'stale-token';
      },
    );

    final result = await dataSource.process('user-123', createTaskItem());

    expect(result.isSuccess, isTrue);
    expect(requestCount, 2);
    expect(forceRefreshCalls, [false, true]);
    expect(authorizations, ['Bearer stale-token', 'Bearer fresh-token']);
    expect(appCheckTokenCalls, 1);
    expect(appCheckHeaders, [
      'firebase-app-check-token',
      'firebase-app-check-token',
    ]);
    expect(client.wasClosed, isTrue);
  });

  test('segundo HTTP 401 não cria loop e permanece retryable', () async {
    var requestCount = 0;
    final forceRefreshCalls = <bool>[];
    final client = _RecordingHttpClient((request) async {
      requestCount += 1;
      return _jsonResponse(401);
    });
    final dataSource = FirestoreSyncRemoteDataSource(
      captureRemoteSend: (_) => RemoteSendPermit(() => true),
      _RecordingFirestore(
        _RecordingUsersCollectionReference(
          _RecordingUserDocumentReference(
            _RecordingHealthCollectionReference(healthDoc),
          ),
        ),
      ),
      _FakeFirebaseAuth(_FakeFirebaseUser('user-123')),
      clientFactory: () => client,
      appCheckTokenProvider: _validAppCheckToken,
      idTokenProvider: (user, forceRefresh) async {
        expect(user.uid, 'user-123');
        forceRefreshCalls.add(forceRefresh);
        return forceRefresh ? 'fresh-token' : 'stale-token';
      },
    );

    final result = await dataSource.process('user-123', createTaskItem());

    expect(result.shouldRetry, isTrue);
    expect(result.code, 'AUTHENTICATION_REQUIRED');
    expect(requestCount, 2);
    expect(forceRefreshCalls, [false, true]);
    expect(client.wasClosed, isTrue);
  });

  test('timeout do backend é retryable e sempre fecha o client', () async {
    final neverCompletes = Completer<http.StreamedResponse>();
    final client = _RecordingHttpClient((request) => neverCompletes.future);
    final dataSource = FirestoreSyncRemoteDataSource(
      captureRemoteSend: (_) => RemoteSendPermit(() => true),
      _RecordingFirestore(
        _RecordingUsersCollectionReference(
          _RecordingUserDocumentReference(
            _RecordingHealthCollectionReference(healthDoc),
          ),
        ),
      ),
      _FakeFirebaseAuth(_FakeFirebaseUser('user-123')),
      clientFactory: () => client,
      appCheckTokenProvider: _validAppCheckToken,
      idTokenProvider: (user, forceRefresh) async {
        expect(user.uid, 'user-123');
        return 'token';
      },
      requestTimeout: const Duration(milliseconds: 10),
    );

    final result = await dataSource.process('user-123', createTaskItem());

    expect(result.shouldRetry, isTrue);
    expect(result.code, 'SYNC_TIMEOUT');
    expect(client.wasClosed, isTrue);
  });

  test('Task update competitivo é enviado somente pelo backend', () async {
    late Map<String, dynamic> payload;
    final client = _RecordingHttpClient((request) async {
      payload = jsonDecode(await request.finalize().bytesToString());
      return _jsonResponse(200);
    });
    final dataSource = FirestoreSyncRemoteDataSource(
      captureRemoteSend: (_) => RemoteSendPermit(() => true),
      _RecordingFirestore(
        _RecordingUsersCollectionReference(
          _RecordingUserDocumentReference(
            _RecordingHealthCollectionReference(healthDoc),
          ),
        ),
      ),
      _FakeFirebaseAuth(_FakeFirebaseUser('user-123')),
      clientFactory: () => client,
      appCheckTokenProvider: _validAppCheckToken,
      idTokenProvider: (_, _) async => 'token',
    );

    final result = await dataSource.process('user-123', createTaskUpdateItem());

    expect(result.isSuccess, isTrue);
    expect(payload, {
      'operation': 'update_task',
      'taskId': 'task-1',
      'isCompleted': true,
    });
  });

  for (final entry in <String, SyncQueueTableData>{
    'TASK_NOT_FOUND': createTaskUpdateItem(),
    'HABIT_NOT_FOUND': createHabitUpdateItem(),
  }.entries) {
    test('HTTP 404 ${entry.key} é falha permanente', () async {
      final client = _RecordingHttpClient(
        (_) async => _jsonResponse(
          404,
          jsonEncode({'code': entry.key, 'error': 'Recurso não encontrado.'}),
        ),
      );
      final source = serverDataSource(
        auth: _FakeFirebaseAuth(_FakeFirebaseUser('user-123')),
        clientFactory: () => client,
        idTokenProvider: (_, _) async => 'token',
        appCheckTokenProvider: _validAppCheckToken,
      );

      final result = await source.process('user-123', entry.value);

      expect(result.isPermanentFailure, isTrue);
      expect(result.shouldRetry, isFalse);
      expect(result.code, 'INVALID_PAYLOAD');
      expect(client.wasClosed, isTrue);
    });
  }

  for (final code in ['USER_NOT_FOUND', 'UNKNOWN_NOT_FOUND']) {
    test('HTTP 404 $code permanece retryable', () async {
      final client = _RecordingHttpClient(
        (_) async => _jsonResponse(
          404,
          jsonEncode({'code': code, 'error': 'Recurso não encontrado.'}),
        ),
      );
      final source = serverDataSource(
        auth: _FakeFirebaseAuth(_FakeFirebaseUser('user-123')),
        clientFactory: () => client,
        idTokenProvider: (_, _) async => 'token',
        appCheckTokenProvider: _validAppCheckToken,
      );

      final result = await source.process('user-123', createTaskUpdateItem());

      expect(result.shouldRetry, isTrue);
      expect(result.isPermanentFailure, isFalse);
      expect(result.code, code);
      expect(client.wasClosed, isTrue);
    });
  }

  test('HTTP 404 sem código permanece retryable', () async {
    final client = _RecordingHttpClient((_) async => _jsonResponse(404));
    final source = serverDataSource(
      auth: _FakeFirebaseAuth(_FakeFirebaseUser('user-123')),
      clientFactory: () => client,
      idTokenProvider: (_, _) async => 'token',
      appCheckTokenProvider: _validAppCheckToken,
    );

    final result = await source.process('user-123', createTaskUpdateItem());

    expect(result.shouldRetry, isTrue);
    expect(result.code, 'BACKEND_404');
    expect(client.wasClosed, isTrue);
  });

  test('Task update preserva false no payload HTTP', () async {
    late Map<String, dynamic> payload;
    final client = _RecordingHttpClient((request) async {
      payload = jsonDecode(await request.finalize().bytesToString());
      return _jsonResponse(200);
    });
    final dataSource = FirestoreSyncRemoteDataSource(
      captureRemoteSend: (_) => RemoteSendPermit(() => true),
      _RecordingFirestore(
        _RecordingUsersCollectionReference(
          _RecordingUserDocumentReference(
            _RecordingHealthCollectionReference(healthDoc),
          ),
        ),
      ),
      _FakeFirebaseAuth(_FakeFirebaseUser('user-123')),
      clientFactory: () => client,
      appCheckTokenProvider: _validAppCheckToken,
      idTokenProvider: (_, _) async => 'token',
    );
    final result = await dataSource.process(
      'user-123',
      createTaskUpdateItem(isCompleted: false),
    );
    expect(result.isSuccess, isTrue);
    expect(payload, {
      'operation': 'update_task',
      'taskId': 'task-1',
      'isCompleted': false,
    });
  });

  test('Habit update normal não solicita atividade competitiva', () async {
    late Map<String, dynamic> payload;
    final client = _RecordingHttpClient((request) async {
      payload = jsonDecode(await request.finalize().bytesToString());
      return _jsonResponse(200);
    });
    final dataSource = FirestoreSyncRemoteDataSource(
      captureRemoteSend: (_) => RemoteSendPermit(() => true),
      _RecordingFirestore(
        _RecordingUsersCollectionReference(
          _RecordingUserDocumentReference(
            _RecordingHealthCollectionReference(healthDoc),
          ),
        ),
      ),
      _FakeFirebaseAuth(_FakeFirebaseUser('user-123')),
      clientFactory: () => client,
      appCheckTokenProvider: _validAppCheckToken,
      idTokenProvider: (_, _) async => 'token',
    );

    final result = await dataSource.process(
      'user-123',
      createHabitUpdateItem(),
    );

    expect(result.isSuccess, isTrue);
    expect(payload, {
      'operation': 'update_habit',
      'habitId': 'habit-1',
      'completedDates': ['2026-08-23'],
    });
  });

  test('conclusão de Habit preserva idempotency key da SyncQueue', () async {
    late Map<String, dynamic> payload;
    final client = _RecordingHttpClient((request) async {
      payload = jsonDecode(await request.finalize().bytesToString());
      return _jsonResponse(200);
    });
    final dataSource = FirestoreSyncRemoteDataSource(
      captureRemoteSend: (_) => RemoteSendPermit(() => true),
      _RecordingFirestore(
        _RecordingUsersCollectionReference(
          _RecordingUserDocumentReference(
            _RecordingHealthCollectionReference(healthDoc),
          ),
        ),
      ),
      _FakeFirebaseAuth(_FakeFirebaseUser('user-123')),
      clientFactory: () => client,
      appCheckTokenProvider: _validAppCheckToken,
      idTokenProvider: (_, _) async => 'token',
    );

    final result = await dataSource.process(
      'user-123',
      createHabitCompletionItem(),
    );

    expect(result.isSuccess, isTrue);
    expect(payload, {
      'operation': 'update_habit_completion',
      'habitId': 'habit-1',
      'completedDates': ['2026-08-23'],
      'competitiveCompletionId': '7d287d4e-190f-42ab-90a8-a93696f8c462',
    });
  });

  test(
    'falha retryable preserva o mesmo update competitivo para retry',
    () async {
      var attempts = 0;
      final payloads = <Map<String, dynamic>>[];
      final dataSource = FirestoreSyncRemoteDataSource(
        captureRemoteSend: (_) => RemoteSendPermit(() => true),
        _RecordingFirestore(
          _RecordingUsersCollectionReference(
            _RecordingUserDocumentReference(
              _RecordingHealthCollectionReference(healthDoc),
            ),
          ),
        ),
        _FakeFirebaseAuth(_FakeFirebaseUser('user-123')),
        clientFactory: () => _RecordingHttpClient((request) async {
          attempts += 1;
          payloads.add(jsonDecode(await request.finalize().bytesToString()));
          return _jsonResponse(attempts == 1 ? 503 : 200);
        }),
        appCheckTokenProvider: _validAppCheckToken,
        idTokenProvider: (_, _) async => 'token',
      );
      final item = createHabitCompletionItem();

      final first = await dataSource.process('user-123', item);
      final second = await dataSource.process('user-123', item);

      expect(first.shouldRetry, isTrue);
      expect(second.isSuccess, isTrue);
      expect(payloads, hasLength(2));
      expect(payloads[1], payloads[0]);
    },
  );

  test('UUID competitivo inválido não inicia request remoto', () async {
    var clientCreated = false;
    final source = FirestoreSyncRemoteDataSource(
      captureRemoteSend: (_) => RemoteSendPermit(() => true),
      _RecordingFirestore(
        _RecordingUsersCollectionReference(
          _RecordingUserDocumentReference(
            _RecordingHealthCollectionReference(healthDoc),
          ),
        ),
      ),
      _FakeFirebaseAuth(_FakeFirebaseUser('user-123')),
      clientFactory: () {
        clientCreated = true;
        return _RecordingHttpClient((_) async => _jsonResponse(200));
      },
    );
    final item = createHabitCompletionItem().copyWith(
      payloadJson: jsonEncode({
        'completedDates': ['2026-08-23'],
        'competitiveCompletionId': 'not-a-uuid',
      }),
    );

    final result = await source.process('user-123', item);

    expect(result.isPermanentFailure, isTrue);
    expect(result.code, 'INVALID_PAYLOAD');
    expect(clientCreated, isFalse);
  });

  test(
    'study_activity create envia intent ao backend sem write direto',
    () async {
      late Map<String, dynamic> payload;
      final client = _RecordingHttpClient((request) async {
        payload = jsonDecode(await request.finalize().bytesToString());
        return _jsonResponse(200);
      });
      final source = serverDataSource(
        auth: _FakeFirebaseAuth(_FakeFirebaseUser('user-123')),
        clientFactory: () => client,
        idTokenProvider: (_, _) async => 'token',
        appCheckTokenProvider: _validAppCheckToken,
      );

      final result = await source.process(
        'user-123',
        createStudyActivityItem(),
      );

      expect(result.isSuccess, isTrue);
      expect(payload, {
        'operation': 'apply_study_activity',
        'mutationId': '7d287d4e-190f-42ab-90a8-a93696f8c462',
        'subjectId': 'subject-1',
        'progressDelta': .25,
        'occurredAt': '2026-09-09T12:00:00.000Z',
        'timeZoneOffsetMinutes': -180,
      });
      expect(healthDoc.lastData, isNull);
      expect(healthDoc.updateCalls, 0);
      expect(client.wasClosed, isTrue);
    },
  );

  test('study_activity mutationId inválido falha sem HTTP', () async {
    var clientCreated = false;
    final source = serverDataSource(
      auth: _FakeFirebaseAuth(_FakeFirebaseUser('user-123')),
      clientFactory: () {
        clientCreated = true;
        return _RecordingHttpClient((_) async => _jsonResponse(200));
      },
      idTokenProvider: (_, _) async => 'token',
      appCheckTokenProvider: _validAppCheckToken,
    );

    final result = await source.process(
      'user-123',
      createStudyActivityItem(mutationId: 'not-a-uuid'),
    );

    expect(result.isPermanentFailure, isTrue);
    expect(result.code, 'INVALID_PAYLOAD');
    expect(clientCreated, isFalse);
  });

  test('study_activity progressDelta inválido falha sem HTTP', () async {
    var clientCreated = false;
    final source = serverDataSource(
      auth: _FakeFirebaseAuth(_FakeFirebaseUser('user-123')),
      clientFactory: () {
        clientCreated = true;
        return _RecordingHttpClient((_) async => _jsonResponse(200));
      },
      idTokenProvider: (_, _) async => 'token',
      appCheckTokenProvider: _validAppCheckToken,
    );

    final result = await source.process(
      'user-123',
      createStudyActivityItem(progressDelta: 0),
    );

    expect(result.isPermanentFailure, isTrue);
    expect(result.code, 'INVALID_PAYLOAD');
    expect(clientCreated, isFalse);
  });

  test('study_activity timezone inválido falha sem HTTP', () async {
    var clientCreated = false;
    final source = serverDataSource(
      auth: _FakeFirebaseAuth(_FakeFirebaseUser('user-123')),
      clientFactory: () {
        clientCreated = true;
        return _RecordingHttpClient((_) async => _jsonResponse(200));
      },
      idTokenProvider: (_, _) async => 'token',
      appCheckTokenProvider: _validAppCheckToken,
    );

    final result = await source.process(
      'user-123',
      createStudyActivityItem(timeZoneOffsetMinutes: 841),
    );

    expect(result.isPermanentFailure, isTrue);
    expect(result.code, 'INVALID_PAYLOAD');
    expect(clientCreated, isFalse);
  });

  test('study_activity subject ausente é falha permanente', () async {
    final client = _RecordingHttpClient(
      (_) async => _jsonResponse(
        409,
        jsonEncode({
          'code': 'STUDY_ACTIVITY_SUBJECT_NOT_FOUND',
          'error': 'A matéria da atividade de estudo não foi encontrada.',
        }),
      ),
    );
    final source = serverDataSource(
      auth: _FakeFirebaseAuth(_FakeFirebaseUser('user-123')),
      clientFactory: () => client,
      idTokenProvider: (_, _) async => 'token',
      appCheckTokenProvider: _validAppCheckToken,
    );

    final result = await source.process('user-123', createStudyActivityItem());

    expect(result.isPermanentFailure, isTrue);
    expect(result.code, 'INVALID_PAYLOAD');
    expect(result.message, contains('STUDY_ACTIVITY_SUBJECT_NOT_FOUND'));
    expect(client.wasClosed, isTrue);
  });

  test('review update chama backend sem transaction ou write direto', () async {
    late Map<String, dynamic> payload;
    final firestore = _TransactionalStudyFirestore();
    seedReviewState(firestore);
    final before = {
      for (final entry in firestore.data.entries)
        entry.key: Map<String, dynamic>.from(entry.value),
    };
    final client = _RecordingHttpClient((request) async {
      payload = jsonDecode(await request.finalize().bytesToString());
      return _jsonResponse(200);
    });
    final source = FirestoreSyncRemoteDataSource(
      captureRemoteSend: (_) => RemoteSendPermit(() => true),
      firestore,
      _FakeFirebaseAuth(_FakeFirebaseUser('user-123')),
      clientFactory: () => client,
      idTokenProvider: (_, _) async => 'token',
      appCheckTokenProvider: _validAppCheckToken,
    );

    final result = await source.process('user-123', reviewUpdateItem('card-1'));

    expect(result.isSuccess, isTrue);
    expect(payload, {
      'operation': 'apply_study_review',
      'cardId': 'card-1',
      'subjectId': 'subject-1',
      'occurredAt': '2026-09-08T10:00:00.000Z',
      'timeZoneOffsetMinutes': -180,
    });
    expect(firestore.transactionCommits, 0);
    expect(firestore.data, before);
    expect(client.wasClosed, isTrue);
  });

  final invalidReviewUpdates = <({String name, SyncQueueTableData item})>[
    (name: 'cardId vazio', item: reviewUpdateItem('')),
    (name: 'cardId com barra', item: reviewUpdateItem('invalid/id')),
    (name: 'subjectId vazio', item: reviewUpdateItem('card-1', subjectId: '')),
    (
      name: 'subjectId com barra',
      item: reviewUpdateItem('card-1', subjectId: 'invalid/id'),
    ),
    (
      name: 'lastReviewed inválido',
      item: reviewUpdateItem('card-1', lastReviewed: 'invalid'),
    ),
    (
      name: 'lastReviewed sem timezone',
      item: reviewUpdateItem('card-1', lastReviewed: '2026-09-08T10:00:00.000'),
    ),
    (
      name: 'timezone fora do limite',
      item: reviewUpdateItem('card-1', timeZoneOffsetMinutes: 841),
    ),
    (
      name: 'campo extra',
      item: reviewUpdateItem(
        'card-1',
        payload: {
          'subjectId': 'subject-1',
          'lastReviewed': '2026-09-08T10:00:00.000Z',
          'timeZoneOffsetMinutes': -180,
          'extra': true,
        },
      ),
    ),
  ];

  for (final invalidReviewUpdate in invalidReviewUpdates) {
    test(
      'review update rejeita ${invalidReviewUpdate.name} sem HTTP',
      () async {
        var clientCreated = false;
        final source = serverDataSource(
          auth: _FakeFirebaseAuth(_FakeFirebaseUser('user-123')),
          clientFactory: () {
            clientCreated = true;
            return _RecordingHttpClient((_) async => _jsonResponse(200));
          },
          idTokenProvider: (_, _) async => 'token',
          appCheckTokenProvider: _validAppCheckToken,
        );

        final result = await source.process(
          'user-123',
          invalidReviewUpdate.item,
        );

        expect(result.isPermanentFailure, isTrue);
        expect(result.code, 'INVALID_PAYLOAD');
        expect(clientCreated, isFalse);
      },
    );
  }

  test('F01 review backend 409 retains original recovery code', () async {
    final client = _RecordingHttpClient(
      (_) async => _jsonResponse(
        409,
        jsonEncode({
          'code': 'STUDY_REVIEW_STATE_INVALID',
          'error': 'O estado remoto da revisão de estudo está inconsistente.',
        }),
      ),
    );
    final source = serverDataSource(
      auth: _FakeFirebaseAuth(_FakeFirebaseUser('user-123')),
      clientFactory: () => client,
      idTokenProvider: (_, _) async => 'token',
      appCheckTokenProvider: _validAppCheckToken,
    );

    final result = await source.process('user-123', reviewUpdateItem('card-1'));

    expect(result.isPermanentFailure, isFalse);
    expect(result.shouldRetry, isTrue);
    expect(result.isSuccess, isFalse);
    expect(result.code, 'STUDY_REVIEW_STATE_INVALID');
    expect(result.message, isNull);
    expect(client.wasClosed, isTrue);
  });

  test('review HTTP transitório continua retryable', () async {
    final client = _RecordingHttpClient((_) async => _jsonResponse(503));
    final source = serverDataSource(
      auth: _FakeFirebaseAuth(_FakeFirebaseUser('user-123')),
      clientFactory: () => client,
      idTokenProvider: (_, _) async => 'token',
      appCheckTokenProvider: _validAppCheckToken,
    );

    final result = await source.process('user-123', reviewUpdateItem('card-1'));

    expect(result.shouldRetry, isTrue);
    expect(client.wasClosed, isTrue);
  });

  test(
    'study_progress_reset envia intent ao backend sem write direto',
    () async {
      late Map<String, dynamic> payload;
      final client = _RecordingHttpClient((request) async {
        payload = jsonDecode(await request.finalize().bytesToString());
        return _jsonResponse(200);
      });
      final source = serverDataSource(
        auth: _FakeFirebaseAuth(_FakeFirebaseUser('user-123')),
        clientFactory: () => client,
        idTokenProvider: (_, _) async => 'token',
        appCheckTokenProvider: _validAppCheckToken,
      );

      final result = await source.process(
        'user-123',
        createStudyProgressResetItem(),
      );

      expect(result.isSuccess, isTrue);
      expect(payload, {
        'operation': 'apply_study_progress_reset',
        'mutationId': '5a3ccf1f-d43e-4a34-823d-61ed255e568a',
        'occurredAt': '2026-09-09T10:00:00.000Z',
      });
      expect(healthDoc.lastData, isNull);
      expect(healthDoc.updateCalls, 0);
      expect(client.wasClosed, isTrue);
    },
  );

  test('study_progress_reset inválido falha sem HTTP', () async {
    for (final item in [
      createStudyProgressResetItem(mutationId: 'not-a-uuid'),
      createStudyProgressResetItem(
        payload: {'occurredAt': '2026-09-09T10:00:00.000Z', 'extra': true},
      ),
      createStudyProgressResetItem(occurredAt: 'invalid'),
      createStudyProgressResetItem(occurredAt: '2026-09-09T10:00:00.000'),
    ]) {
      var clientCreated = false;
      final source = serverDataSource(
        auth: _FakeFirebaseAuth(_FakeFirebaseUser('user-123')),
        clientFactory: () {
          clientCreated = true;
          return _RecordingHttpClient((_) async => _jsonResponse(200));
        },
        idTokenProvider: (_, _) async => 'token',
        appCheckTokenProvider: _validAppCheckToken,
      );

      final result = await source.process('user-123', item);

      expect(result.isPermanentFailure, isTrue);
      expect(result.code, 'INVALID_PAYLOAD');
      expect(clientCreated, isFalse);
    }
  });

  for (final operation in ['create', 'update', 'delete']) {
    for (final value in [0, 1000, null, 'invalid']) {
      test(
        'legacy water $operation with $value never reaches Firestore or HTTP',
        () async {
          healthDoc.storedData.addAll({
            'waterIntakeMl': 1000,
            'mood': 'Before',
          });
          final before = Map<String, dynamic>.of(healthDoc.storedData);
          final item = createHealthItem(
            operationType: operation,
            payload: {
              'waterIntakeMl': value,
              'mood': 'Mixed',
              'date': '2026-08-21T10:00:00.000Z',
            },
          );
          final result = await remote.process('user-123', item);
          expect(result.isSuccess, isFalse);
          expect(result.shouldRetry, isTrue);
          expect(result.code, 'LEGACY_WATER_BLOCKED');
          expect(healthDoc.setCalls, 0);
          expect(healthDoc.updateCalls, 0);
          expect(healthDoc.storedData, before);
        },
      );
    }
  }
  test(
    'health delete without water payload is retained without deleting projection',
    () async {
      final result = await remote.process(
        'user-123',
        createHealthItem(operationType: 'delete', payload: {}),
      );
      expect(result.code, 'LEGACY_WATER_BLOCKED');
      expect(result.isSuccess, isFalse);
      expect(healthDoc.setCalls, 0);
    },
  );
  test('pill partial payload still merges without changing water', () async {
    healthDoc.storedData.addAll({'waterIntakeMl': 1250, 'mood': 'Before'});
    final result = await remote.process(
      'user-123',
      createHealthItem(
        operationType: 'update',
        payload: {
          'hasTakenPillToday': true,
          'date': '2026-08-21T10:00:00.000Z',
        },
      ),
    );
    expect(result.isSuccess, isTrue);
    expect(healthDoc.storedData['waterIntakeMl'], 1250);
    expect(healthDoc.storedData['mood'], 'Before');
    expect(healthDoc.storedData['hasTakenPillToday'], isTrue);
  });

  group('P1 R5 Firestore ambiguity is not an authoritative rejection', () {
    for (final code in [
      'permission-denied',
      'unauthenticated',
      'unavailable',
      'deadline-exceeded',
    ]) {
      for (final update in [false, true]) {
        test(
          '$code before ${update ? 'update' : 'set'} stays unconfirmed',
          () async {
            final error = FirebaseException(
              plugin: 'cloud_firestore',
              code: code,
            );
            if (update) {
              healthDoc.updateError = error;
            } else {
              healthDoc.setError = error;
            }
            final item = update
                ? createGoalUpdateItem({'currentValue': 1})
                : focusItem();
            final original = item.toJson();
            final result = await remote.process('user-123', item);
            expect(result.shouldRetry, isTrue);
            expect(result.isSuccess, isFalse);
            expect(result.isPermanentFailure, isFalse);
            expect(
              result.code,
              code == 'permission-denied'
                  ? 'FIRESTORE_PERMISSION_UNCONFIRMED'
                  : code == 'unauthenticated'
                  ? 'AUTHENTICATION_REQUIRED'
                  : code.toUpperCase(),
            );
            expect(result.code, isNot('ACCOUNT_DELETION_BLOCKED'));
            expect(healthDoc.storedData, isEmpty);
            expect(item.toJson(), original);
          },
        );
      }
    }
    test(
      'plain TimeoutException does not produce a success or permanent reject',
      () async {
        healthDoc.setError = TimeoutException('synthetic timeout');
        final result = await remote.process('user-123', focusItem());
        expect(result.shouldRetry, isTrue);
        expect(result.code, 'SYNC_TIMEOUT');
        expect(result.isSuccess, isFalse);
        expect(healthDoc.storedData, isEmpty);
      },
    );
    for (final code in [
      'invalid-argument',
      'failed-precondition',
      'not-found',
    ]) {
      test('existing definitive $code contract stays terminal', () async {
        healthDoc.updateError = FirebaseException(
          plugin: 'cloud_firestore',
          code: code,
        );
        final result = await remote.process(
          'user-123',
          createGoalUpdateItem({'currentValue': 1}),
        );
        expect(result.isPermanentFailure, isTrue);
        expect(result.code, 'INVALID_PAYLOAD');
        expect(healthDoc.storedData, isEmpty);
      });
    }
    test('a non-Firestore permission error is not remapped globally', () async {
      healthDoc.setError = FirebaseException(
        plugin: 'other-synthetic-plugin',
        code: 'permission-denied',
      );
      final result = await remote.process('user-123', focusItem());
      expect(result.isPermanentFailure, isTrue);
      expect(result.code, 'PERMISSION_DENIED');
    });
    test(
      'after-write unknown result is retryable, never inferred successful',
      () async {
        healthDoc.afterSetError = FirebaseException(
          plugin: 'cloud_firestore',
          code: 'deadline-exceeded',
        );
        final item = focusItem();
        final result = await remote.process('user-123', item);
        expect(healthDoc.storedData, {
          'targetId': 'task-1',
          'targetType': 'TASK',
          'durationSeconds': 1200,
          'timestamp': Timestamp.fromDate(DateTime.utc(2026, 9, 24, 10)),
        });
        expect(result.shouldRetry, isTrue);
        expect(result.isSuccess, isFalse);
        healthDoc.afterSetError = null;
        expect((await remote.process('user-123', item)).isSuccess, isTrue);
        expect(healthDoc.storedData, {
          'targetId': 'task-1',
          'targetType': 'TASK',
          'durationSeconds': 1200,
          'timestamp': Timestamp.fromDate(DateTime.utc(2026, 9, 24, 10)),
        });
        expect(healthDoc.setCalls, 2);
      },
    );
    for (final status in [401, 403, 409, 503]) {
      test('HTTP $status preserves its independent backend contract', () async {
        final client = _RecordingHttpClient(
          (_) async => _jsonResponse(
            status,
            jsonEncode({
              'code': status == 503
                  ? 'ACCOUNT_DELETION_BLOCKED'
                  : 'SYNTHETIC_BACKEND_ERROR',
              'error': 'synthetic',
            }),
          ),
        );
        final source = serverDataSource(
          auth: _FakeFirebaseAuth(_FakeFirebaseUser('user-123')),
          clientFactory: () => client,
          idTokenProvider: (_, _) async => 'synthetic-token',
          appCheckTokenProvider: _validAppCheckToken,
        );
        final result = await source.process('user-123', createTaskItem());
        expect(result.isSuccess, isFalse);
        if (status == 403) {
          expect(result.isPermanentFailure, isTrue);
          expect(result.code, 'PERMISSION_DENIED');
        }
        if (status == 409) {
          expect(result.isPermanentFailure, isTrue);
          expect(result.code, 'INVALID_PAYLOAD');
        }
        if (status == 401 || status == 503) expect(result.shouldRetry, isTrue);
        if (status == 503) expect(result.code, 'BACKEND_503');
        expect(healthDoc.setCalls, 0);
        expect(client.wasClosed, isTrue);
      });
    }
  });

  group('P1 no-op evidence is distinct from write authorization', () {
    test(
      'existing card with no counter evidence stays pending and untouched',
      () async {
        final firestore = _TransactionalStudyFirestore()
          ..seed('users/user-123/review_queue/card-1', {
            'subjectId': 'subject-1',
            'question': 'existing',
          })
          ..seed('users/user-123/subjects/subject-1', {'cardsToReview': 0});
        final before = jsonEncode(firestore.data);
        final result = await transactionalStudyRemote(
          firestore,
        ).process('user-123', reviewCreateItem('card-1'));
        expect(result.code, 'REVIEW_CREATE_LEGACY_UNVERIFIED');
        expect(result.shouldRetry, isTrue);
        expect(result.isSuccess, isFalse);
        expect(jsonEncode(firestore.data), before);
        expect(firestore.transactionWrites, 0);
      },
    );
    test(
      'legacy unknown historical commit remains pending without repeating Client SDK transaction',
      () async {
        final firestore = _TransactionalStudyFirestore()
          ..seed('users/user-123/subjects/subject-1', {'cardsToReview': 0})
          ..afterCommitError = FirebaseException(
            plugin: 'cloud_firestore',
            code: 'deadline-exceeded',
          );
        final source = transactionalStudyRemote(firestore),
            item = reviewCreateItem('card-1');
        expect((await source.process('user-123', item)).shouldRetry, isTrue);
        firestore.afterCommitError = null;
        final replay = await source.process('user-123', item);
        expect(replay.shouldRetry, isTrue);
        expect(replay.code, 'REVIEW_CREATE_LEGACY_UNVERIFIED');
        expect(
          firestore.read('users/user-123/study_info/main')?['reviewQueue'],
          isNull,
        );
        expect(
          firestore.read('users/user-123/subjects/subject-1')?['cardsToReview'],
          0,
        );
        expect(firestore.transactionWrites, 0);
      },
    );
    SyncQueueTableData notificationItem() => createStudyItem(
      collection: 'notifications',
      docId: 'health_med_synthetic',
      operationType: 'delete',
      payload: {
        'occurrenceKey': NotificationOccurrence.key(
          id: 'health_med_synthetic',
          moduleType: 'health',
          dueDate: DateTime.utc(2026, 10, 28, 10),
        ),
      },
    );
    FirestoreSyncRemoteDataSource notificationSource(
      _TransactionalStudyFirestore firestore,
    ) => FirestoreSyncRemoteDataSource(
      captureRemoteSend: (_) => RemoteSendPermit(() => true),
      firestore,
      _FakeFirebaseAuth(_FakeFirebaseUser('user-123')),
    );
    Map<String, dynamic> notification({bool changed = false}) => {
      'moduleType': 'health',
      'dueDate': Timestamp.fromDate(
        DateTime.utc(2026, 10, 28, changed ? 11 : 10),
      ),
      'createdAt': Timestamp.fromDate(DateTime.utc(2026, 10, 28)),
    };
    for (final existing in [false, true]) {
      test(
        'confirmed server ${existing ? 'different occurrence is obsolete' : 'absence meets delete postcondition'} without a write',
        () async {
          final firestore = _TransactionalStudyFirestore();
          const path = 'users/user-123/notifications/health_med_synthetic';
          if (existing) firestore.seed(path, notification(changed: true));
          final result = await notificationSource(
            firestore,
          ).process('user-123', notificationItem());
          expect(result.isSuccess, isTrue);
          expect(firestore.transactionWrites, 0);
          expect(
            firestore.read(path),
            existing ? notification(changed: true) : isNull,
          );
        },
      );
      for (final cached in [true, false]) {
        test(
          'unconfirmed ${existing ? 'changed' : 'absent'} notification snapshot cache=$cached never ACKs',
          () async {
            final firestore = _TransactionalStudyFirestore()
              ..fromCache = cached
              ..pendingWrites = !cached;
            if (existing)
              firestore.seed(
                'users/user-123/notifications/health_med_synthetic',
                notification(changed: true),
              );
            final result = await notificationSource(
              firestore,
            ).process('user-123', notificationItem());
            expect(result.shouldRetry, isTrue);
            expect(result.code, 'FIRESTORE_RESULT_UNCONFIRMED');
            expect(result.isSuccess, isFalse);
            expect(firestore.transactionWrites, 0);
          },
        );
      }
    }
    test(
      'matching notification delete commits once; confirmed absence then replays idempotently',
      () async {
        final firestore = _TransactionalStudyFirestore()
          ..seed(
            'users/user-123/notifications/health_med_synthetic',
            notification(),
          );
        final source = notificationSource(firestore), item = notificationItem();
        expect((await source.process('user-123', item)).isSuccess, isTrue);
        expect((await source.process('user-123', item)).isSuccess, isTrue);
        expect(firestore.transactionWrites, 1);
        expect(
          firestore.read('users/user-123/notifications/health_med_synthetic'),
          isNull,
        );
      },
    );
    test(
      'notification transaction permission-denied never confirms its no-op or delete',
      () async {
        final firestore = _TransactionalStudyFirestore()
          ..transactionError = FirebaseException(
            plugin: 'cloud_firestore',
            code: 'permission-denied',
          );
        final result = await notificationSource(
          firestore,
        ).process('user-123', notificationItem());
        expect(result.shouldRetry, isTrue);
        expect(result.code, 'FIRESTORE_PERMISSION_UNCONFIRMED');
        expect(result.isSuccess, isFalse);
        expect(firestore.transactionWrites, 0);
      },
    );
  });
  group('ReviewQueue creation v1 backend ACK', () {
    Map<String, dynamic> local({
      String card = 'card-1',
      String question = 'Q',
      String answer = 'A',
      String date = '2026-10-28T12:34:56.123456Z',
    }) => {
      'creationProtocolVersion': 1,
      'cardId': card,
      'subjectId': 'subject-1',
      'question': question,
      'answer': answer,
      'createdAt': date,
    };
    SyncQueueTableData row(
      Map<String, dynamic> payload, {
      String uid = 'uid-a',
      String id = 'card-1',
    }) => createStudyItem(
      collection: 'review_queue',
      docId: id,
      operationType: 'create',
      payload: payload,
    ).copyWith(ownerUid: Value(uid));
    Map<String, dynamic> ack(
      Map<String, dynamic> request, {
      String uid = 'uid-a',
      String outcome = 'APPLIED',
    }) {
      final frame = <int>[];
      for (final value in [
        'review-create-v1',
        uid,
        request['cardId'],
        request['subjectId'],
        request['question'],
        request['answer'],
        request['createdAt'],
      ]) {
        final bytes = utf8.encode(value as String);
        frame
          ..addAll(ascii.encode('${bytes.length}:'))
          ..addAll(bytes);
      }
      return {
        'success': true,
        'operation': 'create_review_card',
        'version': 1,
        'uid': uid,
        'operationId': request['cardId'],
        'fingerprint': sha256.convert(frame).toString(),
        'outcome': outcome,
        'effectsCommitted': true,
      };
    }

    FirestoreSyncRemoteDataSource source(
      _TransactionalStudyFirestore fire,
      _FakeFirebaseAuth auth,
      Future<http.StreamedResponse> Function(http.BaseRequest) handler, {
      Duration timeout = const Duration(seconds: 15),
      bool Function()? current,
    }) => FirestoreSyncRemoteDataSource(
      fire,
      auth,
      captureRemoteSend: (_) => RemoteSendPermit(current ?? () => true),
      clientFactory: () => _RecordingHttpClient(handler),
      idTokenProvider: (_, _) async => 'synthetic-id-token',
      appCheckTokenProvider: _validAppCheckToken,
      requestTimeout: timeout,
    );
    Map<String, dynamic> request(http.BaseRequest req) {
      expect(req.url, FirestoreSyncRemoteDataSource.backendSyncUri);
      expect(req.method, 'POST');
      expect(req.headers['Authorization'], 'Bearer synthetic-id-token');
      expect(req.headers['X-Firebase-AppCheck'], 'firebase-app-check-token');
      final data =
          jsonDecode((req as http.Request).body) as Map<String, dynamic>;
      expect(data.keys.toSet(), {
        'operation',
        'version',
        'cardId',
        'subjectId',
        'question',
        'answer',
        'createdAt',
      });
      return data;
    }

    final vectors = [
      (
        local(),
        'd3ee2953c47ce71eb071d3e27447c1689359ff7c913c8666329991efce20ca99',
      ),
      (
        local(
          question: 'á:|🌊',
          answer: 'e\u0301😀',
          date: '2026-10-28T12:34:56.123Z',
        ),
        '29bcc30a91ff89dbe17d5a2669cc116120380054db85c9cbeb20db80394e1ff6',
      ),
    ];
    for (final (payload, digest) in vectors)
      for (final outcome in ['APPLIED', 'REPLAYED']) {
        test('literal Node/Dart fingerprint $digest $outcome', () async {
          final fire = _TransactionalStudyFirestore();
          var calls = 0;
          final remote = source(
            fire,
            _FakeFirebaseAuth(_FakeFirebaseUser('uid-a')),
            (req) async {
              calls++;
              final data = request(req);
              final response = ack(data, outcome: outcome);
              expect(response['fingerprint'], digest);
              return _jsonResponse(
                200,
                jsonEncode({...response, 'fingerprint': digest}),
              );
            },
          );
          final item = row(payload), before = item.payloadJson;
          expect((await remote.process('uid-a', item)).isSuccess, isTrue);
          expect(item.payloadJson, before);
          expect(calls, 1);
          expect(fire.transactionWrites, 0);
          expect(fire.data, isEmpty);
        });
      }
    final wrong = <String, dynamic>{
      'success': false,
      'operation': 'review_card',
      'version': 2,
      'uid': 'uid-b',
      'operationId': 'other-card',
      'fingerprint': '0' * 64,
      'outcome': 'UNKNOWN',
      'effectsCommitted': false,
    };
    for (final field in wrong.keys)
      for (final missing in [true, false])
        test(
          'ACK $field ${missing ? 'missing' : 'wrong'} remains pending',
          () async {
            final fire = _TransactionalStudyFirestore();
            final remote = source(
              fire,
              _FakeFirebaseAuth(_FakeFirebaseUser('uid-a')),
              (req) async {
                final data = ack(request(req));
                if (missing) {
                  data.remove(field);
                } else {
                  data[field] = wrong[field];
                }
                return _jsonResponse(200, jsonEncode(data));
              },
            );
            final result = await remote.process('uid-a', row(local()));
            expect(result.shouldRetry, isTrue);
            expect(result.code, 'REVIEW_CREATE_ACK_INVALID');
            expect(result.isSuccess, isFalse);
            expect(fire.transactionWrites, 0);
          },
        );
    for (final body in ['', 'broken', '[]', 'null', 'true', '{"success":true}'])
      test('2xx indeterminate JSON ${jsonEncode(body)} never ACKs', () async {
        final fire = _TransactionalStudyFirestore();
        final remote = source(
          fire,
          _FakeFirebaseAuth(_FakeFirebaseUser('uid-a')),
          (_) async => _jsonResponse(200, body),
        );
        final result = await remote.process('uid-a', row(local()));
        expect(result.shouldRetry, isTrue);
        expect(result.code, 'REVIEW_CREATE_ACK_INVALID');
        expect(fire.transactionWrites, 0);
      });
    for (final patch in [
      {'version': 1.0},
      {'success': 1},
      {'effectsCommitted': 1},
      {'extra': true},
    ])
      test('ACK strict types/shape $patch', () async {
        final remote = source(
          _TransactionalStudyFirestore(),
          _FakeFirebaseAuth(_FakeFirebaseUser('uid-a')),
          (req) async =>
              _jsonResponse(200, jsonEncode({...ack(request(req)), ...patch})),
        );
        expect(
          (await remote.process('uid-a', row(local()))).code,
          'REVIEW_CREATE_ACK_INVALID',
        );
      });
    for (final date in [
      '2026-10-28T12:34:56.123Z',
      '2026-10-28T12:34:56.123456Z',
      '0001-01-01T00:00:00.000Z',
      '0099-12-31T23:59:59.999999Z',
      '9999-12-31T23:59:59.999999Z',
    ])
      test('canonical UTC precision retained $date', () async {
        final remote = source(
          _TransactionalStudyFirestore(),
          _FakeFirebaseAuth(_FakeFirebaseUser('uid-a')),
          (req) async {
            final data = request(req);
            expect(data['createdAt'], date);
            return _jsonResponse(200, jsonEncode(ack(data)));
          },
        );
        expect(
          (await remote.process('uid-a', row(local(date: date)))).isSuccess,
          isTrue,
        );
      });
    for (final date in [
      '2026-10-28T12:34:56',
      '2026-10-28T12:34:56Z',
      '2026-10-28T12:34:56.123000Z',
      '2026-10-28T12:34:56.1234567Z',
      '2026-02-29T00:00:00.000Z',
      '2026-10-28T24:00:00.000Z',
      '2026-10-28T12:34:56.123+00:00',
      '0000-01-01T00:00:00.000Z',
    ])
      test('reject noncanonical v1 $date before HTTP/SDK', () async {
        final fire = _TransactionalStudyFirestore();
        var calls = 0;
        final remote = source(
          fire,
          _FakeFirebaseAuth(_FakeFirebaseUser('uid-a')),
          (_) async {
            calls++;
            return _jsonResponse(200);
          },
        );
        final result = await remote.process('uid-a', row(local(date: date)));
        expect(result.code, 'INVALID_PAYLOAD');
        expect(calls, 0);
        expect(fire.transactionWrites, 0);
      });
    for (final patch in <Map<String, dynamic>>[
      {'question': '\ud800'},
      {'answer': '\udc00'},
      {'question': ' '},
      {'cardId': 'other'},
      {'subjectId': 'x/y'},
      {'uid': 'uid-b'},
      {'claims': {}},
      {'isPremium': true},
      {'reviewQueue': 1},
    ])
      test('reject forged/invalid v1 $patch without fallback', () async {
        final fire = _TransactionalStudyFirestore();
        var calls = 0;
        final remote = source(
          fire,
          _FakeFirebaseAuth(_FakeFirebaseUser('uid-a')),
          (_) async {
            calls++;
            return _jsonResponse(200);
          },
        );
        expect(
          (await remote.process('uid-a', row({...local(), ...patch}))).code,
          'INVALID_PAYLOAD',
        );
        expect(calls, 0);
        expect(fire.transactionWrites, 0);
      });
    test('effective UTF8 payload limit is enforced before send', () async {
      var calls = 0;
      final remote = source(
        _TransactionalStudyFirestore(),
        _FakeFirebaseAuth(_FakeFirebaseUser('uid-a')),
        (_) async {
          calls++;
          return _jsonResponse(200);
        },
      );
      final result = await remote.process(
        'uid-a',
        row(local(question: '🌊' * (128 * 1024))),
      );
      expect(result.isPermanentFailure, isTrue);
      expect(result.code, 'REVIEW_CREATE_PAYLOAD_TOO_LARGE');
      expect(calls, 0);
    });
    for (final version in [null, 0, 2, '1'])
      test(
        'legacy marker $version never sends or rewrites original timestamp',
        () async {
          final fire = _TransactionalStudyFirestore();
          var calls = 0;
          final payload = {...local(date: '2026-10-28T12:34:56')};
          if (version == null) {
            payload.remove('creationProtocolVersion');
          } else {
            payload['creationProtocolVersion'] = version;
          }
          final item = row(payload), original = item.payloadJson;
          final remote = source(
            fire,
            _FakeFirebaseAuth(_FakeFirebaseUser('uid-a')),
            (_) async {
              calls++;
              return _jsonResponse(200);
            },
          );
          final result = await remote.process('uid-a', item);
          expect(result.code, 'REVIEW_CREATE_LEGACY_UNVERIFIED');
          expect(result.shouldRetry, isTrue);
          expect(item.payloadJson, original);
          expect(calls, 0);
          expect(fire.transactionWrites, 0);
        },
      );
    const statuses = {
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
    for (final entry in statuses.entries)
      test('${entry.key} is pending, sanitized and no SDK fallback', () async {
        final fire = _TransactionalStudyFirestore();
        final remote = source(
          fire,
          _FakeFirebaseAuth(_FakeFirebaseUser('uid-a')),
          (_) async => _jsonResponse(
            entry.value,
            jsonEncode({
              'code': entry.key,
              'error': 'private contents token=secret',
            }),
          ),
        );
        final result = await remote.process('uid-a', row(local()));
        expect(result.code, entry.key);
        expect(result.shouldRetry, isTrue);
        expect(result.message, isNull);
        expect(fire.transactionWrites, 0);
        expect(fire.data, isEmpty);
      });
    for (final status in [400, 403])
      test(
        'ordinary HTTP $status still terminal only for real invalid/permission error',
        () async {
          final remote = source(
            _TransactionalStudyFirestore(),
            _FakeFirebaseAuth(_FakeFirebaseUser('uid-a')),
            (_) async => _jsonResponse(
              status,
              '{"code":"INVALID_PAYLOAD","error":"Invalid"}',
            ),
          );
          final result = await remote.process('uid-a', row(local()));
          expect(result.isPermanentFailure, isTrue);
          expect(result.isSuccess, isFalse);
        },
      );
    test(
      'response lost after synthetic commit then replay: same payload and ID, no local double count',
      () async {
        final fire = _TransactionalStudyFirestore();
        final bodies = <String>[];
        var applied = 0;
        final remote = source(
          fire,
          _FakeFirebaseAuth(_FakeFirebaseUser('uid-a')),
          (req) async {
            final data = request(req);
            bodies.add((req as http.Request).body);
            if (applied == 0) {
              applied++;
              throw TimeoutException('synthetic lost response');
            }
            return _jsonResponse(
              200,
              jsonEncode(ack(data, outcome: 'REPLAYED')),
            );
          },
        );
        final item = row(local()), original = item.payloadJson;
        final first = await remote.process('uid-a', item);
        expect(first.shouldRetry, isTrue);
        expect(first.code, 'SYNC_TIMEOUT');
        expect((await remote.process('uid-a', item)).isSuccess, isTrue);
        expect(bodies[0], bodies[1]);
        expect(item.payloadJson, original);
        expect(applied, 1);
        expect(fire.transactionWrites, 0);
      },
    );
    test('late ACK after generation invalidated is never success', () async {
      var current = true;
      final remote = source(
        _TransactionalStudyFirestore(),
        _FakeFirebaseAuth(_FakeFirebaseUser('uid-a')),
        (req) async {
          final data = request(req);
          current = false;
          return _jsonResponse(200, jsonEncode(ack(data)));
        },
        current: () => current,
      );
      final result = await remote.processForSession(
        'uid-a',
        row(local()),
        canSend: () => current,
      );
      expect(result.code, 'SESSION_STOPPED');
      expect(result.shouldRetry, isTrue);
    });
    test(
      'late A ACK after A to B switch; B independently creates same ID',
      () async {
        final auth = _FakeFirebaseAuth(_FakeFirebaseUser('uid-a'));
        var uid = 'uid-a';
        final remote = source(_TransactionalStudyFirestore(), auth, (
          req,
        ) async {
          final data = request(req), response = ack(data, uid: uid);
          if (uid == 'uid-a') {
            auth.user = _FakeFirebaseUser('uid-b');
          }
          return _jsonResponse(200, jsonEncode(response));
        });
        expect(
          (await remote.process('uid-a', row(local()))).code,
          'SESSION_STOPPED',
        );
        uid = 'uid-b';
        expect(
          (await remote.process('uid-b', row(local(), uid: 'uid-b'))).isSuccess,
          isTrue,
        );
        expect(
          (await remote.process('uid-b', row(local(), uid: 'uid-a'))).code,
          'SESSION_STOPPED',
        );
      },
    );
    for (final badJson in ['broken', '[]', 'null'])
      test(
        'unknown protocol JSON $badJson remains recoverable without sends',
        () async {
          var calls = 0;
          final remote = source(
            _TransactionalStudyFirestore(),
            _FakeFirebaseAuth(_FakeFirebaseUser('uid-a')),
            (_) async {
              calls++;
              return _jsonResponse(200);
            },
          );
          final item = row(local()).copyWith(payloadJson: badJson),
              original = item.payloadJson;
          final result = await remote.process('uid-a', item);
          expect(result.shouldRetry, isTrue);
          expect(result.code, 'REVIEW_CREATE_LEGACY_UNVERIFIED');
          expect(item.payloadJson, original);
          expect(calls, 0);
        },
      );
    test(
      'actual request timeout never confirms a remotely unknown commit',
      () async {
        final pending = Completer<http.StreamedResponse>();
        final fire = _TransactionalStudyFirestore();
        final remote = source(
          fire,
          _FakeFirebaseAuth(_FakeFirebaseUser('uid-a')),
          (_) => pending.future,
          timeout: const Duration(milliseconds: 5),
        );
        final item = row(local()), before = item.payloadJson;
        final result = await remote.process('uid-a', item);
        expect(result.shouldRetry, isTrue);
        expect(result.code, 'SYNC_TIMEOUT');
        pending.complete(_jsonResponse(200, '{}'));
        expect(item.payloadJson, before);
        expect(fire.transactionWrites, 0);
      },
    );
    test(
      '401 refresh retains exact serialized payload and validates final ACK',
      () async {
        final auth = _FakeFirebaseAuth(_FakeFirebaseUser('uid-a')),
            bodies = <String>[],
            refresh = <bool>[];
        final remote = FirestoreSyncRemoteDataSource(
          _TransactionalStudyFirestore(),
          auth,
          captureRemoteSend: (_) => RemoteSendPermit(() => true),
          appCheckTokenProvider: _validAppCheckToken,
          idTokenProvider: (_, force) async {
            refresh.add(force);
            return force ? 'new-token' : 'old-token';
          },
          clientFactory: () => _RecordingHttpClient((req) async {
            final data =
                jsonDecode((req as http.Request).body) as Map<String, dynamic>;
            bodies.add(req.body);
            if (bodies.length == 1)
              return _jsonResponse(401, '{"code":"INVALID_TOKEN"}');
            expect(req.headers['Authorization'], 'Bearer new-token');
            return _jsonResponse(200, jsonEncode(ack(data)));
          }),
        );
        expect((await remote.process('uid-a', row(local()))).isSuccess, isTrue);
        expect(refresh, [false, true]);
        expect(bodies, hasLength(2));
        expect(bodies[0], bodies[1]);
      },
    );
    test(
      'generation invalidation in A-B-A rejects ACK even when UID returns to A',
      () async {
        var current = true;
        final auth = _FakeFirebaseAuth(_FakeFirebaseUser('uid-a'));
        final remote = source(_TransactionalStudyFirestore(), auth, (
          req,
        ) async {
          final response = ack(request(req));
          auth.user = _FakeFirebaseUser('uid-b');
          current = false;
          auth.user = _FakeFirebaseUser('uid-a');
          return _jsonResponse(200, jsonEncode(response));
        }, current: () => current);
        expect(
          (await remote.processForSession(
            'uid-a',
            row(local()),
            canSend: () => current,
          )).code,
          'SESSION_STOPPED',
        );
      },
    );
  });
  group('S2 deterministic StudyInfo hold before IO', () {
    for (final operation in ['create', 'update', ' CrEaTe ', '\tUPDATE\n']) {
      for (final payload in [
        '{ "reviewQueue": 3 }',
        'malformed-private-marker',
        '{"progress":0.2,"extra":true}',
      ]) {
        test(
          'holds $operation independently of payload shape ${payload.length}',
          () async {
            final item =
                createStudyItem(
                  collection: '\tstudy_info\n',
                  docId: '\u00a0main\ufeff',
                  operationType: operation,
                  payload: {},
                ).copyWith(
                  payloadJson: '  $payload  ',
                  attemptCount: 8,
                  lastAttemptAt: const Value(123),
                  lastErrorCode: const Value('OLD_PRIVATE_MARKER'),
                );
            final before = item.toJson();
            final source = FirestoreSyncRemoteDataSource(
              _RecordingFirestore(usersCollection),
              _FakeFirebaseAuth(),
              captureRemoteSend: (_) =>
                  throw StateError('permit must not be captured'),
              clientFactory: () => throw StateError('HTTP must not be created'),
              idTokenProvider: (_, _) =>
                  throw StateError('token must not be read'),
              appCheckTokenProvider: () =>
                  throw StateError('App Check must not be read'),
            );
            final result = await source.processForSession(
              'synthetic-private-owner',
              item,
              canSend: () => throw StateError('not a send'),
            );
            expect(result.code, 'STUDY_INFO_LEGACY_HOLD');
            expect(result.shouldRetry, isTrue);
            expect(result.isSuccess, isFalse);
            expect(result.isPermanentFailure, isFalse);
            expect(result.message, isNull);
            expect(item.toJson(), before);
            expect(usersCollection.lastUserId, isNull);
            expect(healthDoc.setCalls, 0);
            expect(healthDoc.updateCalls, 0);
          },
        );
      }
    }
    for (final tuple in [
      ('study_info', 'other', 'update'),
      ('study_info', 'MAIN', 'create'),
      ('Study_info', 'main', 'create'),
      ('study_info', 'main', 'delete'),
      ('study_activity', 'main', 'create'),
      ('study_progress_reset', 'main', 'create'),
      ('review_queue', 'main', 'create'),
      ('review_queue', 'main', 'update'),
      ('subjects', 'main', 'update'),
      ('health_info', 'main', 'update'),
      ('tasks', 'main', 'update'),
      ('goals', 'main', 'update'),
    ]) {
      test('classification excludes ${tuple.$1}/${tuple.$2}/${tuple.$3}', () {
        expect(
          LegacyStudyInfoOperation.isBlocked(
            createStudyItem(
              collection: tuple.$1,
              docId: tuple.$2,
              operationType: tuple.$3,
              payload: {},
            ),
          ),
          isFalse,
        );
      });
    }
  });
  group('F01 scoped domain HOLD transport', () {
    SyncQueueTableData row(bool deleting) => deleting
        ? createStudyItem(
            collection: 'subjects',
            docId: 'subject-1',
            operationType: 'delete',
            payload: {},
          )
        : reviewUpdateItem('card-1');
    const reviewCode = 'STUDY_REVIEW_STATE_INVALID';
    const deleteCode = 'STUDY_REVIEW_QUEUE_STATE_INVALID';
    for (final deleting in [false, true]) {
      final code = deleting ? deleteCode : reviewCode;
      if (deleting) {
        test(
          'subject delete preserves original 409 code without ACK',
          () async {
            final client = _RecordingHttpClient(
              (_) async => _jsonResponse(
                409,
                jsonEncode({'code': code, 'error': 'private-server-detail'}),
              ),
            );
            final source = serverDataSource(
              auth: _FakeFirebaseAuth(_FakeFirebaseUser('user-123')),
              clientFactory: () => client,
              idTokenProvider: (_, _) async => 'token',
              appCheckTokenProvider: _validAppCheckToken,
            );
            final result = await source.process('user-123', row(deleting));
            expect(result.status, SyncOperationStatus.retryableError);
            expect(result.code, code);
            expect(result.isSuccess, isFalse);
            expect(result.message, isNull);
            expect(client.wasClosed, isTrue);
          },
        );
      }
      test('persisted $code blocks direct calls before any IO', () async {
        var io = 0;
        final item = row(
          deleting,
        ).copyWith(lastErrorCode: Value(code), attemptCount: 3);
        final source = serverDataSource(
          auth: _FakeFirebaseAuth(_FakeFirebaseUser('user-123')),
          clientFactory: () {
            io++;
            throw StateError('HTTP forbidden');
          },
          idTokenProvider: (_, _) async {
            io++;
            throw StateError('token forbidden');
          },
          appCheckTokenProvider: () async {
            io++;
            throw StateError('App Check forbidden');
          },
        );
        for (var n = 0; n < 3; n++) {
          final result = await source.process('user-123', item);
          expect(result.code, code);
          expect(result.isSuccess, isFalse);
          expect(result.isPermanentFailure, isFalse);
        }
        expect(io, 0);
        expect(item.attemptCount, 3);
      });
      for (final scenario in [
        (409, deleting ? reviewCode : deleteCode, 'INVALID_PAYLOAD'),
        (409, 'OTHER_CONFLICT', 'INVALID_PAYLOAD'),
        (403, code, 'PERMISSION_DENIED'),
      ]) {
        test(
          '$deleting HTTP ${scenario.$1}/${scenario.$2} keeps earlier contract',
          () async {
            final client = _RecordingHttpClient(
              (_) async => _jsonResponse(
                scenario.$1,
                jsonEncode({'code': scenario.$2, 'error': 'sanitized'}),
              ),
            );
            final source = serverDataSource(
              auth: _FakeFirebaseAuth(_FakeFirebaseUser('user-123')),
              clientFactory: () => client,
              idTokenProvider: (_, _) async => 'token',
              appCheckTokenProvider: _validAppCheckToken,
            );
            final result = await source.process('user-123', row(deleting));
            expect(result.isPermanentFailure, isTrue);
            expect(result.code, scenario.$3);
            expect(result.isSuccess, isFalse);
          },
        );
      }
    }
  });
}
