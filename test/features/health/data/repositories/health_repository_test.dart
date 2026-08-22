// ignore_for_file: subtype_of_sealed_class, must_be_immutable

import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:drift/native.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/services/notification_service.dart';
import 'package:life_os/core/services/sync_manager.dart';
import 'package:life_os/core/services/sync_operation_result.dart';
import 'package:life_os/core/services/sync_queue_store.dart';
import 'package:life_os/core/services/sync_remote_data_source.dart';
import 'package:life_os/features/health/data/repositories/health_repository.dart';

class FakeFirebaseUser extends Fake implements User {
  @override
  String get uid => 'user-123';
}

class FakeFirebaseAuth extends Fake implements FirebaseAuth {
  final User user;

  FakeFirebaseAuth(this.user);

  @override
  User? get currentUser => user;
}

class _RecordingQueryDocumentSnapshot extends Fake
    implements QueryDocumentSnapshot<Map<String, dynamic>> {
  final String docIdValue;
  final Map<String, dynamic> dataValue;

  _RecordingQueryDocumentSnapshot(this.docIdValue, this.dataValue);

  @override
  String get id => docIdValue;

  @override
  Map<String, dynamic> data() => Map<String, dynamic>.from(dataValue);
}

class _RecordingQuerySnapshot extends Fake
    implements QuerySnapshot<Map<String, dynamic>> {
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> docsValue;

  _RecordingQuerySnapshot(this.docsValue);

  @override
  List<QueryDocumentSnapshot<Map<String, dynamic>>> get docs => docsValue;
}

class _RecordingCollectionReference extends Fake
    implements CollectionReference<Map<String, dynamic>> {
  final DocumentReference<Map<String, dynamic>>? documentReference;
  final QuerySnapshot<Map<String, dynamic>>? snapshot;
  final String name;

  _RecordingCollectionReference({
    required this.name,
    this.documentReference,
    this.snapshot,
  });

  @override
  Future<QuerySnapshot<Map<String, dynamic>>> get([Object? options]) async {
    if (snapshot == null) {
      throw UnsupportedError('Unexpected get on collection $name');
    }

    return snapshot!;
  }

  @override
  DocumentReference<Map<String, dynamic>> doc([String? path]) {
    if (documentReference == null) {
      throw UnsupportedError('Unexpected doc on collection $name');
    }

    return documentReference!;
  }
}

class _RecordingUserDocumentReference extends Fake
    implements DocumentReference<Map<String, dynamic>> {
  final Map<String, _RecordingCollectionReference> collections;

  _RecordingUserDocumentReference(this.collections);

  @override
  CollectionReference<Map<String, dynamic>> collection(String path) {
    final collection = collections[path];

    if (collection == null) {
      throw UnsupportedError('Unexpected collection: $path');
    }

    return collection;
  }
}

class _RecordingFirestore extends Fake implements FirebaseFirestore {
  final CollectionReference<Map<String, dynamic>> usersCollection;

  _RecordingFirestore(this.usersCollection);

  @override
  CollectionReference<Map<String, dynamic>> collection(String path) {
    if (path != 'users') {
      throw UnsupportedError('Unexpected collection: $path');
    }

    return usersCollection;
  }
}

class _NoopQueueStore implements SyncQueueStore {
  @override
  Future<List<SyncQueueTableData>> getPendingSyncItems(String ownerUid) async =>
      const [];

  @override
  Future<int> markSyncItemAsSucceeded(int id, String ownerUid) async => 0;

  @override
  Future<int> markSyncItemRejected(
    int id,
    String ownerUid,
    String errorCode,
  ) async => 0;

  @override
  Future<int> markSyncItemRetryableFailure(
    int id,
    String ownerUid,
    String errorCode,
  ) async => 0;
}

class _NoopRemoteDataSource implements SyncRemoteDataSource {
  @override
  Future<SyncOperationResult> process(
    String uid,
    SyncQueueTableData item,
  ) async {
    return const SyncOperationResult.success();
  }
}

class FakeSyncManager extends SyncManager {
  int calls = 0;

  FakeSyncManager()
    : super(
        queueStore: _NoopQueueStore(),
        remoteDataSource: _NoopRemoteDataSource(),
        currentUserId: () => 'user-123',
      );

  @override
  Future<bool> processPendingItems() async {
    calls += 1;
    return true;
  }
}

class _MutableClock {
  DateTime value;

  _MutableClock(this.value);

  DateTime now() => value;
}

void main() {
  late AppDatabase db;
  late FakeFirebaseAuth auth;
  late FakeFirebaseUser user;
  late _RecordingFirestore firestore;
  late FakeSyncManager syncManager;
  late HealthRepository repository;
  late _MutableClock clock;

  void configureRepositoryWithHealthDocuments(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> healthDocuments,
  ) {
    final medications = _RecordingCollectionReference(
      name: 'medications',
      snapshot: _RecordingQuerySnapshot(
        const <QueryDocumentSnapshot<Map<String, dynamic>>>[],
      ),
    );
    final healthInfo = _RecordingCollectionReference(
      name: 'health_info',
      snapshot: _RecordingQuerySnapshot(healthDocuments),
    );
    final userDoc = _RecordingUserDocumentReference({
      'medications': medications,
      'health_info': healthInfo,
    });
    final usersCollection = _RecordingCollectionReference(
      name: 'users',
      documentReference: userDoc,
    );

    firestore = _RecordingFirestore(usersCollection);
    repository = HealthRepository(
      NotificationService(),
      firestore,
      auth,
      db,
      syncManager,
      now: clock.now,
    );
  }

  setUp(() {
    db = AppDatabase(executor: NativeDatabase.memory());
    user = FakeFirebaseUser();
    auth = FakeFirebaseAuth(user);
    syncManager = FakeSyncManager();
    clock = _MutableClock(DateTime.utc(2026, 8, 21, 10));

    final emptyMedications = _RecordingCollectionReference(
      name: 'medications',
      snapshot: _RecordingQuerySnapshot(
        const <QueryDocumentSnapshot<Map<String, dynamic>>>[],
      ),
    );
    final emptyHealthInfo = _RecordingCollectionReference(
      name: 'health_info',
      snapshot: _RecordingQuerySnapshot(
        const <QueryDocumentSnapshot<Map<String, dynamic>>>[],
      ),
    );
    final emptyUserDoc = _RecordingUserDocumentReference({
      'medications': emptyMedications,
      'health_info': emptyHealthInfo,
    });
    final emptyUsersCollection = _RecordingCollectionReference(
      name: 'users',
      documentReference: emptyUserDoc,
    );
    firestore = _RecordingFirestore(emptyUsersCollection);

    repository = HealthRepository(
      NotificationService(),
      firestore,
      auth,
      db,
      syncManager,
      now: clock.now,
    );
  });

  tearDown(() async {
    await db.closeDatabase();
  });

  test('updateMood salva localmente e enfileira o payload correto', () async {
    await repository.updateMood('Radiante');

    final healthRow = await db.select(db.healthEntries).getSingle();
    final pending = (await db.getPendingSyncItems(
      'user-123',
    )).cast<SyncQueueTableData>();
    final payload = jsonDecode(pending.single.payloadJson) as Map;

    expect(healthRow.docId, '2026-08-21');
    expect(healthRow.mood, 'Radiante');
    expect(pending.single.collection, 'health_info');
    expect(pending.single.operationType, 'update');
    expect(payload, {'mood': 'Radiante', 'date': '2026-08-21T10:00:00.000Z'});
    expect(syncManager.calls, 1);
  });

  test('addWater salva localmente e enfileira o payload correto', () async {
    await repository.addWater(500);

    final healthRow = await db.select(db.healthEntries).getSingle();
    final pending = (await db.getPendingSyncItems(
      'user-123',
    )).cast<SyncQueueTableData>();
    final payload = jsonDecode(pending.single.payloadJson) as Map;

    expect(healthRow.waterIntakeMl, 750);
    expect(payload, {'waterIntakeMl': 750, 'date': '2026-08-21T10:00:00.000Z'});
    expect(syncManager.calls, 1);
  });

  test('ciclo menstrual salva localmente e entra na SyncQueue', () async {
    await repository.updateCycleSettings({
      'isEnabled': true,
      'lastPeriodStart': '2026-08-01T00:00:00.000',
      'cycleLengthDays': 30,
      'periodLengthDays': 6,
    });

    final healthRow = await db.select(db.healthEntries).getSingle();
    final pending = (await db.getPendingSyncItems(
      'user-123',
    )).cast<SyncQueueTableData>();
    final localCycle = jsonDecode(healthRow.menstrualCycleJson!) as Map;
    final payload = jsonDecode(pending.single.payloadJson) as Map;

    expect(localCycle['cycleLengthDays'], 30);
    expect(payload['menstrualCycle'], localCycle);
    expect(payload['date'], '2026-08-21T10:00:00.000Z');
    expect(syncManager.calls, 1);
  });

  test('Firebase reidrata todos os campos do dia em banco vazio', () async {
    final cycle = <String, dynamic>{
      'isEnabled': true,
      'lastPeriodStart': '2026-08-01T00:00:00.000',
      'cycleLengthDays': 28,
      'periodLengthDays': 5,
    };
    configureRepositoryWithHealthDocuments([
      _RecordingQueryDocumentSnapshot('2026-08-21', {
        'mood': 'Radiante',
        'waterIntakeMl': 1500,
        'hasTakenPillToday': true,
        'menstrualCycle': cycle,
        'date': Timestamp.fromDate(clock.value),
      }),
    ]);

    await repository.syncHealthFromFirebase();

    final restored = await repository.getHealthStream().first;

    expect(restored.mood, 'Radiante');
    expect(restored.waterIntakeMl, 1500);
    expect(restored.hasTakenPillToday, isTrue);
    expect(restored.menstrualCycle?['cycleLengthDays'], 28);
  });

  test(
    'resposta parcial preserva ausentes e aplica zero e false explícitos',
    () async {
      await repository.updateMood('Radiante');
      await repository.addWater(750);
      await repository.updatePillStatus(true);

      configureRepositoryWithHealthDocuments([
        _RecordingQueryDocumentSnapshot('2026-08-21', {
          'waterIntakeMl': 0,
          'hasTakenPillToday': false,
          'date': Timestamp.fromDate(clock.value),
        }),
      ]);

      await repository.syncHealthFromFirebase();

      final restored = await db.select(db.healthEntries).getSingle();

      expect(restored.mood, 'Radiante');
      expect(restored.waterIntakeMl, 0);
      expect(restored.hasTakenPillToday, isFalse);
    },
  );

  test('valores inválidos do Firebase são sanitizados', () async {
    configureRepositoryWithHealthDocuments([
      _RecordingQueryDocumentSnapshot('2026-08-21', {
        'mood': '   ',
        'waterIntakeMl': -50,
        'hasTakenPillToday': 'sim',
        'menstrualCycle': {
          'isEnabled': 'sim',
          'lastPeriodStart': 'inválida',
          'cycleLengthDays': 0,
          'periodLengthDays': 999,
        },
        'date': 'inválida',
      }),
    ]);

    await repository.syncHealthFromFirebase();

    final restored = await repository.getHealthStream().first;

    expect(restored.mood, '—');
    expect(restored.waterIntakeMl, 0);
    expect(restored.hasTakenPillToday, isFalse);
    expect(restored.menstrualCycle?['isEnabled'], isFalse);
    expect(restored.menstrualCycle?['cycleLengthDays'], 1);
    expect(restored.menstrualCycle?['periodLengthDays'], 1);
    expect(restored.date, DateTime(2026, 8, 21));
  });

  test(
    'ciclo persiste no dia seguinte sem carregar métricas diárias antigas',
    () async {
      await repository.updateMood('Radiante');
      await repository.addWater(750);
      await repository.updatePillStatus(true);
      await repository.updateCycleSettings({
        'isEnabled': true,
        'lastPeriodStart': '2026-08-01T00:00:00.000',
        'cycleLengthDays': 30,
        'periodLengthDays': 6,
      });

      clock.value = DateTime.utc(2026, 8, 22, 9);

      final nextDay = await repository.getHealthStream().first;

      expect(nextDay.mood, '—');
      expect(nextDay.waterIntakeMl, 0);
      expect(nextDay.hasTakenPillToday, isFalse);
      expect(nextDay.menstrualCycle?['cycleLengthDays'], 30);
      expect(nextDay.menstrualCycle?['periodLengthDays'], 6);
    },
  );

  test(
    'reconstrução usa o ciclo válido mais recente sem copiar humor e água',
    () async {
      clock.value = DateTime.utc(2026, 8, 23, 9);
      configureRepositoryWithHealthDocuments([
        _RecordingQueryDocumentSnapshot('2026-08-20', {
          'mood': 'Tranquilo',
          'waterIntakeMl': 500,
          'menstrualCycle': {
            'isEnabled': true,
            'lastPeriodStart': '2026-07-01T00:00:00.000',
            'cycleLengthDays': 28,
            'periodLengthDays': 5,
          },
          'date': Timestamp.fromDate(DateTime.utc(2026, 8, 20, 9)),
        }),
        _RecordingQueryDocumentSnapshot('2026-08-22', {
          'mood': 'Radiante',
          'waterIntakeMl': 1500,
          'menstrualCycle': {
            'isEnabled': true,
            'lastPeriodStart': '2026-08-01T00:00:00.000',
            'cycleLengthDays': 31,
            'periodLengthDays': 7,
          },
          'date': Timestamp.fromDate(DateTime.utc(2026, 8, 22, 9)),
        }),
      ]);

      await repository.syncHealthFromFirebase();

      final rebuilt = await repository.getHealthStream().first;

      expect(rebuilt.mood, '—');
      expect(rebuilt.waterIntakeMl, 0);
      expect(rebuilt.hasTakenPillToday, isFalse);
      expect(rebuilt.menstrualCycle?['cycleLengthDays'], 31);
      expect(rebuilt.menstrualCycle?['periodLengthDays'], 7);
    },
  );
}
