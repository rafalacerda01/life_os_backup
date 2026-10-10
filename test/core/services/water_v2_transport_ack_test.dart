import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/remote_send_permit.dart';
import 'package:life_os/core/database/local_mutation_gate.dart';
import 'package:life_os/core/services/sync_manager.dart';
import 'package:life_os/core/services/sync_operation_result.dart';
import 'package:life_os/core/services/sync_queue_store.dart';
import 'package:life_os/core/services/sync_remote_data_source.dart';
import 'package:life_os/core/services/water_v2_contract.dart';
import 'package:life_os/core/services/water_v2_remote_data_source.dart';
import 'package:life_os/core/services/water_v2_sync_processor.dart';
import 'package:life_os/features/health/data/local/water_v2_local_store.dart';
import 'package:life_os/features/health/data/local/water_v2_tables.dart';
import 'package:logger/logger.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

const uid = 'water-owner';
const day = '2026-08-21';
const epoch = '11111111-1111-4111-8111-111111111111';
const epochB = '22222222-2222-4222-8222-222222222222';
const idA = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const idB = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const idC = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const instant = '2026-08-21T10:00:00.123Z';

class _User extends Fake implements User {
  _User(this.uid);
  @override
  final String uid;
}

class _Auth extends Fake implements FirebaseAuth {
  String? uid = 'water-owner';
  @override
  User? get currentUser => uid == null ? null : _User(uid!);
}

class _Firestore extends Fake implements FirebaseFirestore {
  int calls = 0;
  @override
  CollectionReference<Map<String, dynamic>> collection(String path) {
    calls++;
    throw StateError('FIRESTORE_FORBIDDEN');
  }
}

class _OtherRemote implements SyncRemoteDataSource {
  int calls = 0;
  @override
  Future<SyncOperationResult> process(
    String uid,
    SyncQueueTableData item,
  ) async {
    calls++;
    return const SyncOperationResult.success();
  }
}

class _Queue extends AppDatabaseSyncQueueStore {
  _Queue(super.db);
  int genericAcks = 0;
  @override
  Future<int> markSyncItemAsSucceeded(int id, String ownerUid) {
    genericAcks++;
    return super.markSyncItemAsSucceeded(id, ownerUid);
  }
}

class _Writes extends QueryInterceptor {
  bool failQueue = false, failCommit = false;
  Future<void> Function()? afterProjection;
  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String sql,
    List<Object?> args,
  ) async {
    if (failQueue && sql.contains('"sync_queue_table"'))
      throw StateError('SQLITE_FAKE_SECRET');
    final result = await super.runUpdate(executor, sql, args);
    if (sql.contains('"health_entries"')) await afterProjection?.call();
    return result;
  }

  @override
  Future<void> commitTransaction(TransactionExecutor executor) {
    if (failCommit) throw StateError('SQLITE_COMMIT_FAKE_SECRET');
    return super.commitTransaction(executor);
  }
}

/// No Firebase. A durable fake receipt ledger distinguishes lost responses
/// from lost commits and implements idempotent UUID replay and saturation.
class _Client extends MockClient {
  _Client(super.handler);
  bool closed = false;
  @override
  void close() {
    closed = true;
    super.close();
  }
}

class _Ledger {
  int total = 1000, revision = 0, writes = 0;
  final receipts = <String, ({String body, int credit, int revision})>{};
  http.Response apply(http.Request request) {
    final data = jsonDecode(request.body) as Map<String, dynamic>;
    final mutation = data['mutationId'] as String;
    final prior = receipts[mutation];
    if (prior != null && prior.body != request.body)
      return error(409, 'WATER_MUTATION_CONFLICT', false);
    if (prior == null) {
      final next = (total + 250).clamp(0, 1000000);
      revision++;
      receipts[mutation] = (
        body: request.body,
        credit: next - total,
        revision: revision,
      );
      total = next;
      writes++;
    }
    final receipt = receipts[mutation]!;
    return http.Response(
      jsonEncode({
        'success': true,
        'operation': 'increment_water',
        'version': 2,
        'healthDay': data['healthDay'],
        'epoch': epoch,
        'revision': revision,
        'waterIntakeMl': total,
        'alreadyApplied': prior != null,
        'effectiveCreditMl': receipt.credit,
        'appliedRevision': receipt.revision,
      }),
      200,
    );
  }
}

http.Response error(int status, String code, bool retryable) => http.Response(
  jsonEncode({
    'error': 'server-secret-never-log',
    'code': code,
    'retryable': retryable,
  }),
  status,
);

void main() {
  late AppDatabase db;
  late sqlite.Database raw;
  late WaterV2LocalStore store;
  late _Auth auth;
  late _Writes writes;
  late _Ledger ledger;
  late List<http.Request> requests;
  late List<bool> refreshes;
  late List<_Client> clients;
  var tokenCalls = 0, appCalls = 0;
  DateTime now() => DateTime.utc(2026, 8, 21, 12);
  WaterV2RemoteDataSource remote({
    Future<http.Response> Function(http.Request)? handler,
    Future<String?> Function(User, bool)? token,
    Future<String?> Function()? app,
  }) => WaterV2RemoteDataSource.enabledForLocalTests(
    auth,
    captureRemoteSend: (owner) =>
        db.localMutations.captureRemoteSend(expectedUid: owner),
    clientFactory: () {
      final client = _Client((request) async {
        requests.add(request);
        return handler == null ? ledger.apply(request) : handler(request);
      });
      clients.add(client);
      return client;
    },
    idTokenProvider: (user, refresh) async {
      tokenCalls++;
      refreshes.add(refresh);
      return token == null ? 'fake-secret-id-token' : token(user, refresh);
    },
    appCheckTokenProvider: () async {
      appCalls++;
      return app == null ? 'fake-secret-app-check' : app();
    },
  );
  WaterV2SyncProcessor processor([WaterV2RemoteDataSource? transport]) =>
      WaterV2SyncProcessor.forLocalTests(db, transport ?? remote(), now: now);
  Future<SyncQueueTableData> seed({
    String id = idA,
    String? origin = epoch,
    int offset = -180,
    String occurred = instant,
  }) async {
    final input = WaterV2IntentInput(
      ownerUid: uid,
      mutationId: id,
      healthDay: day,
      deltaMl: 250,
      occurredAtUtc: occurred,
      timeZoneOffsetMinutes: offset,
      originEpoch: origin,
    );
    late int queueId;
    await db.transaction(() async {
      await store.insertIntent(input);
      queueId = await db.insertSyncItem(
        ownerUid: uid,
        collection: 'water_v2',
        docId: id,
        operationType: 'increment_water',
        createdAt: now().millisecondsSinceEpoch,
        payloadJson: jsonEncode({
          'operation': 'increment_water',
          'version': 2,
          'mutationId': id,
          'healthDay': day,
          'deltaMl': 250,
          'occurredAt': occurred,
          'timeZoneOffsetMinutes': offset,
        }),
      );
      await (db.update(db.waterV2Intents)
            ..where((t) => t.ownerUid.equals(uid) & t.mutationId.equals(id)))
          .write(WaterV2IntentsCompanion(syncQueueId: Value(queueId)));
      final previous = await db.select(db.healthEntries).getSingle();
      await db
          .update(db.healthEntries)
          .write(
            HealthEntriesCompanion(
              waterIntakeMl: Value(
                (previous.waterIntakeMl + 250).clamp(0, 1000000),
              ),
            ),
          );
    });
    return await db.getSyncItemById(queueId) as SyncQueueTableData;
  }

  Map<String, List<Map<String, Object?>>> snapshot() => {
    for (final table in [
      'water_v2_daily_states',
      'water_v2_intents',
      'sync_queue_table',
      'health_entries',
    ])
      table: [
        for (final row in raw.select('SELECT * FROM "$table" ORDER BY rowid'))
          Map<String, Object?>.from(row),
      ],
  };
  void pending(
    SyncQueueTableData item, {
    int total = 1000,
    int projection = 1250,
  }) {
    expect(
      raw.select('SELECT status FROM sync_queue_table WHERE id = ?', [
        item.id,
      ]).single['status'],
      'pending',
    );
    expect(
      raw.select(
        'SELECT local_status FROM water_v2_intents WHERE mutation_id = ?',
        [item.docId],
      ).single['local_status'],
      isNot('receipt_confirmed'),
    );
    expect(
      raw
          .select('SELECT confirmed_water_intake_ml FROM water_v2_daily_states')
          .single['confirmed_water_intake_ml'],
      total,
    );
    expect(
      raw
          .select('SELECT water_intake_ml FROM health_entries')
          .single['water_intake_ml'],
      projection,
    );
  }

  Future<(WaterV2IncrementSuccess, RemoteSendPermit)> preparedProof(
    SyncQueueTableData item,
  ) async {
    final permit = db.localMutations.captureRemoteSend(expectedUid: uid);
    final request = (await store.prepareIncrement(
      uid,
      item,
      admission: db.localMutations.capture(expectedUid: uid),
      permit: permit,
    ))!;
    final response = ledger.apply(
      http.Request('POST', Uri.https('fake.invalid'))
        ..body = jsonEncode(request.toJson()),
    );
    return (
      WaterV2IncrementSuccess.parse(response.body, request, permit: permit),
      permit,
    );
  }

  setUp(() async {
    raw = sqlite.sqlite3.openInMemory();
    writes = _Writes();
    db = AppDatabase(
      executor: NativeDatabase.opened(
        raw,
        closeUnderlyingOnClose: false,
      ).interceptWith(writes),
    );
    await db.select(db.waterV2Intents).get();
    auth = _Auth();
    db.localMutations.bindSessionReader(() => auth.uid);
    db.localMutations.openPreparedSession();
    store = WaterV2LocalStore(db);
    await store.persistConfirmedState(
      ownerUid: uid,
      healthDay: day,
      epoch: epoch,
      revision: 0,
      confirmedWaterIntakeMl: 1000,
      reconciledAtUtc: instant,
    );
    await db
        .into(db.healthEntries)
        .insert(
          HealthEntriesCompanion.insert(
            docId: day,
            date: now(),
            waterIntakeMl: const Value(1000),
            mood: const Value('bem'),
            hasTakenPillToday: const Value(true),
            menstrualCycleJson: const Value(
              ' {"cycleLength":28,"nota":"á"} \r\n',
            ),
          ),
        );
    ledger = _Ledger();
    requests = [];
    clients = [];
    refreshes = [];
    tokenCalls = 0;
    appCalls = 0;
  });
  tearDown(() async {
    await db.close();
    raw.dispose();
  });

  test(
    'exact immutable payload, approved HTTPS, no redirects, typed success and one atomic ACK',
    () async {
      final item = await seed();
      final before = await db.select(db.healthEntries).getSingle();
      final result = await processor().process(uid, item, canSend: () => true);
      expect(result.isSuccess, isTrue);
      expect(
        requests.single.url.toString(),
        'https://life-os-backend-gray.vercel.app/api/sync',
      );
      expect(requests.single.followRedirects, isFalse);
      expect(jsonDecode(requests.single.body), jsonDecode(item.payloadJson));
      expect(jsonDecode(requests.single.body), isNot(contains('epoch')));
      expect(
        requests.single.headers['Authorization'],
        'Bearer fake-secret-id-token',
      );
      expect(
        requests.single.headers['X-Firebase-AppCheck'],
        'fake-secret-app-check',
      );
      final intent = await db.select(db.waterV2Intents).getSingle();
      expect(intent.mutationId, idA);
      expect(intent.occurredAtUtc, instant);
      expect(intent.timeZoneOffsetMinutes, -180);
      expect(intent.localStatus, 'receipt_confirmed');
      expect(intent.originEpoch, epoch);
      final q = await db.getSyncItemById(item.id) as SyncQueueTableData;
      expect(q.status, 'succeeded');
      expect(q.isSynced, isTrue);
      expect(q.attemptCount, 1);
      final state = await db.select(db.waterV2DailyStates).getSingle();
      expect(state.revision, 1);
      expect(state.confirmedWaterIntakeMl, 1250);
      expect(await db.select(db.healthEntries).getSingle(), before);
    },
  );
  test('default transport disabled: zero tokens, HTTP and local ACK', () async {
    final item = await seed();
    final before = snapshot();
    final transport = WaterV2RemoteDataSource(
      auth,
      captureRemoteSend: (u) =>
          db.localMutations.captureRemoteSend(expectedUid: u),
    );
    expect(
      (await processor(transport).process(uid, item, canSend: () => true)).code,
      'WATER_V2_DISABLED',
    );
    expect(snapshot(), before);
    expect(requests, isEmpty);
    expect(tokenCalls, 0);
  });
  test(
    'default manager quarantines explicit V2 without generic remote calls',
    () async {
      final item = await seed();
      final other = _OtherRemote();
      final queue = _Queue(db);
      final manager = SyncManager(
        queueStore: queue,
        remoteDataSource: other,
        currentUserId: () => auth.uid,
      );
      addTearDown(manager.dispose);
      expect(await manager.processPendingItems(), isFalse);
      expect(other.calls, 0);
      expect(queue.genericAcks, 0);
      expect(requests, isEmpty);
      pending(item);
    },
  );
  test(
    'generic Firestore data source refuses Water V2 even disguised as update',
    () async {
      final item = await seed();
      final firestore = _Firestore();
      final ds = FirestoreSyncRemoteDataSource(
        firestore,
        auth,
        clientFactory: () => throw StateError('NO_HTTP'),
      );
      for (final row in [
        item,
        item.copyWith(operationType: 'update'),
        item.copyWith(collection: 'health_info'),
      ]) {
        expect((await ds.process(uid, row)).code, 'WATER_V2_DISABLED');
      }
      expect(firestore.calls, 0);
      pending(item);
    },
  );
  for (final code in ['AUTHENTICATION_REQUIRED', 'APP_CHECK_REQUIRED']) {
    test('$code missing token fails closed before HTTP', () async {
      final item = await seed();
      final transport = remote(
        token: (_, _) async =>
            code == 'AUTHENTICATION_REQUIRED' ? null : 'fake',
        app: () async => code == 'APP_CHECK_REQUIRED' ? null : 'fake',
      );
      expect(
        (await processor(
          transport,
        ).process(uid, item, canSend: () => true)).code,
        code,
      );
      expect(requests, isEmpty);
      expect(clients, isEmpty);
      pending(item);
    });
  }
  test('UID changed before send never creates client or token', () async {
    final item = await seed();
    auth.uid = 'other-uid';
    expect(
      (await processor().process(uid, item, canSend: () => true)).code,
      'SESSION_STOPPED',
    );
    expect(tokenCalls, 0);
    expect(requests, isEmpty);
    pending(item);
  });
  for (final duringApp in [false, true]) {
    test(
      'logout aborted during ${duringApp ? 'App Check' : 'ID token'} never revives old permit',
      () async {
        final item = await seed();
        final reached = Completer<void>();
        final release = Completer<String?>();
        final transport = remote(
          token: (_, _) {
            if (!duringApp) {
              reached.complete();
              return release.future;
            }
            return Future.value('fake');
          },
          app: () {
            if (duringApp) {
              reached.complete();
              return release.future;
            }
            return Future.value('fake');
          },
        );
        final oldPermit = transport.capturePermit(uid, () => true);
        final operation = processor(
          transport,
        ).process(uid, item, canSend: () => true);
        await reached.future;
        final q = db.localMutations.beginQuiesce(uid);
        await q.drain();
        q.finish(signOutConfirmed: false);
        release.complete('fake');
        expect((await operation).code, 'SESSION_STOPPED');
        expect(oldPermit.isCurrent, isFalse);
        expect(requests, isEmpty);
        pending(item);
        expect(
          (await processor().process(uid, item, canSend: () => true)).isSuccess,
          isTrue,
        );
        expect(ledger.writes, 1);
      },
    );
  }
  for (final change in ['uid', 'logout', 'a-b-a']) {
    test(
      '$change during HTTP prevents late ACK; explicit relogin retry keeps UUID',
      () async {
        final item = await seed();
        final reached = Completer<void>();
        final release = Completer<void>();
        final transport = remote(
          handler: (request) async {
            final response = ledger.apply(request);
            reached.complete();
            await release.future;
            return response;
          },
        );
        final operation = processor(
          transport,
        ).process(uid, item, canSend: () => true);
        await reached.future;
        if (change == 'logout') {
          final q = db.localMutations.beginQuiesce(uid);
          await q.drain();
          q.finish(signOutConfirmed: true);
        } else {
          auth.uid = 'other-uid';
          db.localMutations.observeSession(auth.uid);
          if (change == 'a-b-a') {
            auth.uid = uid;
            db.localMutations.observeSession(uid);
            db.localMutations.openPreparedSession();
          }
        }
        release.complete();
        expect((await operation).code, 'SESSION_STOPPED');
        pending(item);
        auth.uid = uid;
        db.localMutations.observeSession(uid);
        db.localMutations.openPreparedSession();
        expect(
          (await processor().process(uid, item, canSend: () => true)).isSuccess,
          isTrue,
        );
        expect(requests, hasLength(2));
        expect(requests[0].body, requests[1].body);
        expect(ledger.total, 1250);
        expect(ledger.writes, 1);
      },
    );
  }
  test(
    'lost response after remote commit replays exactly once with preserved timestamp/offset',
    () async {
      final item = await seed();
      var lost = true;
      final transport = remote(
        handler: (request) async {
          final response = ledger.apply(request);
          if (lost) throw http.ClientException('SECRET_TOKEN_PAYLOAD');
          return response;
        },
      );
      final p = processor(transport);
      expect(
        (await p.process(uid, item, canSend: () => true)).code,
        'NETWORK_ERROR',
      );
      pending(item);
      lost = false;
      expect(
        (await p.process(uid, item, canSend: () => true)).isSuccess,
        isTrue,
      );
      expect(requests[0].body, requests[1].body);
      expect(ledger.writes, 1);
      expect(ledger.total, 1250);
    },
  );
  for (final entry in <(int, String, bool, bool)>[
    (503, 'WATER_V2_DISABLED', true, true),
    (409, 'WATER_INVALID_REMOTE_STATE', true, true),
    (409, 'WATER_SNAPSHOT_MISMATCH', true, true),
    (409, 'WATER_MUTATION_CONFLICT', false, false),
    (403, 'WATER_ACCOUNT_DELETING', false, false),
    (400, 'WATER_INVALID_PAYLOAD', false, false),
  ]) {
    test('typed error ${entry.$2}: retryability and no ACK', () async {
      final item = await seed();
      final result = await processor(
        remote(handler: (_) async => error(entry.$1, entry.$2, entry.$3)),
      ).process(uid, item, canSend: () => true);
      expect(result.code, entry.$2);
      expect(result.shouldRetry, entry.$4);
      pending(item);
    });
  }
  test(
    '401 refreshes once under original permit and exact original body',
    () async {
      final item = await seed();
      final transport = remote(
        handler: (r) async => requests.length == 1
            ? error(401, 'AUTHENTICATION_REQUIRED', true)
            : ledger.apply(r),
      );
      expect(
        (await processor(
          transport,
        ).process(uid, item, canSend: () => true)).isSuccess,
        isTrue,
      );
      expect(refreshes, [false, true]);
      expect(appCalls, 1);
      expect(requests[0].body, requests[1].body);
    },
  );
  test(
    'App Check 401 does not refresh ID token or authorize another POST',
    () async {
      final item = await seed();
      expect(
        (await processor(
          remote(handler: (_) async => error(401, 'APP_CHECK_INVALID', true)),
        ).process(uid, item, canSend: () => true)).shouldRetry,
        isTrue,
      );
      expect(requests, hasLength(1));
      expect(refreshes, [false]);
      pending(item);
    },
  );
  test('UID changes during 401 refresh prevents a second POST', () async {
    final item = await seed();
    final transport = remote(
      handler: (_) async => error(401, 'AUTHENTICATION_REQUIRED', true),
      token: (_, refresh) async {
        if (refresh) {
          auth.uid = 'other';
          db.localMutations.observeSession('other');
        }
        return 'fake';
      },
    );
    expect(
      (await processor(transport).process(uid, item, canSend: () => true)).code,
      'SESSION_STOPPED',
    );
    expect(requests, hasLength(1));
    pending(item);
  });
  test(
    'two concurrent operations serialize HTTP and ACK without duplicate projection',
    () async {
      final a = await seed();
      final b = await seed(id: idB);
      final reached = Completer<void>();
      final release = Completer<void>();
      final p = processor(
        remote(
          handler: (r) async {
            if (requests.length == 1) {
              reached.complete();
              await release.future;
            }
            return ledger.apply(r);
          },
        ),
      );
      final first = p.process(uid, a, canSend: () => true);
      await reached.future;
      final second = p.process(uid, b, canSend: () => true);
      expect(requests, hasLength(1));
      release.complete();
      expect((await first).isSuccess, isTrue);
      expect((await second).isSuccess, isTrue);
      expect(ledger.total, 1500);
      expect(ledger.writes, 2);
      expect(
        (await db.select(db.healthEntries).getSingle()).waterIntakeMl,
        1500,
      );
      expect(
        (await db.select(db.waterV2Intents).get()).every(
          (r) => r.localStatus == 'receipt_confirmed',
        ),
        isTrue,
      );
    },
  );
  test(
    'concurrent duplicate operation makes one POST and one queue ACK',
    () async {
      final a = await seed();
      final p = processor();
      final results = await Future.wait([
        p.process(uid, a, canSend: () => true),
        p.process(uid, a, canSend: () => true),
      ]);
      expect(results.every((r) => r.isSuccess), isTrue);
      expect(requests, hasLength(1));
      expect(ledger.writes, 1);
      expect(
        (await db.getSyncItemById(a.id) as SyncQueueTableData).attemptCount,
        1,
      );
    },
  );
  test(
    'duplicate direct ACK is idempotent and does not rewrite later local projection',
    () async {
      final a = await seed();
      final (proof, permit) = await preparedProof(a);
      final ticket = db.localMutations.capture(expectedUid: uid);
      await store.acknowledgeIncrement(
        proof,
        admission: ticket,
        permit: permit,
        observedAtUtc: instant,
      );
      await seed(id: idB);
      final before = snapshot();
      await store.acknowledgeIncrement(
        proof,
        admission: ticket,
        permit: permit,
        observedAtUtc: instant,
      );
      expect(snapshot(), before);
    },
  );
  test(
    'newer local intention during old HTTP survives ACK; other health fields stay byte-identical',
    () async {
      final a = await seed();
      final before = await db.select(db.healthEntries).getSingle();
      final reached = Completer<void>();
      final release = Completer<void>();
      final p = processor(
        remote(
          handler: (r) async {
            final response = ledger.apply(r);
            reached.complete();
            await release.future;
            return response;
          },
        ),
      );
      final first = p.process(uid, a, canSend: () => true);
      await reached.future;
      final b = await seed(id: idB);
      release.complete();
      expect((await first).isSuccess, isTrue);
      final after = await db.select(db.healthEntries).getSingle();
      expect(after.waterIntakeMl, 1500);
      expect(after.mood, before.mood);
      expect(after.hasTakenPillToday, before.hasTakenPillToday);
      expect(after.menstrualCycleJson, before.menstrualCycleJson);
      expect(after.date, before.date);
      expect(
        (await db.getSyncItemById(b.id) as SyncQueueTableData).status,
        'pending',
      );
      expect(
        (db.select(db.waterV2Intents)..where((t) => t.mutationId.equals(idB)))
            .getSingle()
            .then((r) => r.localStatus),
        completion('not_sent'),
      );
    },
  );
  test(
    'remote snapshot older than local confirmed revision cannot ACK or revert projection',
    () async {
      final a = await seed();
      final (proof, permit) = await preparedProof(a);
      await store.persistConfirmedState(
        ownerUid: uid,
        healthDay: day,
        epoch: epoch,
        revision: 2,
        confirmedWaterIntakeMl: 1500,
        reconciledAtUtc: instant,
      );
      final before = snapshot();
      await expectLater(
        store.acknowledgeIncrement(
          proof,
          admission: db.localMutations.capture(expectedUid: uid),
          permit: permit,
          observedAtUtc: instant,
        ),
        throwsStateError,
      );
      expect(snapshot(), before);
    },
  );
  for (final mid in [true, false]) {
    test(
      'SQLite ${mid ? 'middle write' : 'commit'} failure rolls back every ACK write',
      () async {
        final a = await seed();
        final (proof, permit) = await preparedProof(a);
        final before = snapshot();
        writes.failQueue = mid;
        writes.failCommit = !mid;
        await expectLater(
          store.acknowledgeIncrement(
            proof,
            admission: db.localMutations.capture(expectedUid: uid),
            permit: permit,
            observedAtUtc: instant,
          ),
          throwsStateError,
        );
        expect(snapshot(), before);
        writes.failQueue = false;
        writes.failCommit = false;
        await store.acknowledgeIncrement(
          proof,
          admission: db.localMutations.capture(expectedUid: uid),
          permit: permit,
          observedAtUtc: instant,
        );
        expect(
          (await db.getSyncItemById(a.id) as SyncQueueTableData).status,
          'succeeded',
        );
      },
    );
  }
  test(
    'quiescence after last projection SQL but before commit rolls back entire ACK',
    () async {
      final a = await seed();
      final (proof, permit) = await preparedProof(a);
      final before = snapshot();
      final reached = Completer<void>();
      final release = Completer<void>();
      writes.afterProjection = () async {
        reached.complete();
        await release.future;
      };
      final ticket = db.localMutations.capture(expectedUid: uid);
      final ack = store.acknowledgeIncrement(
        proof,
        admission: ticket,
        permit: permit,
        observedAtUtc: instant,
      );
      final checked = expectLater(ack, throwsA(isA<RemoteSessionStopped>()));
      await reached.future;
      final q = db.localMutations.beginQuiesce(uid);
      release.complete();
      await checked;
      await q.drain();
      q.finish(signOutConfirmed: false);
      expect(snapshot(), before);
      expect(permit.isCurrent, isFalse);
    },
  );
  test(
    'uncertain other intent refuses whole ACK instead of double credit or UUID-only reconcile',
    () async {
      final a = await seed();
      final b = await seed(id: idB);
      final permit = db.localMutations.captureRemoteSend(expectedUid: uid);
      final ticket = db.localMutations.capture(expectedUid: uid);
      await store.prepareIncrement(uid, a, admission: ticket, permit: permit);
      final (proof, bPermit) = await preparedProof(b);
      final before = snapshot();
      await expectLater(
        store.acknowledgeIncrement(
          proof,
          admission: ticket,
          permit: bPermit,
          observedAtUtc: instant,
        ),
        throwsStateError,
      );
      expect(snapshot(), before);
      pending(a, projection: 1500);
      pending(b, projection: 1500);
    },
  );
  test(
    'no trusted origin epoch quarantines intention without HTTP or adoption',
    () async {
      final a = await seed(origin: null);
      expect(
        (await processor().process(uid, a, canSend: () => true)).code,
        'WATER_ORIGIN_REQUIRED',
      );
      expect(requests, isEmpty);
      pending(a);
      expect(
        (await db.select(db.waterV2Intents).getSingle()).originEpoch,
        isNull,
      );
    },
  );
  test(
    'zero-credit receipt at cap still ACKs exactly once and preserves fields',
    () async {
      await store.persistConfirmedState(
        ownerUid: uid,
        healthDay: day,
        epoch: epoch,
        revision: 1,
        confirmedWaterIntakeMl: 1000000,
        reconciledAtUtc: instant,
      );
      await db
          .update(db.healthEntries)
          .write(const HealthEntriesCompanion(waterIntakeMl: Value(1000000)));
      ledger.total = 1000000;
      ledger.revision = 1;
      final a = await seed();
      expect(
        (await processor().process(uid, a, canSend: () => true)).isSuccess,
        isTrue,
      );
      expect(ledger.receipts[idA]!.credit, 0);
      expect(
        (await db.select(db.healthEntries).getSingle()).waterIntakeMl,
        1000000,
      );
      expect((await db.select(db.waterV2DailyStates).getSingle()).revision, 2);
    },
  );
  test(
    'manager Water path never invokes generic ACK; two operations of the same day retain FIFO',
    () async {
      await seed();
      await seed(id: idB);
      final queue = _Queue(db);
      final other = _OtherRemote();
      final manager = SyncManager(
        queueStore: queue,
        remoteDataSource: other,
        currentUserId: () => auth.uid,
        waterV2Processor: processor(),
      );
      addTearDown(manager.dispose);
      expect(await manager.processPendingItems(), isTrue);
      expect(queue.genericAcks, 0);
      expect(other.calls, 0);
      expect(requests.map((r) => jsonDecode(r.body)['mutationId']), [idA, idB]);
      expect(ledger.total, 1500);
    },
  );
  test(
    'manager detach ends promptly and late HTTP cannot mark Water success',
    () async {
      final a = await seed();
      final reached = Completer<void>();
      final release = Completer<void>();
      final p = processor(
        remote(
          handler: (r) async {
            final response = ledger.apply(r);
            reached.complete();
            await release.future;
            return response;
          },
        ),
      );
      final queue = _Queue(db);
      final manager = SyncManager(
        queueStore: queue,
        remoteDataSource: _OtherRemote(),
        currentUserId: () => auth.uid,
        waterV2Processor: p,
      );
      addTearDown(manager.dispose);
      final drain = manager.processPendingItems();
      await reached.future;
      expect(await manager.prepareForSessionDetach(uid), isTrue);
      expect(await drain, isFalse);
      release.complete();
      // Joining the processor's lane observes the late request and then fails
      // closed under a stopped generation; no timing sleeps are needed.
      var canContinue = true;
      final joined = p.process(uid, a, canSend: () => canContinue);
      canContinue = false;
      expect((await joined).code, 'SESSION_STOPPED');
      pending(a);
      expect(queue.genericAcks, 0);
    },
  );
  test(
    'legacy absolute operation remains V1 and is never converted into an intent',
    () async {
      final id = await db.insertSyncItem(
        ownerUid: uid,
        collection: 'health_info',
        docId: day,
        operationType: 'update',
        payloadJson: ' {"waterIntakeMl":1250} ',
      );
      final original = await db.getSyncItemById(id) as SyncQueueTableData;
      final other = _OtherRemote();
      final manager = SyncManager(
        queueStore: _Queue(db),
        remoteDataSource: other,
        currentUserId: () => auth.uid,
        waterV2Processor: processor(),
      );
      addTearDown(manager.dispose);
      expect(await manager.processPendingItems(), isTrue);
      expect(other.calls, 1);
      expect(requests, isEmpty);
      expect(await db.select(db.waterV2Intents).get(), isEmpty);
      expect(
        (await db.getSyncItemById(id) as SyncQueueTableData).payloadJson,
        original.payloadJson,
      );
    },
  );
  test(
    'errors and manager logs never contain payload, UID or token secrets',
    () async {
      await seed();
      final logs = <String>[];
      void listen(OutputEvent event) => logs.addAll(event.lines);
      Logger.addOutputListener(listen);
      addTearDown(() => Logger.removeOutputListener(listen));
      final transport = remote(
        handler: (_) async => http.Response(
          '{"code":"fake-secret-id-token","error":"$uid $instant","retryable":false}',
          409,
        ),
      );
      final manager = SyncManager(
        queueStore: _Queue(db),
        remoteDataSource: _OtherRemote(),
        currentUserId: () => auth.uid,
        waterV2Processor: processor(transport),
      );
      addTearDown(manager.dispose);
      expect(await manager.processPendingItems(), isFalse);
      final queue = await db.select(db.syncQueueTable).getSingle();
      expect(queue.lastErrorCode, 'WATER_HTTP_409');
      expect(
        logs.join(),
        isNot(matches('fake-secret|$uid|$instant|$idA|waterIntakeMl')),
      );
    },
  );
  for (final change in <String, Object?>{
    'version': 2.0,
    'epoch': epochB,
    'revision': 0,
    'waterIntakeMl': 1000001,
    'effectiveCreditMl': 251,
    'appliedRevision': 2,
    'healthDay': '2026-08-22',
    'alreadyApplied': 'false',
    'extra': true,
  }.entries) {
    test('malformed ${change.key} success cannot ACK', () async {
      final a = await seed();
      final transport = remote(
        handler: (r) async {
          final response = ledger.apply(r);
          final data = jsonDecode(response.body) as Map<String, dynamic>;
          data[change.key] = change.value;
          return http.Response(jsonEncode(data), 200);
        },
      );
      expect(
        (await processor(transport).process(uid, a, canSend: () => true)).code,
        'WATER_INVALID_RESPONSE',
      );
      pending(a);
    });
  }
  for (final body in ['{}', '[]', '{"success":true}', 'not-json']) {
    test('generic 200 $body is no proof', () async {
      final a = await seed();
      expect(
        (await processor(
          remote(handler: (_) async => http.Response(body, 200)),
        ).process(uid, a, canSend: () => true)).code,
        'WATER_INVALID_RESPONSE',
      );
      pending(a);
    });
  }
  test(
    'typed reconcile preserves all membership data but performs no ACK or base/projection update',
    () async {
      final a = await seed();
      final before = snapshot();
      final req = WaterV2ReconcileRequest(
        ownerUid: uid,
        healthDay: day,
        expectedEpoch: epoch,
        expectedRevision: 1,
        pendingMutationIds: [idA, idB],
      );
      final transport = remote(
        handler: (r) async => http.Response(
          jsonEncode({
            'success': true,
            'operation': 'reconcile_water',
            'version': 2,
            'healthDay': day,
            'epoch': epoch,
            'revision': 1,
            'waterIntakeMl': 1250,
            'complete': true,
            'recognized': [
              {
                'mutationId': idA,
                'effectiveCreditMl': 250,
                'appliedRevision': 1,
              },
            ],
            'unrecognizedMutationIds': [idB],
          }),
          200,
        ),
      );
      final result = await transport.reconcile(
        req,
        transport.capturePermit(uid, () => true),
      );
      expect(result.error, isNull);
      expect(result.value!.recognized.single.mutationId, idA);
      expect(result.value!.unrecognizedMutationIds, [idB]);
      expect(snapshot(), before);
      pending(a);
      expect(jsonDecode(requests.single.body), req.toJson());
    },
  );
  for (final defect in [
    'missing',
    'duplicate',
    'foreign',
    'partial',
    'extra',
    'epoch',
    'revision',
  ]) {
    test('reconcile $defect fails closed without ACK', () async {
      await seed();
      final before = snapshot();
      final req = WaterV2ReconcileRequest(
        ownerUid: uid,
        healthDay: day,
        expectedEpoch: epoch,
        expectedRevision: 0,
        pendingMutationIds: [idA],
      );
      final data = <String, dynamic>{
        'success': true,
        'operation': 'reconcile_water',
        'version': 2,
        'healthDay': day,
        'epoch': epoch,
        'revision': 0,
        'waterIntakeMl': 1000,
        'complete': true,
        'recognized': [],
        'unrecognizedMutationIds': [idA],
      };
      switch (defect) {
        case 'missing':
          data['unrecognizedMutationIds'] = [];
        case 'duplicate':
          data['unrecognizedMutationIds'] = [idA, idA];
        case 'foreign':
          data['unrecognizedMutationIds'] = [idC];
        case 'partial':
          data['complete'] = false;
        case 'extra':
          data['fingerprint'] = 'fake';
        case 'epoch':
          data['epoch'] = epochB;
        case 'revision':
          data['revision'] = 1;
      }
      final transport = remote(
        handler: (_) async => http.Response(jsonEncode(data), 200),
      );
      expect(
        (await transport.reconcile(
          req,
          transport.capturePermit(uid, () => true),
        )).error!.code,
        'WATER_INVALID_RESPONSE',
      );
      expect(snapshot(), before);
    });
  }
  test(
    'proof from aborted logout cannot be revived with a newly captured permit',
    () async {
      final a = await seed();
      final (proof, oldPermit) = await preparedProof(a);
      final before = snapshot();
      final q = db.localMutations.beginQuiesce(uid);
      await q.drain();
      q.finish(signOutConfirmed: false);
      final fresh = db.localMutations.captureRemoteSend(expectedUid: uid);
      expect(oldPermit.isCurrent, isFalse);
      expect(fresh.isCurrent, isTrue);
      await expectLater(
        store.acknowledgeIncrement(
          proof,
          admission: db.localMutations.capture(expectedUid: uid),
          permit: fresh,
          observedAtUtc: instant,
        ),
        throwsA(isA<RemoteSessionStopped>()),
      );
      expect(snapshot(), before);
    },
  );
  for (final defect in [
    'owner',
    'payload',
    'docId',
    'link',
    'status',
    'origin',
  ]) {
    test('persisted $defect mismatch blocks HTTP before any send', () async {
      final a = await seed();
      switch (defect) {
        case 'owner':
          await db.customStatement(
            "UPDATE sync_queue_table SET owner_uid = 'other'",
          );
        case 'payload':
          await db.customStatement(
            "UPDATE sync_queue_table SET payload_json = '{\"operation\":\"increment_water\"}'",
          );
        case 'docId':
          await db.customStatement('UPDATE sync_queue_table SET doc_id = ?', [
            idB,
          ]);
        case 'link':
          await db.customStatement(
            'UPDATE water_v2_intents SET sync_queue_id = 987',
          );
        case 'status':
          await db.customStatement(
            "UPDATE sync_queue_table SET status = 'succeeded', is_synced = 1",
          );
        case 'origin':
          await db.customStatement(
            'UPDATE water_v2_intents SET origin_epoch = ?',
            [epochB],
          );
      }
      final before = snapshot();
      final result = await processor().process(uid, a, canSend: () => true);
      expect(result.shouldRetry, isTrue);
      expect(requests, isEmpty);
      expect(snapshot(), before);
    });
  }
  for (final mutateQueue in [false, true]) {
    test(
      'immutable ${mutateQueue ? 'queue' : 'intent'} changed during HTTP cannot ACK',
      () async {
        final a = await seed();
        final transport = remote(
          handler: (r) async {
            final response = ledger.apply(r);
            if (mutateQueue)
              await db.customStatement(
                "UPDATE sync_queue_table SET payload_json = '{}'",
              );
            else
              await db.customStatement(
                'UPDATE water_v2_intents SET occurred_at_utc = ?',
                ['2026-08-21T11:00:00.123Z'],
              );
            return response;
          },
        );
        expect(
          (await processor(
            transport,
          ).process(uid, a, canSend: () => true)).shouldRetry,
          isTrue,
        );
        pending(a);
      },
    );
  }
  test('another owner cannot receive or ACK this operation', () async {
    final a = await seed();
    auth.uid = 'owner-b';
    db.localMutations.observeSession(auth.uid);
    db.localMutations.openPreparedSession();
    final before = snapshot();
    expect(
      (await processor().process(
        'owner-b',
        a,
        canSend: () => true,
      )).shouldRetry,
      isTrue,
    );
    expect(requests, isEmpty);
    expect(snapshot(), before);
  });
  test(
    'queued concurrent operation retains original generation across aborted logout',
    () async {
      final a = await seed();
      final b = await seed(id: idB);
      final reached = Completer<void>();
      final release = Completer<void>();
      final p = processor(
        remote(
          handler: (r) async {
            final response = ledger.apply(r);
            reached.complete();
            await release.future;
            return response;
          },
        ),
      );
      final first = p.process(uid, a, canSend: () => true);
      await reached.future;
      final second = p.process(uid, b, canSend: () => true);
      final q = db.localMutations.beginQuiesce(uid);
      await q.drain();
      q.finish(signOutConfirmed: false);
      release.complete();
      expect((await first).code, 'SESSION_STOPPED');
      expect((await second).code, 'SESSION_STOPPED');
      expect(requests, hasLength(1));
      pending(a, projection: 1500);
      pending(b, projection: 1500);
      // A new explicit action can replay A's original UUID, then process B FIFO.
      final current = processor();
      expect(
        (await current.process(uid, a, canSend: () => true)).isSuccess,
        isTrue,
      );
      expect(
        (await current.process(uid, b, canSend: () => true)).isSuccess,
        isTrue,
      );
      expect(ledger.total, 1500);
      expect(ledger.writes, 2);
    },
  );
  test(
    'second 401 stays pending with two attempts maximum and closes all clients',
    () async {
      final a = await seed();
      expect(
        (await processor(
          remote(
            handler: (_) async => error(401, 'AUTHENTICATION_REQUIRED', true),
          ),
        ).process(uid, a, canSend: () => true)).code,
        'AUTHENTICATION_REQUIRED',
      );
      expect(requests, hasLength(2));
      expect(refreshes, [false, true]);
      expect(clients.every((c) => c.closed), isTrue);
      pending(a);
    },
  );
  test(
    'redirect response is not followed, is not an ACK, and closes client',
    () async {
      final a = await seed();
      final result = await processor(
        remote(
          handler: (_) async => http.Response(
            '',
            302,
            headers: {'location': 'https://unapproved.invalid'},
          ),
        ),
      ).process(uid, a, canSend: () => true);
      expect(result.shouldRetry, isTrue);
      expect(requests, hasLength(1));
      expect(requests.single.followRedirects, isFalse);
      expect(clients.single.closed, isTrue);
      pending(a);
    },
  );
  test(
    'lost response before commit retries without inventing a new intention',
    () async {
      final a = await seed();
      var fail = true;
      final p = processor(
        remote(
          handler: (r) async {
            if (fail) throw http.ClientException('fake-secret');
            return ledger.apply(r);
          },
        ),
      );
      expect(
        (await p.process(uid, a, canSend: () => true)).code,
        'NETWORK_ERROR',
      );
      pending(a);
      expect(ledger.writes, 0);
      fail = false;
      expect((await p.process(uid, a, canSend: () => true)).isSuccess, isTrue);
      expect(ledger.writes, 1);
      expect(requests[0].body, requests[1].body);
    },
  );
  test(
    'timeout is deterministic with a zero-duration deadline and unresolved fake HTTP',
    () async {
      final a = await seed();
      final pendingResponse = Completer<http.Response>();
      final client = _Client((r) {
        requests.add(r);
        return pendingResponse.future;
      });
      final transport = WaterV2RemoteDataSource.enabledForLocalTests(
        auth,
        captureRemoteSend: (u) =>
            db.localMutations.captureRemoteSend(expectedUid: u),
        clientFactory: () => client,
        idTokenProvider: (_, _) async => 'fake',
        appCheckTokenProvider: () async => 'fake',
        requestTimeout: Duration.zero,
      );
      expect(
        (await processor(transport).process(uid, a, canSend: () => true)).code,
        'SYNC_TIMEOUT',
      );
      expect(client.closed, isTrue);
      pending(a);
      pendingResponse.complete(http.Response('{}', 200));
    },
  );
  test('token exceptions produce no sensitive result, log or HTTP', () async {
    final a = await seed();
    final result = await processor(
      remote(
        token: (_, _) async =>
            throw StateError('fake-secret-id-token $uid $instant'),
      ),
    ).process(uid, a, canSend: () => true);
    expect(result.code, 'WATER_REMOTE_FAILED');
    expect(result.message, isNull);
    expect(requests, isEmpty);
    pending(a);
  });
  test('App Check exceptions produce no sensitive result or HTTP', () async {
    final a = await seed();
    final result = await processor(
      remote(app: () async => throw StateError('fake-secret-app-check $uid')),
    ).process(uid, a, canSend: () => true);
    expect(result.code, 'APP_CHECK_REQUIRED');
    expect(result.message, isNull);
    expect(requests, isEmpty);
    pending(a);
  });
  test('201 generic success is not an increment proof', () async {
    final a = await seed();
    expect(
      (await processor(
        remote(handler: (_) async => http.Response('{}', 201)),
      ).process(uid, a, canSend: () => true)).shouldRetry,
      isTrue,
    );
    pending(a);
  });
  test(
    'SQLite failure through manager recovers with idempotent replay and never calls generic ACK',
    () async {
      final a = await seed();
      // A recent succeeded V1 absolute write must survive both Water attempts.
      final legacyId = await db.insertSyncItem(
        ownerUid: uid,
        collection: 'health',
        docId: '2026-08-20',
        operationType: 'update',
        payloadJson: '{"waterIntakeMl":750,"mood":"bem"}',
      );
      await db.markSyncItemAsSucceeded(legacyId, uid);
      final legacyBefore = await db.getSyncItemById(legacyId);
      final healthBefore = await db.select(db.healthEntries).getSingle();
      final admission = db.localMutations.captureRemoteSend(expectedUid: uid);
      final responses = <Map<String, dynamic>>[];
      late Map<String, List<Map<String, Object?>>> beforeFailedAck;
      final queue = _Queue(db);
      final otherRemote = _OtherRemote();
      final p = processor(
        remote(
          handler: (r) async {
            final response = ledger.apply(r);
            responses.add(jsonDecode(response.body) as Map<String, dynamic>);
            // Inject only the first ACK commit; replay must be able to recover.
            if (requests.length == 1) {
              beforeFailedAck = snapshot();
              writes.failCommit = true;
            }
            return response;
          },
        ),
      );
      final manager = SyncManager(
        queueStore: queue,
        remoteDataSource: otherRemote,
        currentUserId: () => auth.uid,
        waterV2Processor: p,
      );
      addTearDown(manager.dispose);

      expect(await manager.processPendingItems(), isFalse);
      expect(requests, hasLength(1));
      expect(responses.single['alreadyApplied'], isFalse);
      expect(ledger.receipts.keys, [idA]);
      expect(ledger.writes, 1);
      expect(ledger.total, 1250);
      expect(ledger.revision, 1);
      pending(a);
      final afterFailedAck = snapshot();
      for (final table in [
        'water_v2_daily_states',
        'water_v2_intents',
        'health_entries',
      ]) {
        expect(afterFailedAck[table], beforeFailedAck[table], reason: table);
      }
      final failedIntent = await db.select(db.waterV2Intents).getSingle();
      expect(failedIntent.localStatus, 'unreconciled');
      final failedQueue = await db.getSyncItemById(a.id) as SyncQueueTableData;
      expect(failedQueue.isSynced, isFalse);
      expect(failedQueue.attemptCount, 1);
      expect(failedQueue.lastErrorCode, 'WATER_LOCAL_ACK_FAILED');
      final rolledBackState = await db
          .select(db.waterV2DailyStates)
          .getSingle();
      expect(rolledBackState.revision, 0);
      expect(rolledBackState.confirmedWaterIntakeMl, 1000);
      expect(await db.getSyncItemById(legacyId), legacyBefore);
      expect(queue.genericAcks, 0);
      expect(otherRemote.calls, 0);

      writes.failCommit = false;
      // Explicit drain cancels scheduled retry; no clock advance or timer wait.
      expect(admission.isCurrent, isTrue);
      expect(await manager.processPendingItems(), isTrue);
      expect(admission.isCurrent, isTrue);
      expect(auth.uid, uid);
      expect(requests, hasLength(2));
      expect(requests.last.body, requests.first.body);
      expect(jsonDecode(requests.last.body), jsonDecode(a.payloadJson));
      expect(responses.map((r) => r['alreadyApplied']).toList(), [false, true]);
      for (final response in responses) {
        expect(response['epoch'], epoch);
        expect(response['revision'], 1);
        expect(response['appliedRevision'], 1);
        expect(response['waterIntakeMl'], 1250);
        expect(response['effectiveCreditMl'], 250);
      }
      expect(ledger.receipts.keys, [idA]);
      expect(ledger.receipts[idA]!.body, requests.first.body);
      expect(ledger.writes, 1);
      expect(ledger.total, 1250);
      expect(ledger.revision, 1);
      final confirmedIntent = await db.select(db.waterV2Intents).getSingle();
      expect(confirmedIntent.mutationId, failedIntent.mutationId);
      expect(confirmedIntent.ownerUid, failedIntent.ownerUid);
      expect(confirmedIntent.healthDay, failedIntent.healthDay);
      expect(confirmedIntent.deltaMl, failedIntent.deltaMl);
      expect(confirmedIntent.occurredAtUtc, failedIntent.occurredAtUtc);
      expect(
        confirmedIntent.timeZoneOffsetMinutes,
        failedIntent.timeZoneOffsetMinutes,
      );
      expect(confirmedIntent.originEpoch, failedIntent.originEpoch);
      expect(confirmedIntent.syncQueueId, a.id);
      expect(confirmedIntent.localStatus, 'receipt_confirmed');
      final confirmedQueue =
          await db.getSyncItemById(a.id) as SyncQueueTableData;
      expect(confirmedQueue.status, 'succeeded');
      expect(confirmedQueue.isSynced, isTrue);
      expect(confirmedQueue.attemptCount, 2);
      expect(confirmedQueue.lastErrorCode, isNull);
      expect(confirmedQueue.payloadJson, a.payloadJson);
      expect(confirmedQueue.lastAttemptAt, now().millisecondsSinceEpoch);
      final state = await db.select(db.waterV2DailyStates).getSingle();
      expect(state.ownerUid, uid);
      expect(state.epoch, epoch);
      expect(state.healthDay, day);
      expect(state.revision, 1);
      expect(state.confirmedWaterIntakeMl, 1250);
      expect(state.reconciledAtUtc, now().toIso8601String());
      expect(await db.select(db.healthEntries).getSingle(), healthBefore);
      expect(await db.getSyncItemById(legacyId), legacyBefore);
      expect(await db.getPendingSyncItems(uid), isEmpty);
      expect(queue.genericAcks, 0);
      expect(otherRemote.calls, 0);
      expect(clients.every((client) => client.closed), isTrue);
    },
  );
  test(
    'two independently injected processors share the same database FIFO lane',
    () async {
      final a = await seed();
      final b = await seed(id: idB);
      final reached = Completer<void>();
      final release = Completer<void>();
      final p = processor(
        remote(
          handler: (r) async {
            reached.complete();
            await release.future;
            return ledger.apply(r);
          },
        ),
      );
      final first = p.process(uid, a, canSend: () => true);
      await reached.future;
      final second = processor().process(uid, b, canSend: () => true);
      expect(requests, hasLength(1));
      release.complete();
      expect((await first).isSuccess, isTrue);
      expect((await second).isSuccess, isTrue);
      expect(ledger.total, 1500);
      expect(
        (await db.select(db.healthEntries).getSingle()).waterIntakeMl,
        1500,
      );
    },
  );
  test('missing authenticated user prevents all token and HTTP work', () async {
    final a = await seed();
    auth.uid = null;
    expect(
      (await processor().process(uid, a, canSend: () => true)).code,
      'SESSION_STOPPED',
    );
    expect(tokenCalls, 0);
    expect(appCalls, 0);
    expect(requests, isEmpty);
    pending(a);
  });
  test(
    'partial credit at the limit ACKs receipt without losing identity',
    () async {
      await store.persistConfirmedState(
        ownerUid: uid,
        healthDay: day,
        epoch: epoch,
        revision: 1,
        confirmedWaterIntakeMl: 999900,
        reconciledAtUtc: instant,
      );
      await db
          .update(db.healthEntries)
          .write(const HealthEntriesCompanion(waterIntakeMl: Value(999900)));
      ledger.total = 999900;
      ledger.revision = 1;
      final a = await seed();
      expect(
        (await processor().process(uid, a, canSend: () => true)).isSuccess,
        isTrue,
      );
      expect(ledger.receipts[idA]!.credit, 100);
      expect(ledger.writes, 1);
      expect(
        (await db.select(db.healthEntries).getSingle()).waterIntakeMl,
        1000000,
      );
    },
  );
  test(
    'UID change after final SQL rolls back all ACK fields at commit',
    () async {
      final a = await seed();
      final (proof, permit) = await preparedProof(a);
      final before = snapshot();
      final reached = Completer<void>();
      final release = Completer<void>();
      writes.afterProjection = () async {
        reached.complete();
        await release.future;
      };
      final ack = store.acknowledgeIncrement(
        proof,
        admission: db.localMutations.capture(expectedUid: uid),
        permit: permit,
        observedAtUtc: instant,
      );
      final checked = expectLater(
        ack,
        throwsA(
          anyOf(isA<RemoteSessionStopped>(), isA<LocalMutationUnavailable>()),
        ),
      );
      await reached.future;
      auth.uid = 'owner-b';
      db.localMutations.observeSession(auth.uid);
      release.complete();
      await checked;
      expect(snapshot(), before);
    },
  );
  test(
    'malformed terminal server error cannot reject the queue by arbitrary code',
    () async {
      final a = await seed();
      final transport = remote(
        handler: (_) async => http.Response(
          jsonEncode({'code': 'WATER_MUTATION_CONFLICT', 'retryable': false}),
          409,
        ),
      );
      expect(
        (await processor(transport).process(uid, a, canSend: () => true)).code,
        'WATER_HTTP_409',
      );
      pending(a);
    },
  );
  test('no credit below saturation is not a valid direct success', () async {
    final a = await seed();
    final transport = remote(
      handler: (r) async {
        final data = jsonDecode(ledger.apply(r).body) as Map<String, dynamic>;
        data['effectiveCreditMl'] = 0;
        return http.Response(jsonEncode(data), 200);
      },
    );
    expect(
      (await processor(transport).process(uid, a, canSend: () => true)).code,
      'WATER_INVALID_RESPONSE',
    );
    pending(a);
  });
  test(
    'reconcile bounds reject duplicate IDs and more than 100 without HTTP',
    () async {
      for (final ids in [
        [idA, idA],
        List.filled(101, idA),
      ]) {
        expect(
          () => WaterV2ReconcileRequest(
            ownerUid: uid,
            healthDay: day,
            expectedEpoch: epoch,
            expectedRevision: 0,
            pendingMutationIds: ids,
          ),
          throwsFormatException,
        );
      }
      expect(requests, isEmpty);
    },
  );
  test(
    'noncanonical operation spelling is reserved, never routed to generic Firestore or generic ACK',
    () async {
      final a = await seed();
      await db.customStatement(
        "UPDATE sync_queue_table SET collection = 'health_info', operation_type = 'INCREMENT_WATER'",
      );
      final other = _OtherRemote();
      final queue = _Queue(db);
      final manager = SyncManager(
        queueStore: queue,
        remoteDataSource: other,
        currentUserId: () => auth.uid,
      );
      addTearDown(manager.dispose);
      expect(await manager.processPendingItems(), isFalse);
      expect(other.calls, 0);
      expect(queue.genericAcks, 0);
      pending(a);
    },
  );
  test(
    'ACK nested in outer transaction retains remote admission until outer physical commit',
    () async {
      final a = await seed();
      final (proof, permit) = await preparedProof(a);
      final before = snapshot();
      final ticket = db.localMutations.capture(expectedUid: uid);
      final reached = Completer<void>();
      final release = Completer<void>();
      final operation = db.transaction(() async {
        await store.acknowledgeIncrement(
          proof,
          admission: ticket,
          permit: permit,
          observedAtUtc: instant,
        );
        reached.complete();
        await release.future;
      }, admission: ticket);
      final checked = expectLater(
        operation,
        throwsA(isA<RemoteSessionStopped>()),
      );
      await reached.future;
      final q = db.localMutations.beginQuiesce(uid);
      release.complete();
      await checked;
      await q.drain();
      q.finish(signOutConfirmed: false);
      expect(snapshot(), before);
    },
  );
  test(
    'ACK observation clock with microseconds is stored as canonical milliseconds without changing request identity',
    () async {
      final a = await seed();
      final clock = DateTime.utc(2026, 8, 21, 12, 0, 0, 123, 456);
      final p = WaterV2SyncProcessor.forLocalTests(
        db,
        remote(),
        now: () => clock,
      );
      expect((await p.process(uid, a, canSend: () => true)).isSuccess, isTrue);
      final state = await db.select(db.waterV2DailyStates).getSingle();
      expect(state.reconciledAtUtc, '2026-08-21T12:00:00.123Z');
      expect(
        (await db.getSyncItemById(a.id) as SyncQueueTableData).lastAttemptAt,
        clock.millisecondsSinceEpoch,
      );
      expect(jsonDecode(requests.single.body)['occurredAt'], instant);
    },
  );
}
