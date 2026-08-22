// ignore_for_file: subtype_of_sealed_class, must_be_immutable

import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/services/sync_remote_data_source.dart';

class _RecordingHealthDocumentReference extends Fake
    implements DocumentReference<Map<String, dynamic>> {
  final Map<String, dynamic> storedData = <String, dynamic>{};
  Map<String, dynamic>? lastData;
  SetOptions? lastOptions;
  FirebaseException? setError;

  @override
  Future<void> set(Map<String, dynamic> data, [SetOptions? options]) async {
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
  }
}

class _RecordingHealthCollectionReference extends Fake
    implements CollectionReference<Map<String, dynamic>> {
  final _RecordingHealthDocumentReference documentReference;

  _RecordingHealthCollectionReference(this.documentReference);

  @override
  DocumentReference<Map<String, dynamic>> doc([String? path]) {
    return documentReference;
  }
}

class _RecordingUserDocumentReference extends Fake
    implements DocumentReference<Map<String, dynamic>> {
  final _RecordingHealthCollectionReference healthCollection;

  _RecordingUserDocumentReference(this.healthCollection);

  @override
  CollectionReference<Map<String, dynamic>> collection(String path) {
    if (path != 'health_info') {
      throw UnsupportedError('Unexpected collection: $path');
    }

    return healthCollection;
  }
}

class _RecordingUsersCollectionReference extends Fake
    implements CollectionReference<Map<String, dynamic>> {
  final _RecordingUserDocumentReference userDocumentReference;

  _RecordingUsersCollectionReference(this.userDocumentReference);

  @override
  DocumentReference<Map<String, dynamic>> doc([String? path]) {
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

void main() {
  late _RecordingHealthDocumentReference healthDoc;
  late FirestoreSyncRemoteDataSource remote;

  setUp(() {
    healthDoc = _RecordingHealthDocumentReference();
    final healthCollection = _RecordingHealthCollectionReference(healthDoc);
    final userDoc = _RecordingUserDocumentReference(healthCollection);
    final usersCollection = _RecordingUsersCollectionReference(userDoc);
    final firestore = _RecordingFirestore(usersCollection);

    remote = FirestoreSyncRemoteDataSource(firestore, _FakeFirebaseAuth());
  });

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

  test('health_info create também usa set com merge:true', () async {
    final item = createHealthItem(
      operationType: 'create',
      payload: {'waterIntakeMl': 250, 'date': '2026-08-21T10:00:00.000Z'},
    );

    final result = await remote.process('user-123', item);

    expect(result.isSuccess, isTrue);
    expect(healthDoc.lastData?['waterIntakeMl'], 250);
    expect(healthDoc.lastData?['date'], isA<Timestamp>());
    expect(healthDoc.lastOptions?.merge, isTrue);
  });

  test('humor seguido de água preserva ambos os campos', () async {
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
    expect(healthDoc.storedData['waterIntakeMl'], 750);
  });

  test('água seguida de humor preserva ambos os campos', () async {
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

    expect(healthDoc.storedData['waterIntakeMl'], 750);
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
      _RecordingFirestore(
        _RecordingUsersCollectionReference(
          _RecordingUserDocumentReference(
            _RecordingHealthCollectionReference(healthDoc),
          ),
        ),
      ),
      auth,
      clientFactory: () => client,
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

  test('item de A com sessão B não inicia request server-side', () async {
    var clientFactoryCalls = 0;
    var tokenProviderCalls = 0;
    final dataSource = FirestoreSyncRemoteDataSource(
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
      idTokenProvider: (user, forceRefresh) async {
        tokenProviderCalls += 1;
        return 'token-b';
      },
    );

    final result = await dataSource.process('user-123', createTaskItem());

    expect(result.shouldRetry, isTrue);
    expect(result.code, 'AUTHENTICATION_REQUIRED');
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
      _RecordingFirestore(
        _RecordingUsersCollectionReference(
          _RecordingUserDocumentReference(
            _RecordingHealthCollectionReference(healthDoc),
          ),
        ),
      ),
      auth,
      clientFactory: () => client,
      idTokenProvider: (user, forceRefresh) async {
        tokenUsers.add(user.uid);
        forceRefreshCalls.add(forceRefresh);
        return user.uid == 'user-123' ? 'token-a' : 'token-b';
      },
    );

    final result = await dataSource.process('user-123', createTaskItem());

    expect(result.shouldRetry, isTrue);
    expect(result.code, 'AUTHENTICATION_REQUIRED');
    expect(requestCount, 1);
    expect(tokenUsers, ['user-123']);
    expect(forceRefreshCalls, [false]);
    expect(authorizations, ['Bearer token-a']);
    expect(client.wasClosed, isTrue);
  });

  test('HTTP 401 renova token e repete a requisição somente uma vez', () async {
    var requestCount = 0;
    final forceRefreshCalls = <bool>[];
    final authorizations = <String?>[];
    final client = _RecordingHttpClient((request) async {
      requestCount += 1;
      authorizations.add(request.headers['authorization']);
      return _jsonResponse(requestCount == 1 ? 401 : 200);
    });
    final dataSource = FirestoreSyncRemoteDataSource(
      _RecordingFirestore(
        _RecordingUsersCollectionReference(
          _RecordingUserDocumentReference(
            _RecordingHealthCollectionReference(healthDoc),
          ),
        ),
      ),
      _FakeFirebaseAuth(_FakeFirebaseUser('user-123')),
      clientFactory: () => client,
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
      _RecordingFirestore(
        _RecordingUsersCollectionReference(
          _RecordingUserDocumentReference(
            _RecordingHealthCollectionReference(healthDoc),
          ),
        ),
      ),
      _FakeFirebaseAuth(_FakeFirebaseUser('user-123')),
      clientFactory: () => client,
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
      _RecordingFirestore(
        _RecordingUsersCollectionReference(
          _RecordingUserDocumentReference(
            _RecordingHealthCollectionReference(healthDoc),
          ),
        ),
      ),
      _FakeFirebaseAuth(_FakeFirebaseUser('user-123')),
      clientFactory: () => client,
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
}
