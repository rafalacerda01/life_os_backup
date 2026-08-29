// ignore_for_file: subtype_of_sealed_class, must_be_immutable

import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:drift/native.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/services/notification_preferences.dart';
import 'package:life_os/core/services/notification_service.dart';
import 'package:life_os/core/services/sync_manager.dart';
import 'package:life_os/core/services/sync_operation_result.dart';
import 'package:life_os/core/services/sync_queue_store.dart';
import 'package:life_os/core/services/sync_remote_data_source.dart';
import 'package:life_os/features/health/data/models/health_model.dart';
import 'package:life_os/features/health/data/repositories/health_repository.dart';
import 'package:life_os/features/health/services/medication_reminder_lifecycle.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeFirebaseUser extends Fake implements User {
  FakeFirebaseUser([this.userId = 'user-123']);

  final String userId;

  @override
  String get uid => userId;
}

class FakeFirebaseAuth extends Fake implements FirebaseAuth {
  User? user;

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

class _RecordingNotificationService extends NotificationService {
  bool notificationPermissionGranted = true;
  bool exactPermissionGranted = true;
  bool scheduleResult = true;
  int notificationPermissionRequests = 0;
  int platformPermissionRequests = 0;
  int exactPermissionRequests = 0;
  int scheduleCalls = 0;
  final List<int> cancelledIds = [];
  String? lastPermissionPreferenceKey;

  @override
  Future<bool> requestPermissions({String? preferenceKey}) async {
    notificationPermissionRequests += 1;
    lastPermissionPreferenceKey = preferenceKey;

    final preferences = await SharedPreferences.getInstance();
    final allEnabled =
        preferences.getBool(NotificationPreferenceKeys.allNotifications) ??
        true;
    final categoryEnabled = preferenceKey == null
        ? true
        : preferences.getBool(preferenceKey) ?? true;
    if (!allEnabled || !categoryEnabled) return false;

    platformPermissionRequests += 1;
    return notificationPermissionGranted;
  }

  @override
  Future<bool> requestExactAlarmPermission() async {
    exactPermissionRequests += 1;
    return exactPermissionGranted;
  }

  @override
  Future<bool> scheduleMedicationNotification({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledDate,
    String? preferenceKey,
    bool repeatDaily = false,
  }) async {
    scheduleCalls += 1;
    return scheduleResult;
  }

  @override
  Future<void> cancelNotification(int id) async {
    cancelledIds.add(id);
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
  late _RecordingNotificationService notificationService;
  late HealthRepository repository;
  late _MutableClock clock;

  void configureRepositoryWithHealthDocuments(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> healthDocuments, {
    List<QueryDocumentSnapshot<Map<String, dynamic>>> medicationDocuments =
        const [],
  }) {
    final medications = _RecordingCollectionReference(
      name: 'medications',
      snapshot: _RecordingQuerySnapshot(medicationDocuments),
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
      notificationService,
      firestore,
      auth,
      db,
      syncManager,
      now: clock.now,
    );
  }

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    db = AppDatabase(executor: NativeDatabase.memory());
    user = FakeFirebaseUser();
    auth = FakeFirebaseAuth(user);
    syncManager = FakeSyncManager();
    notificationService = _RecordingNotificationService();
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
      notificationService,
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

  HealthRepository repositoryWithCheckpoint(Future<void> Function() callback) {
    return HealthRepository(
      notificationService,
      firestore,
      auth,
      db,
      syncManager,
      now: clock.now,
      beforeCycleSyncEnqueue: callback,
    );
  }

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

  group('updatePillStatus expectedUid', () {
    test('UID correto altera false para true e cria uma SyncQueue', () async {
      final result = await repository.updatePillStatus(
        true,
        expectedUid: 'user-123',
      );

      final healthRow = await db.select(db.healthEntries).getSingle();
      final pending = await db.getPendingSyncItems('user-123');
      final payload = jsonDecode(pending.single.payloadJson) as Map;

      expect(result, isTrue);
      expect(healthRow.hasTakenPillToday, isTrue);
      expect(pending, hasLength(1));
      expect(payload, <String, dynamic>{
        'hasTakenPillToday': true,
        'date': '2026-08-21T10:00:00.000Z',
      });
      expect(syncManager.calls, 1);
    });

    test('UID diferente falha fechado sem Drift ou SyncQueue', () async {
      final result = await repository.updatePillStatus(
        true,
        expectedUid: 'user-b',
      );

      expect(result, isFalse);
      expect(await db.select(db.healthEntries).get(), isEmpty);
      expect(await db.getPendingSyncItems('user-123'), isEmpty);
      expect(await db.getPendingSyncItems('user-b'), isEmpty);
      expect(syncManager.calls, 0);
    });

    test('Firebase user null falha fechado sem escrita', () async {
      auth.user = null;

      final result = await repository.updatePillStatus(
        true,
        expectedUid: 'user-123',
      );

      expect(result, isFalse);
      expect(await db.select(db.healthEntries).get(), isEmpty);
      expect(await db.getPendingSyncItems('user-123'), isEmpty);
    });

    test('estado já true é no-op sem timestamp ou queue redundante', () async {
      expect(
        await repository.updatePillStatus(true, expectedUid: 'user-123'),
        isTrue,
      );
      final original = await db.select(db.healthEntries).getSingle();
      clock.value = DateTime.utc(2026, 8, 21, 18);

      expect(
        await repository.updatePillStatus(true, expectedUid: 'user-123'),
        isTrue,
      );

      final afterRetry = await db.select(db.healthEntries).getSingle();
      expect(afterRetry.date, original.date);
      expect(await db.getPendingSyncItems('user-123'), hasLength(1));
      expect(syncManager.calls, 1);
    });

    test(
      'duas chamadas concorrentes geram uma única mudança e queue',
      () async {
        final results = await Future.wait<bool>(<Future<bool>>[
          repository.updatePillStatus(true, expectedUid: 'user-123'),
          repository.updatePillStatus(true, expectedUid: 'user-123'),
        ]);

        expect(results, <bool>[true, true]);
        expect(
          (await db.select(db.healthEntries).getSingle()).hasTakenPillToday,
          isTrue,
        );
        expect(await db.getPendingSyncItems('user-123'), hasLength(1));
        expect(syncManager.calls, 1);
      },
    );

    test('leitura diária também exige o mesmo UID esperado', () async {
      await repository.updatePillStatus(true, expectedUid: 'user-123');

      expect(
        await repository.getPillStatusForToday(expectedUid: 'user-123'),
        isTrue,
      );
      expect(
        await repository.getPillStatusForToday(expectedUid: 'user-b'),
        isNull,
      );
    });
  });

  group('mutações Cycle vinculadas ao expectedUid', () {
    final cycleData = <String, dynamic>{
      'isEnabled': true,
      'lastPeriodStart': '2026-08-01T00:00:00.000',
      'cycleLengthDays': 30,
      'periodLengthDays': 6,
    };

    test('settings estável persiste com owner A', () async {
      final result = await repository.updateCycleSettings(
        cycleData,
        expectedUid: 'user-123',
      );

      final rows = await db.select(db.healthEntries).get();
      final queue = await db.select(db.syncQueueTable).get();

      expect(result, isTrue);
      expect(rows, hasLength(1));
      expect(queue, hasLength(1));
      expect(queue.single.ownerUid, 'user-123');
    });

    test('settings rejeita Firebase B sem Drift ou SyncQueue', () async {
      auth.user = FakeFirebaseUser('user-b');

      final result = await repository.updateCycleSettings(
        cycleData,
        expectedUid: 'user-123',
      );

      expect(result, isFalse);
      expect(await db.select(db.healthEntries).get(), isEmpty);
      expect(await db.select(db.syncQueueTable).get(), isEmpty);
    });

    test(
      'switch durante settings faz rollback e retry válido funciona',
      () async {
        final checkpointReached = Completer<void>();
        final releaseCheckpoint = Completer<void>();
        var checkpointCalls = 0;
        final guardedRepository = repositoryWithCheckpoint(() async {
          checkpointCalls += 1;
          if (checkpointCalls != 1) return;
          checkpointReached.complete();
          await releaseCheckpoint.future;
        });

        final mutation = guardedRepository.updateCycleSettings(
          cycleData,
          expectedUid: 'user-123',
        );
        await checkpointReached.future;
        auth.user = FakeFirebaseUser('user-b');
        releaseCheckpoint.complete();

        expect(await mutation, isFalse);
        expect(await db.select(db.healthEntries).get(), isEmpty);
        expect(await db.select(db.syncQueueTable).get(), isEmpty);

        auth.user = FakeFirebaseUser('user-123');
        expect(
          await guardedRepository.updateCycleSettings(
            cycleData,
            expectedUid: 'user-123',
          ),
          isTrue,
        );
        expect(await db.select(db.healthEntries).get(), hasLength(1));
        expect(
          (await db.select(db.syncQueueTable).get()).single.ownerUid,
          'user-123',
        );
      },
    );

    test('toggle estável persiste e mismatch falha fechado', () async {
      expect(
        await repository.toggleMenstrualCycleFeature(
          true,
          expectedUid: 'user-123',
        ),
        isTrue,
      );
      expect(await db.select(db.healthEntries).get(), hasLength(1));
      expect(
        (await db.select(db.syncQueueTable).get()).single.ownerUid,
        'user-123',
      );

      await db.clearAllData();
      auth.user = FakeFirebaseUser('user-b');

      expect(
        await repository.toggleMenstrualCycleFeature(
          false,
          expectedUid: 'user-123',
        ),
        isFalse,
      );
      expect(await db.select(db.healthEntries).get(), isEmpty);
      expect(await db.select(db.syncQueueTable).get(), isEmpty);
    });

    test('switch durante toggle faz rollback integral', () async {
      final checkpointReached = Completer<void>();
      final releaseCheckpoint = Completer<void>();
      final guardedRepository = repositoryWithCheckpoint(() async {
        checkpointReached.complete();
        await releaseCheckpoint.future;
      });

      final mutation = guardedRepository.toggleMenstrualCycleFeature(
        true,
        expectedUid: 'user-123',
      );
      await checkpointReached.future;
      auth.user = FakeFirebaseUser('user-b');
      releaseCheckpoint.complete();

      expect(await mutation, isFalse);
      expect(await db.select(db.healthEntries).get(), isEmpty);
      expect(await db.select(db.syncQueueTable).get(), isEmpty);
    });

    test('switch durante pill faz rollback integral', () async {
      final checkpointReached = Completer<void>();
      final releaseCheckpoint = Completer<void>();
      final guardedRepository = repositoryWithCheckpoint(() async {
        checkpointReached.complete();
        await releaseCheckpoint.future;
      });

      final mutation = guardedRepository.updatePillStatus(
        true,
        expectedUid: 'user-123',
      );
      await checkpointReached.future;
      auth.user = FakeFirebaseUser('user-b');
      releaseCheckpoint.complete();

      expect(await mutation, isFalse);
      expect(await db.select(db.healthEntries).get(), isEmpty);
      expect(await db.select(db.syncQueueTable).get(), isEmpty);
    });
  });

  test('ciclo menstrual salva localmente e entra na SyncQueue', () async {
    await repository.updateCycleSettings({
      'isEnabled': true,
      'lastPeriodStart': '2026-08-01T00:00:00.000',
      'cycleLengthDays': 30,
      'periodLengthDays': 6,
    }, expectedUid: 'user-123');

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
    expect(
      restored.menstrualCycle?['lastPeriodStart'],
      '2026-08-01T00:00:00.000',
    );
  });

  test('ciclo remoto ausente preserva data local válida', () async {
    await repository.updateCycleSettings({
      'isEnabled': true,
      'lastPeriodStart': '2026-08-01T00:00:00.000',
      'cycleLengthDays': 28,
      'periodLengthDays': 5,
    }, expectedUid: 'user-123');
    configureRepositoryWithHealthDocuments([
      _RecordingQueryDocumentSnapshot('2026-08-21', {
        'menstrualCycle': {
          'isEnabled': true,
          'cycleLengthDays': 30,
          'periodLengthDays': 6,
        },
      }),
    ]);

    await repository.syncHealthFromFirebase();

    final row = await db.select(db.healthEntries).getSingle();
    final cycle = jsonDecode(row.menstrualCycleJson!) as Map;
    expect(cycle['lastPeriodStart'], '2026-08-01T00:00:00.000');
    expect(cycle['cycleLengthDays'], 30);
    expect(cycle['periodLengthDays'], 6);
  });

  test('ciclo remoto ausente sem local não fabrica data', () async {
    configureRepositoryWithHealthDocuments([
      _RecordingQueryDocumentSnapshot('2026-08-21', {
        'menstrualCycle': {
          'isEnabled': true,
          'cycleLengthDays': 28,
          'periodLengthDays': 5,
        },
      }),
    ]);

    await repository.syncHealthFromFirebase();

    final row = await db.select(db.healthEntries).getSingle();
    final cycle = jsonDecode(row.menstrualCycleJson!) as Map;
    final restored = await repository.getHealthStream().first;
    expect(cycle.containsKey('lastPeriodStart'), isFalse);
    expect(restored.menstrualCycle?['isEnabled'], isTrue);
    expect(restored.cyclePhaseInfo['day'], 0);
    expect(restored.cyclePhaseInfo['name'], 'Ciclo não configurado');
  });

  test('ciclo remoto inválido preserva data local válida', () async {
    await repository.updateCycleSettings({
      'isEnabled': true,
      'lastPeriodStart': '2026-08-01T00:00:00.000',
      'cycleLengthDays': 28,
      'periodLengthDays': 5,
    }, expectedUid: 'user-123');
    configureRepositoryWithHealthDocuments([
      _RecordingQueryDocumentSnapshot('2026-08-21', {
        'menstrualCycle': {
          'isEnabled': true,
          'lastPeriodStart': 'not-a-date',
          'cycleLengthDays': 31,
          'periodLengthDays': 7,
        },
      }),
    ]);

    await repository.syncHealthFromFirebase();

    final row = await db.select(db.healthEntries).getSingle();
    final cycle = jsonDecode(row.menstrualCycleJson!) as Map;
    expect(cycle['lastPeriodStart'], '2026-08-01T00:00:00.000');
    expect(cycle['cycleLengthDays'], 31);
    expect(cycle['periodLengthDays'], 7);
  });

  test('ciclo remoto inválido sem local permanece incompleto', () async {
    configureRepositoryWithHealthDocuments([
      _RecordingQueryDocumentSnapshot('2026-08-21', {
        'mood': 'Tranquilo',
        'waterIntakeMl': 1250,
        'hasTakenPillToday': true,
        'menstrualCycle': {
          'isEnabled': true,
          'lastPeriodStart': 'not-a-date',
          'cycleLengthDays': 28,
          'periodLengthDays': 5,
        },
      }),
    ]);

    await repository.syncHealthFromFirebase();

    final row = await db.select(db.healthEntries).getSingle();
    final cycle = jsonDecode(row.menstrualCycleJson!) as Map;
    final restored = await repository.getHealthStream().first;
    expect(cycle.containsKey('lastPeriodStart'), isFalse);
    expect(restored.menstrualCycle?['isEnabled'], isTrue);
    expect(restored.cyclePhaseInfo['day'], 0);
    expect(restored.mood, 'Tranquilo');
    expect(restored.waterIntakeMl, 1250);
    expect(restored.hasTakenPillToday, isTrue);
  });

  test('string menstrual vazia não fabrica data', () async {
    configureRepositoryWithHealthDocuments([
      _RecordingQueryDocumentSnapshot('2026-08-21', {
        'menstrualCycle': {
          'isEnabled': true,
          'lastPeriodStart': '',
          'cycleLengthDays': 28,
          'periodLengthDays': 5,
        },
      }),
    ]);

    await repository.syncHealthFromFirebase();

    final row = await db.select(db.healthEntries).getSingle();
    final cycle = jsonDecode(row.menstrualCycleJson!) as Map;
    expect(cycle.containsKey('lastPeriodStart'), isFalse);
  });

  test('tipo menstrual inesperado não interrompe hidratação', () async {
    configureRepositoryWithHealthDocuments([
      _RecordingQueryDocumentSnapshot('2026-08-21', {
        'mood': 'Focado',
        'waterIntakeMl': 750,
        'hasTakenPillToday': true,
        'menstrualCycle': {
          'isEnabled': true,
          'lastPeriodStart': 20260801,
          'cycleLengthDays': 28,
          'periodLengthDays': 5,
        },
      }),
    ]);

    await repository.syncHealthFromFirebase();

    final row = await db.select(db.healthEntries).getSingle();
    final cycle = jsonDecode(row.menstrualCycleJson!) as Map;
    expect(cycle.containsKey('lastPeriodStart'), isFalse);
    expect(row.mood, 'Focado');
    expect(row.waterIntakeMl, 750);
    expect(row.hasTakenPillToday, isTrue);
  });

  test(
    'resposta parcial preserva ausentes e aplica zero e false explícitos',
    () async {
      await repository.updateMood('Radiante');
      await repository.addWater(750);
      await repository.updatePillStatus(true, expectedUid: 'user-123');

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
    expect(restored.menstrualCycle?.containsKey('lastPeriodStart'), isFalse);
    expect(restored.date, DateTime(2026, 8, 21));
  });

  test(
    'ciclo persiste no dia seguinte sem carregar métricas diárias antigas',
    () async {
      await repository.updateMood('Radiante');
      await repository.addWater(750);
      await repository.updatePillStatus(true, expectedUid: 'user-123');
      await repository.updateCycleSettings({
        'isEnabled': true,
        'lastPeriodStart': '2026-08-01T00:00:00.000',
        'cycleLengthDays': 30,
        'periodLengthDays': 6,
      }, expectedUid: 'user-123');

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

  test('permissão normal negada preserva medicamento salvo', () async {
    notificationService.notificationPermissionGranted = false;

    await repository.addMedication(
      'Medicamento de teste',
      DateTime(2026, 8, 25, 21),
      7,
    );

    expect(await db.select(db.medications).get(), hasLength(1));
    expect(notificationService.notificationPermissionRequests, 1);
    expect(notificationService.platformPermissionRequests, 1);
    expect(
      notificationService.lastPermissionPreferenceKey,
      NotificationPreferenceKeys.medicationReminders,
    );
    expect(notificationService.exactPermissionRequests, 0);
    expect(notificationService.scheduleCalls, 0);
  });

  test(
    'preferência global off salva sem pedir permissões ou agendar',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        NotificationPreferenceKeys.allNotifications: false,
        NotificationPreferenceKeys.medicationReminders: true,
      });

      await repository.addMedication(
        'Medicamento de teste',
        DateTime(2026, 8, 25, 21),
        null,
      );

      expect(await db.select(db.medications).get(), hasLength(1));
      expect(notificationService.platformPermissionRequests, 0);
      expect(notificationService.exactPermissionRequests, 0);
      expect(notificationService.scheduleCalls, 0);
    },
  );

  test('preferência de medicamento off salva sem pedir ou agendar', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      NotificationPreferenceKeys.allNotifications: true,
      NotificationPreferenceKeys.medicationReminders: false,
    });

    await repository.addMedication(
      'Medicamento de teste',
      DateTime(2026, 8, 25, 21),
      null,
    );

    expect(await db.select(db.medications).get(), hasLength(1));
    expect(notificationService.platformPermissionRequests, 0);
    expect(notificationService.exactPermissionRequests, 0);
    expect(notificationService.scheduleCalls, 0);
  });

  test('preferências on preservam fluxo completo de permissões', () async {
    await repository.addMedication(
      'Medicamento de teste',
      DateTime(2026, 8, 25, 21),
      null,
    );

    expect(await db.select(db.medications).get(), hasLength(1));
    expect(notificationService.platformPermissionRequests, 1);
    expect(notificationService.exactPermissionRequests, 1);
    expect(notificationService.scheduleCalls, 1);
  });

  test('exact negado preserva medicamento e ainda tenta fallback', () async {
    notificationService.exactPermissionGranted = false;

    await repository.addMedication(
      'Medicamento de teste',
      DateTime(2026, 8, 25, 21),
      null,
    );

    expect(await db.select(db.medications).get(), hasLength(1));
    expect(notificationService.exactPermissionRequests, 1);
    expect(notificationService.scheduleCalls, 1);
  });

  test('schedule false preserva medicamento salvo', () async {
    notificationService.scheduleResult = false;

    await repository.addMedication(
      'Medicamento de teste',
      DateTime(2026, 8, 25, 21),
      null,
    );

    expect(await db.select(db.medications).get(), hasLength(1));
    expect(notificationService.scheduleCalls, 1);
  });

  test(
    'deleteMedication mantém cancelamento individual pelo mesmo ID',
    () async {
      const firestoreId = 'medication-to-delete';
      final localId = await db
          .into(db.medications)
          .insert(
            MedicationsCompanion.insert(
              firestoreId: firestoreId,
              name: 'Medicamento de teste',
              startDate: DateTime(2026, 8, 25, 21),
            ),
          );

      await repository.deleteMedication(firestoreId, localId);

      expect(await db.select(db.medications).get(), isEmpty);
      expect(notificationService.cancelledIds, <int>[
        notificationIdForMedication(firestoreId),
      ]);
    },
  );

  test('hidratação agenda sem solicitar permissão exact', () async {
    configureRepositoryWithHealthDocuments(
      const [],
      medicationDocuments: [
        _RecordingQueryDocumentSnapshot('remote-medication', {
          'name': 'Medicamento remoto',
          'startDate': Timestamp.fromDate(DateTime(2026, 8, 25, 21)),
          'durationDays': 7,
          'endDate': Timestamp.fromDate(DateTime(2026, 9, 1, 21)),
        }),
      ],
    );

    await repository.syncHealthFromFirebase();

    final medication = await db.select(db.medications).getSingle();
    expect(medication.startDate, DateTime(2026, 8, 25, 21));
    expect(notificationService.scheduleCalls, 1);
    expect(notificationService.exactPermissionRequests, 0);
  });
}
