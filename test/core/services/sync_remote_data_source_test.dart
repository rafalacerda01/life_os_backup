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

void main() {
  late _RecordingHealthDocumentReference healthDoc;
  late FirestoreSyncRemoteDataSource remote;

  FirestoreSyncRemoteDataSource serverDataSource({
    required FirebaseAuth auth,
    required http.Client Function() clientFactory,
    required Future<String?> Function(User user, bool forceRefresh)
    idTokenProvider,
    required SyncAppCheckTokenProvider appCheckTokenProvider,
  }) {
    return FirestoreSyncRemoteDataSource(
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
      appCheckTokenProvider: _validAppCheckToken,
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

  test('Habit update normal não solicita atividade competitiva', () async {
    late Map<String, dynamic> payload;
    final client = _RecordingHttpClient((request) async {
      payload = jsonDecode(await request.finalize().bytesToString());
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
}
