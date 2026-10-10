import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/local_database_identity.dart';
import 'package:life_os/core/database/local_mutation_gate.dart';
import 'package:life_os/core/services/notification_service.dart';
import 'package:life_os/core/services/sync_manager.dart';
import 'package:life_os/features/health/data/local/water_v2_local_store.dart';
import 'package:life_os/features/health/data/local/water_v2_tables.dart';
import 'package:life_os/features/health/data/repositories/health_repository.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

const owner = 'user-a';
const day = '2026-08-21';
const epoch = '11111111-1111-4111-8111-111111111111';
const otherEpoch = '22222222-2222-4222-8222-222222222222';
const idA = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const idB = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const instant = '2026-08-21T10:00:00.123Z';

WaterV2IntentInput intent({
  String uid = owner,
  String id = idA,
  String healthDay = day,
  int delta = 250,
  String occurred = instant,
  int offset = 0,
  String? origin = epoch,
}) => WaterV2IntentInput(
  ownerUid: uid,
  mutationId: id,
  healthDay: healthDay,
  deltaMl: delta,
  occurredAtUtc: occurred,
  timeZoneOffsetMinutes: offset,
  originEpoch: origin,
);

class _Writes extends QueryInterceptor {
  bool failIntent = false;
  bool failState = false;
  bool failCommit = false;
  Future<void> Function()? afterIntent;
  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    if ((failIntent && statement.contains('"water_v2_intents"')) ||
        (failState && statement.contains('"water_v2_daily_states"'))) {
      throw StateError('TEST_WRITE_FAILURE');
    }
    final result = await super.runInsert(executor, statement, args);
    if (statement.contains('"water_v2_intents"')) await afterIntent?.call();
    return result;
  }

  @override
  Future<void> commitTransaction(TransactionExecutor inner) async {
    if (failCommit) throw StateError('TEST_COMMIT_FAILURE');
    await super.commitTransaction(inner);
  }
}

class _User extends Fake implements User {
  @override
  String get uid => owner;
}

class _Auth extends Fake implements FirebaseAuth {
  @override
  User get currentUser => _User();
}

class _Firestore extends Fake implements FirebaseFirestore {
  int calls = 0;
  @override
  CollectionReference<Map<String, dynamic>> collection(String path) {
    calls++;
    throw StateError('NETWORK_FORBIDDEN');
  }
}

class _Notifications extends Fake implements NotificationService {}

class _Sync extends Fake implements SyncManager {
  int calls = 0;
  @override
  Future<bool> processPendingItems() async {
    calls++;
    return false;
  }
}

void main() {
  late sqlite.Database raw;
  late AppDatabase db;
  late WaterV2LocalStore store;
  late _Writes writes;
  Future<WaterV2DailyState> confirmed({
    String uid = owner,
    String healthDay = day,
    String stateEpoch = epoch,
    int revision = 1,
    int total = 1000,
    String reconciled = instant,
    LocalMutationTicket? admission,
  }) => store.persistConfirmedState(
    ownerUid: uid,
    healthDay: healthDay,
    epoch: stateEpoch,
    revision: revision,
    confirmedWaterIntakeMl: total,
    reconciledAtUtc: reconciled,
    admission: admission,
  );
  Future<List<WaterV2Intent>> rows([
    String uid = owner,
    String healthDay = day,
  ]) => store.readIntents(ownerUid: uid, healthDay: healthDay);
  setUp(() async {
    raw = sqlite.sqlite3.openInMemory();
    writes = _Writes();
    db = AppDatabase(
      executor: NativeDatabase.opened(
        raw,
        closeUnderlyingOnClose: false,
      ).interceptWith(writes),
    );
    store = WaterV2LocalStore(db);
    await db.select(db.waterV2Intents).get();
  });
  tearDown(() async {
    await db.close();
    raw.dispose();
  });

  test(
    'inserts immutable intent without creating confirmed state, projection or SyncQueue',
    () async {
      final row = await store.insertIntent(intent());
      expect(row.mutationId, idA);
      expect(row.occurredAtUtc, instant);
      expect(row.localStatus, WaterV2IntentStatus.notSent);
      expect(row.syncQueueId, isNull);
      expect(row.originEpoch, epoch);
      expect(row.deltaMl, 250);
      expect(await rows(), [row]);
      expect(
        await store.readConfirmedState(ownerUid: owner, healthDay: day),
        isNull,
      );
      expect(await db.select(db.healthEntries).get(), isEmpty);
      expect(await db.select(db.syncQueueTable).get(), isEmpty);
    },
  );
  test(
    'identical UUID insertion is idempotent and SQLite rejects a raw duplicate',
    () async {
      final first = await store.insertIntent(intent());
      expect(await store.insertIntent(intent()), first);
      expect(await rows(), hasLength(1));
      await expectLater(
        () => db.into(db.waterV2Intents).insert(first.toCompanion(false)),
        throwsA(isA<sqlite.SqliteException>()),
      );
      expect(await rows(), [first]);
    },
  );
  test('concurrent identical insertions persist one identity', () async {
    final results = await Future.wait([
      store.insertIntent(intent()),
      store.insertIntent(intent()),
    ]);
    expect(results[0], results[1]);
    expect(await rows(), hasLength(1));
  });
  for (final changed in [
    intent(occurred: '2026-08-21T11:00:00.123Z'),
    intent(offset: 60),
    intent(healthDay: '2026-08-22', occurred: '2026-08-22T10:00:00.123Z'),
    intent(origin: otherEpoch),
  ]) {
    test(
      'UUID collision rejects differing immutable fields: ${changed.occurredAtUtc}/${changed.timeZoneOffsetMinutes}/${changed.originEpoch}',
      () async {
        final original = await store.insertIntent(intent());
        await expectLater(() => store.insertIntent(changed), throwsStateError);
        expect(await rows(), [original]);
      },
    );
  }
  test(
    'unprovisioned origin stays null and retry cannot adopt an epoch',
    () async {
      final original = await store.insertIntent(intent(origin: null));
      expect(original.localStatus, WaterV2IntentStatus.unreconciled);
      await confirmed();
      expect((await rows()).single.originEpoch, isNull);
      expect(await store.insertIntent(intent(origin: null)), original);
      await expectLater(() => store.insertIntent(intent()), throwsStateError);
      expect((await rows()).single.originEpoch, isNull);
    },
  );
  test(
    'retry preserves an existing delivery state and explicit queue link',
    () async {
      final queueId = await db.insertSyncItem(
        ownerUid: owner,
        collection: 'health_info',
        docId: day,
        operationType: 'update',
        payloadJson: '{"waterIntakeMl":1250}',
      );
      await store.insertIntent(intent());
      // Model a future integration's row without implementing ACK/link APIs now.
      await (db.update(
        db.waterV2Intents,
      )..where((t) => t.mutationId.equals(idA))).write(
        WaterV2IntentsCompanion(
          localStatus: const Value(WaterV2IntentStatus.unreconciled),
          syncQueueId: Value(queueId),
        ),
      );
      final before = (await rows()).single;
      expect(await store.insertIntent(intent()), before);
      await db.markSyncItemAsSucceeded(queueId, owner);
      await db.cleanupSucceededSyncItems(
        owner,
        DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch,
      );
      expect(await db.select(db.syncQueueTable).get(), isEmpty);
      expect(await store.insertIntent(intent()), before);
    },
  );
  test(
    'two devices with equal local queue ID use distinct global UUIDs',
    () async {
      final secondDb = AppDatabase(executor: NativeDatabase.memory());
      addTearDown(secondDb.close);
      final secondStore = WaterV2LocalStore(secondDb);
      Future<int> localId(AppDatabase database) => database.insertSyncItem(
        ownerUid: owner,
        collection: 'health_info',
        docId: day,
        operationType: 'update',
        payloadJson: '{"waterIntakeMl":1250}',
      );
      expect(await localId(db), 1);
      expect(await localId(secondDb), 1);
      final a = await store.insertIntent(intent(id: idA));
      final b = await secondStore.insertIntent(intent(id: idB));
      expect(a.mutationId, isNot(b.mutationId));
      expect(a.syncQueueId, isNull);
      expect(b.syncQueueId, isNull);
      expect(await rows(), [a]);
      expect(await secondStore.readIntents(ownerUid: owner, healthDay: day), [
        b,
      ]);
    },
  );
  test(
    'UUID namespace is per owner and reads are partitioned by day',
    () async {
      await store.insertIntent(intent());
      await store.insertIntent(intent(uid: 'user-b', origin: otherEpoch));
      await store.insertIntent(
        intent(
          id: idB,
          healthDay: '2026-08-22',
          occurred: '2026-08-22T10:00:00.123Z',
        ),
      );
      expect(await rows(), hasLength(1));
      expect(await rows('user-b'), hasLength(1));
      expect(await rows(owner, '2026-08-22'), hasLength(1));
      expect(await rows('user-c'), isEmpty);
    },
  );
  test(
    'confirmed state is explicit, bounded and does not ACK or transform legacy data',
    () async {
      await db
          .into(db.healthEntries)
          .insert(
            HealthEntriesCompanion.insert(
              docId: day,
              date: DateTime.utc(2026, 8, 21),
              waterIntakeMl: const Value(1250),
            ),
          );
      final queueId = await db.insertSyncItem(
        ownerUid: owner,
        collection: 'health_info',
        docId: day,
        operationType: 'update',
        payloadJson: '{ "waterIntakeMl": 1500 }',
      );
      final legacy = await db.select(db.healthEntries).getSingle();
      final queue = await db.select(db.syncQueueTable).getSingle();
      final original = await store.insertIntent(intent());
      final state = await confirmed(total: 1000, revision: 2);
      expect(state.confirmedWaterIntakeMl, 1000);
      expect(state.revision, 2);
      expect(state.reconciledAtUtc, instant);
      expect(
        await store.readConfirmedState(ownerUid: owner, healthDay: day),
        state,
      );
      expect(await db.select(db.healthEntries).getSingle(), legacy);
      expect(await db.getSyncItemById(queueId), queue);
      expect(await rows(), [original]);
    },
  );
  test(
    'state accepts monotonic revision, same snapshot replay and saturated zero-credit revisions',
    () async {
      final first = await confirmed(revision: 1, total: 999900);
      expect(await confirmed(revision: 1, total: 999900), first);
      await confirmed(revision: 2, total: 1000000);
      final last = await confirmed(revision: 3, total: 1000000);
      expect(last.revision, 3);
      expect(last.confirmedWaterIntakeMl, 1000000);
    },
  );
  for (final bad in [(1, 750), (2, 1250), (3, 750)]) {
    test(
      'rejects regressed or inconsistent state revision=${bad.$1} total=${bad.$2}',
      () async {
        final original = await confirmed(revision: 2, total: 1000);
        await expectLater(
          () => confirmed(revision: bad.$1, total: bad.$2),
          throwsStateError,
        );
        expect(
          await store.readConfirmedState(ownerUid: owner, healthDay: day),
          original,
        );
      },
    );
  }
  test('epochs cannot mix across days or intents for the same owner', () async {
    await confirmed();
    await expectLater(
      () => confirmed(stateEpoch: otherEpoch),
      throwsStateError,
    );
    await expectLater(
      () => confirmed(healthDay: '2026-08-22', stateEpoch: otherEpoch),
      throwsStateError,
    );
    await expectLater(
      () => store.insertIntent(intent(origin: otherEpoch)),
      throwsStateError,
    );
    expect(await db.select(db.waterV2DailyStates).get(), hasLength(1));
    expect(await rows(), isEmpty);
  });
  test(
    'an intent epoch prevents a different confirmed epoch, even before state exists',
    () async {
      await store.insertIntent(intent());
      await expectLater(
        () => confirmed(stateEpoch: otherEpoch),
        throwsStateError,
      );
      expect(await db.select(db.waterV2DailyStates).get(), isEmpty);
    },
  );
  test(
    'different owners may independently establish different epochs',
    () async {
      await confirmed();
      await confirmed(uid: 'user-b', stateEpoch: otherEpoch, total: 0);
      expect(
        (await store.readConfirmedState(
          ownerUid: 'user-b',
          healthDay: day,
        ))!.epoch,
        otherEpoch,
      );
      expect(
        (await store.readConfirmedState(
          ownerUid: owner,
          healthDay: day,
        ))!.epoch,
        epoch,
      );
    },
  );
  for (final commit in [false, true]) {
    test(
      'failure ${commit ? 'at commit' : 'on second write'} rolls back intent + state + legacy queue',
      () async {
        final before = await confirmed();
        writes.failState = !commit;
        writes.failCommit = commit;
        await expectLater(
          () => db.transaction(() async {
            await store.insertIntent(intent());
            await db.insertSyncItem(
              ownerUid: owner,
              collection: 'health_info',
              docId: day,
              operationType: 'update',
              payloadJson: '{"waterIntakeMl":1250}',
            );
            await confirmed(revision: 2, total: 1250);
          }),
          throwsStateError,
        );
        writes.failState = false;
        writes.failCommit = false;
        expect(await rows(), isEmpty);
        expect(await db.select(db.syncQueueTable).get(), isEmpty);
        expect(
          await store.readConfirmedState(ownerUid: owner, healthDay: day),
          before,
        );
      },
    );
  }
  test('intent insert failure leaves no row or side effect', () async {
    writes.failIntent = true;
    await expectLater(() => store.insertIntent(intent()), throwsStateError);
    expect(await rows(), isEmpty);
    expect(await db.select(db.waterV2DailyStates).get(), isEmpty);
  });
  test(
    'UID A → B → A preserves data and invalidates old A admission',
    () async {
      var currentUid = owner;
      db.localMutations.bindSessionReader(() => currentUid);
      db.localMutations.openPreparedSession();
      final original = await store.insertIntent(intent());
      final old = db.localMutations.capture(expectedUid: owner);
      currentUid = 'user-b';
      db.localMutations.observeSession(currentUid);
      db.localMutations.openPreparedSession();
      await expectLater(() => rows(), throwsA(isA<LocalMutationUnavailable>()));
      await store.insertIntent(intent(uid: 'user-b', origin: otherEpoch));
      currentUid = owner;
      db.localMutations.observeSession(currentUid);
      db.localMutations.openPreparedSession();
      expect(await rows(), [original]);
      await expectLater(
        () => store.insertIntent(intent(id: idB), admission: old),
        throwsA(isA<LocalMutationUnavailable>()),
      );
      expect(await rows(), [original]);
      await store.insertIntent(intent(id: idB));
      expect(await rows(), hasLength(2));
    },
  );
  test(
    'scope rejects another owner even without a bound Auth reader',
    () async {
      final scoped = AppDatabase.forUser(
        identity: LocalDatabaseIdentity(owner),
        executor: NativeDatabase.memory(),
      );
      addTearDown(scoped.close);
      final local = WaterV2LocalStore(scoped);
      await local.insertIntent(intent());
      await expectLater(
        () => local.insertIntent(intent(uid: 'user-b')),
        throwsA(isA<LocalMutationUnavailable>()),
      );
      await expectLater(
        () => local.readIntents(ownerUid: 'user-b', healthDay: day),
        throwsA(isA<LocalMutationUnavailable>()),
      );
      await expectLater(
        () => local.persistConfirmedState(
          ownerUid: 'user-b',
          healthDay: day,
          epoch: epoch,
          revision: 0,
          confirmedWaterIntakeMl: 0,
          reconciledAtUtc: instant,
        ),
        throwsA(isA<LocalMutationUnavailable>()),
      );
    },
  );
  test(
    'session changes after SQLite insert roll back the old producer',
    () async {
      var currentUid = owner;
      db.localMutations.bindSessionReader(() => currentUid);
      db.localMutations.openPreparedSession();
      final reached = Completer<void>();
      final release = Completer<void>();
      writes.afterIntent = () async {
        reached.complete();
        await release.future;
      };
      final pending = store.insertIntent(intent());
      final rejected = expectLater(
        pending,
        throwsA(isA<LocalMutationUnavailable>()),
      );
      await reached.future;
      currentUid = 'user-b';
      db.localMutations.observeSession(currentUid);
      release.complete();
      await rejected;
      writes.afterIntent = null;
      expect(raw.select('SELECT * FROM water_v2_intents'), isEmpty);
      currentUid = owner;
      db.localMutations.observeSession(currentUid);
      db.localMutations.openPreparedSession();
      expect(await rows(), isEmpty);
    },
  );
  test(
    'quiescence rejects new local admissions without waiting or discarding identities',
    () async {
      db.localMutations.bindSessionReader(() => owner);
      db.localMutations.openPreparedSession();
      final original = await store.insertIntent(intent());
      final barrier = db.localMutations.beginQuiesce(owner);
      await barrier.drain();
      await expectLater(
        () => store.insertIntent(intent(id: idB)),
        throwsA(isA<LocalMutationUnavailable>()),
      );
      barrier.finish(signOutConfirmed: false);
      expect(await rows(), [original]);
      await store.insertIntent(intent(id: idB));
      expect(await rows(), hasLength(2));
    },
  );
  test(
    'detach invalidates an in-flight write and preserves prior durable intent',
    () async {
      final original = await store.insertIntent(intent());
      final reached = Completer<void>();
      final release = Completer<void>();
      writes.afterIntent = () async {
        reached.complete();
        await release.future;
      };
      final pending = store.insertIntent(intent(id: idB));
      final rejected = expectLater(
        pending,
        throwsA(isA<LocalMutationUnavailable>()),
      );
      await reached.future;
      final detach = db.localMutations.sealAndDrainForDetach();
      release.complete();
      await rejected;
      await detach;
      expect(
        raw
            .select('SELECT mutation_id FROM water_v2_intents')
            .map((r) => r['mutation_id']),
        [original.mutationId],
      );
    },
  );
  test(
    'close and reopen the actual SQLite file retains identity, milliseconds, state and UID isolation',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'water_v2_restart_',
      );
      addTearDown(() {
        expect(
          directory.absolute.parent.path,
          Directory.systemTemp.absolute.path,
        );
        expect(
          directory.uri.pathSegments.where((s) => s.isNotEmpty).last,
          startsWith('water_v2_restart_'),
        );
        directory.deleteSync(recursive: true);
      });
      Future<AppDatabase> open(String uid) async => AppDatabase.forUser(
        identity: LocalDatabaseIdentity(uid),
        executor: NativeDatabase(LocalDatabaseIdentity(uid).fileIn(directory)),
      );
      var a = await open(owner);
      var local = WaterV2LocalStore(a);
      final original = await local.insertIntent(
        intent(occurred: '2026-08-22T01:00:00.987Z', offset: -180),
      );
      await local.persistConfirmedState(
        ownerUid: owner,
        healthDay: day,
        epoch: epoch,
        revision: 4,
        confirmedWaterIntakeMl: 1250,
        reconciledAtUtc: instant,
      );
      await a.close();
      final b = await open('user-b');
      final localB = WaterV2LocalStore(b);
      expect(
        await localB.readIntents(ownerUid: 'user-b', healthDay: day),
        isEmpty,
      );
      await localB.insertIntent(
        intent(uid: 'user-b', id: idA, origin: otherEpoch),
      );
      await b.close();
      a = await open(owner);
      local = WaterV2LocalStore(a);
      try {
        expect(
          await local.insertIntent(
            intent(occurred: '2026-08-22T01:00:00.987Z', offset: -180),
          ),
          original,
        );
        expect(await local.readIntents(ownerUid: owner, healthDay: day), [
          original,
        ]);
        expect(
          (await local.readConfirmedState(
            ownerUid: owner,
            healthDay: day,
          ))!.revision,
          4,
        );
      } finally {
        await a.close();
      }
    },
  );
  test(
    'all local operations run with HTTP forbidden and produce no network request',
    () async {
      var requests = 0;
      await HttpOverrides.runZoned(
        () async {
          await store.insertIntent(intent());
          await confirmed();
          await rows();
          await store.readConfirmedState(ownerUid: owner, healthDay: day);
        },
        createHttpClient: (_) {
          requests++;
          throw StateError('NETWORK_FORBIDDEN');
        },
      );
      expect(requests, 0);
    },
  );
  test(
    'current addWater remains V1 even if isolated V2 records exist',
    () async {
      final firestore = _Firestore();
      final sync = _Sync();
      await db
          .into(db.healthEntries)
          .insert(
            HealthEntriesCompanion.insert(
              docId: day,
              date: DateTime(2026, 8, 21),
              waterIntakeMl: const Value(1000),
              mood: const Value('bem'),
              hasTakenPillToday: const Value(true),
              menstrualCycleJson: const Value('{"cycleLength":28}'),
            ),
          );
      final v2 = await confirmed(total: 10000);
      final repo = HealthRepository(
        _Notifications(),
        firestore,
        _Auth(),
        db,
        sync,
        now: () => DateTime(2026, 8, 21, 10),
      );
      await repo.addWater();
      final legacy = await db.select(db.healthEntries).getSingle();
      expect(legacy.waterIntakeMl, 1250);
      expect(legacy.mood, 'bem');
      expect(legacy.hasTakenPillToday, isTrue);
      expect(legacy.menstrualCycleJson, '{"cycleLength":28}');
      final queued = await db.select(db.syncQueueTable).getSingle();
      expect(queued.ownerUid, owner);
      expect(queued.status, 'pending');
      expect(queued.attemptCount, 0);
      expect(jsonDecode(queued.payloadJson), {
        'waterIntakeMl': 1250,
        'date': DateTime(2026, 8, 21, 10).toIso8601String(),
      });
      expect(queued.collection, 'health_info');
      expect(queued.operationType, 'update');
      expect(await rows(), isEmpty);
      expect(
        await store.readConfirmedState(ownerUid: owner, healthDay: day),
        v2,
      );
      expect(firestore.calls, 0);
      expect(sync.calls, 1);
    },
  );
  test(
    'explicit clearAllData includes the new tables, with no automatic cleanup on reads',
    () async {
      await store.insertIntent(intent());
      await confirmed();
      expect(await rows(), hasLength(1));
      await db.clearAllData();
      expect(await rows(), isEmpty);
      expect(await db.select(db.waterV2DailyStates).get(), isEmpty);
    },
  );

  final invalidIntents = <String, WaterV2IntentInput>{
    'empty owner': intent(uid: ''),
    'foreign path': intent(uid: '../other'),
    'trimmed owner': intent(uid: ' user-a'),
    'local ID': intent(id: '1'),
    'uppercase UUID': intent(id: idA.toUpperCase()),
    'UUID v1': intent(id: 'aaaaaaaa-aaaa-1aaa-8aaa-aaaaaaaaaaaa'),
    'impossible date': intent(healthDay: '2026-02-30'),
    'invalid year': intent(healthDay: '0000-01-01'),
    'invalid delta': intent(delta: 500),
    'timestamp rollover': intent(occurred: '2026-02-30T10:00:00.123Z'),
    'missing milliseconds': intent(occurred: '2026-08-21T10:00:00Z'),
    'microseconds': intent(occurred: '2026-08-21T10:00:00.123456Z'),
    'noncanonical UTC': intent(occurred: '2026-08-21T10:00:00.123+00:00'),
    'offset too large': intent(offset: 841),
    'offset too small': intent(offset: -841),
    'captured day mismatch': intent(occurred: '2026-08-22T10:00:00.123Z'),
    'bad epoch': intent(origin: 'legacy'),
  };
  for (final entry in invalidIntents.entries) {
    test('invalid intent ${entry.key} rejected with no writes', () async {
      await expectLater(
        () => store.insertIntent(entry.value),
        throwsArgumentError,
      );
      expect(await rows(), isEmpty);
      expect(await db.select(db.waterV2DailyStates).get(), isEmpty);
    });
  }
  for (final bad in [(0, -1), (0, 1000001), (-1, 0), (9007199254740992, 0)]) {
    test('invalid confirmed bounds ${bad.$1}/${bad.$2} rejected', () async {
      await expectLater(
        () => confirmed(revision: bad.$1, total: bad.$2),
        throwsArgumentError,
      );
      expect(await db.select(db.waterV2DailyStates).get(), isEmpty);
    });
  }
  for (final constraint in [
    "mutation_id = 'local-1'",
    'delta_ml = 500',
    'time_zone_offset_minutes = 841',
    "origin_epoch = 'unknown'",
    "local_status = 'succeeded'",
    'sync_queue_id = -1',
    "owner_uid = ''",
  ]) {
    test('SQLite enforces $constraint independently of the store', () async {
      final original = await store.insertIntent(intent());
      await expectLater(
        () => db.customStatement('UPDATE water_v2_intents SET $constraint'),
        throwsA(isA<sqlite.SqliteException>()),
      );
      expect(await rows(), [original]);
    });
  }
  for (final constraint in [
    'revision = -1',
    'confirmed_water_intake_ml = 1000001',
    "epoch = 'unknown'",
  ]) {
    test(
      'SQLite state constraint $constraint preserves previous snapshot',
      () async {
        final original = await confirmed();
        await expectLater(
          () => db.customStatement(
            'UPDATE water_v2_daily_states SET $constraint',
          ),
          throwsA(isA<sqlite.SqliteException>()),
        );
        expect(
          await store.readConfirmedState(ownerUid: owner, healthDay: day),
          original,
        );
      },
    );
  }
}
