import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';
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
  String serverEpoch = epoch;
  final receipts = <String, ({String body, int credit, int revision})>{};
  Map<String, dynamic> recognized(String id) {
    final receipt = receipts[id]!;
    final data = jsonDecode(receipt.body) as Map<String, dynamic>;
    return {
      for (final key in [
        'mutationId',
        'healthDay',
        'deltaMl',
        'occurredAt',
        'timeZoneOffsetMinutes',
      ])
        key: data[key],
      'fingerprint': sha256
          .convert(
            utf8.encode(
              jsonEncode([
                2,
                data['mutationId'],
                data['healthDay'],
                data['deltaMl'],
                data['occurredAt'],
                data['timeZoneOffsetMinutes'],
              ]),
            ),
          )
          .toString(),
      'effectiveCreditMl': receipt.credit,
      'appliedRevision': receipt.revision,
    };
  }

  http.Response apply(http.Request request) {
    final data = jsonDecode(request.body) as Map<String, dynamic>;
    if (data['operation'] == 'reconcile_water') {
      if (data['expectedEpoch'] != serverEpoch ||
          (data['expectedRevision'] as int) > revision)
        return error(409, 'WATER_SNAPSHOT_MISMATCH', true);
      final ids = (data['pendingMutationIds'] as List).cast<String>();
      if (ids.any(
        (id) =>
            receipts.containsKey(id) &&
            jsonDecode(receipts[id]!.body)['originEpoch'] != serverEpoch,
      ))
        return error(409, 'WATER_SNAPSHOT_MISMATCH', true);
      return http.Response(
        jsonEncode({
          'success': true,
          'operation': 'reconcile_water',
          'version': 2,
          'healthDay': data['healthDay'],
          'epoch': serverEpoch,
          'revision': revision,
          'waterIntakeMl': total,
          'complete': true,
          'recognized': [
            for (final id in ids)
              if (receipts.containsKey(id)) recognized(id),
          ],
          'unrecognizedMutationIds': [
            for (final id in ids)
              if (!receipts.containsKey(id)) id,
          ],
        }),
        200,
      );
    }
    if (data['originEpoch'] != serverEpoch)
      return error(409, 'WATER_EPOCH_MISMATCH', true);
    final mutation = data['mutationId'] as String;
    final prior = receipts[mutation];
    if (prior != null && jsonDecode(prior.body)['originEpoch'] != serverEpoch)
      return error(409, 'WATER_SNAPSHOT_MISMATCH', true);
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
        'epoch': serverEpoch,
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
          'originEpoch': origin,
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

  Future<void> makeUncertain(
    SyncQueueTableData item, {
    bool applied = true,
  }) async {
    final permit = db.localMutations.captureRemoteSend(expectedUid: uid);
    final request = (await store.prepareIncrement(
      uid,
      item,
      admission: db.localMutations.capture(expectedUid: uid),
      permit: permit,
    ))!;
    if (applied)
      ledger.apply(
        http.Request('POST', Uri.https('fake.invalid'))
          ..body = jsonEncode(request.toJson()),
      );
  }

  Future<
    ({
      WaterV2ReconcilePlan plan,
      WaterV2ReconcileSuccess proof,
      RemoteSendPermit permit,
      LocalMutationTicket ticket,
    })
  >
  reconciliationProof() async {
    final ticket = db.localMutations.capture(expectedUid: uid);
    final permit = db.localMutations.captureRemoteSend(expectedUid: uid);
    final plan = (await store.prepareReconciliation(
      uid,
      day,
      admission: ticket,
      permit: permit,
    ))!;
    final response = ledger.apply(
      http.Request('POST', Uri.https('fake.invalid'))
        ..body = jsonEncode(plan.request.toJson()),
    );
    final proof = WaterV2ReconcileSuccess.parse(
      response.body,
      plan.request,
      permit: permit,
    );
    return (plan: plan, proof: proof, permit: permit, ticket: ticket);
  }

  Future<void> checkConfirmed(
    List<SyncQueueTableData> items, {
    int revision = 2,
    int total = 1500,
  }) async {
    final state = await db.select(db.waterV2DailyStates).getSingle();
    expect(state.epoch, epoch);
    expect(state.revision, revision);
    expect(state.confirmedWaterIntakeMl, total);
    for (final item in items) {
      final row = await (db.select(
        db.waterV2Intents,
      )..where((t) => t.mutationId.equals(item.docId))).getSingle();
      expect(row.localStatus, 'receipt_confirmed');
      expect(row.syncQueueId, item.id);
      expect(
        WaterV2IncrementRequest.fromIntent(row).toJson(),
        jsonDecode(item.payloadJson),
      );
      final queue = await db.getSyncItemById(item.id) as SyncQueueTableData;
      expect(queue.status, 'succeeded');
      expect(queue.isSynced, isTrue);
      expect(queue.payloadJson, item.payloadJson);
      expect(queue.ownerUid, uid);
      expect(queue.lastErrorCode, isNull);
      expect(queue.attemptCount, 1);
    }
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
    'R2CB confirmed intent with pending queue fails closed without confirming any sibling',
    () async {
      final a = await seed();
      final b = await seed(id: idB);
      await makeUncertain(a);
      await makeUncertain(b);
      late Map<String, List<Map<String, Object?>>> before;
      final transport = remote(
        handler: (r) async {
          final response = ledger.apply(r);
          await db.customStatement(
            "UPDATE water_v2_intents SET local_status = 'receipt_confirmed' WHERE mutation_id = ?",
            [idB],
          );
          before = snapshot();
          return response;
        },
      );
      final result = await processor(
        transport,
      ).reconcileDay(uid, day, canSend: () => true);
      expect(result.code, 'WATER_QUEUE_CONFLICT');
      expect(snapshot(), before);
      expect(
        (await db.getSyncItemById(a.id) as SyncQueueTableData).status,
        'pending',
      );
    },
  );

  for (final change in ['uid', 'quiescence', 'generation']) {
    test(
      'R2CB $change after final SQL rolls back every reconciliation ACK component',
      () async {
        final a = await seed();
        final b = await seed(id: idB);
        await makeUncertain(a);
        await makeUncertain(b);
        final before = snapshot();
        final reached = Completer<void>();
        final release = Completer<void>();
        var currentGeneration = 0;
        final captured = currentGeneration;
        writes.afterProjection = () async {
          reached.complete();
          await release.future;
        };
        final operation = processor().reconcileDay(
          uid,
          day,
          canSend: () => currentGeneration == captured,
        );
        await reached.future;
        LocalMutationQuiescence? q;
        if (change == 'uid') {
          auth.uid = 'owner-b';
          db.localMutations.observeSession(auth.uid);
        }
        if (change == 'quiescence') q = db.localMutations.beginQuiesce(uid);
        if (change == 'generation') currentGeneration++;
        release.complete();
        expect((await operation).code, 'SESSION_STOPPED');
        expect(snapshot(), before);
        if (q != null) {
          await q.drain();
          q.finish(signOutConfirmed: false);
        }
        writes.afterProjection = null;
      },
    );
  }
  for (final invalidation in ['SQLite', 'aborted logout']) {
    test(
      'R2CB outer transaction $invalidation rolls back an already completed inner reconcile ACK',
      () async {
        final a = await seed();
        final b = await seed(id: idB);
        await makeUncertain(a);
        await makeUncertain(b);
        final evidence = await reconciliationProof();
        final before = snapshot();
        final reached = Completer<void>();
        final release = Completer<void>();
        final outer = db.transaction(() async {
          await store.acknowledgeReconciliation(
            evidence.proof,
            plan: evidence.plan,
            admission: evidence.ticket,
            permit: evidence.permit,
            observedAtUtc: instant,
          );
          reached.complete();
          await release.future;
        }, admission: evidence.ticket);
        final checked = expectLater(
          outer,
          invalidation == 'SQLite'
              ? throwsStateError
              : throwsA(isA<RemoteSessionStopped>()),
        );
        await reached.future;
        LocalMutationQuiescence? q;
        if (invalidation == 'SQLite')
          writes.failCommit = true;
        else
          q = db.localMutations.beginQuiesce(uid);
        release.complete();
        await checked;
        writes.failCommit = false;
        if (q != null) {
          await q.drain();
          q.finish(signOutConfirmed: false);
        }
        expect(snapshot(), before);
        expect(
          (await processor().reconcileDay(
            uid,
            day,
            canSend: () => true,
          )).isSuccess,
          isTrue,
        );
        await checkConfirmed([a, b]);
        expect(ledger.writes, 2);
      },
    );
  }
  test(
    'R2CB old reconcile proof cannot be revived by a new permit after aborted logout',
    () async {
      final a = await seed();
      await makeUncertain(a);
      final evidence = await reconciliationProof();
      final before = snapshot();
      final q = db.localMutations.beginQuiesce(uid);
      await q.drain();
      q.finish(signOutConfirmed: false);
      final fresh = db.localMutations.captureRemoteSend(expectedUid: uid);
      expect(evidence.permit.isCurrent, isFalse);
      expect(fresh.isCurrent, isTrue);
      await expectLater(
        store.acknowledgeReconciliation(
          evidence.proof,
          plan: evidence.plan,
          admission: db.localMutations.capture(expectedUid: uid),
          permit: fresh,
          observedAtUtc: instant,
        ),
        throwsA(isA<RemoteSessionStopped>()),
      );
      expect(snapshot(), before);
    },
  );
  for (final invalid in [
    'origin',
    'queue',
    'owner',
    'link',
    'status',
    'immutable',
    'deleted',
  ]) {
    test(
      'R2CB persisted $invalid changed during HTTP prevents every sibling confirmation',
      () async {
        final a = await seed();
        final b = await seed(id: idB);
        await makeUncertain(a);
        await makeUncertain(b);
        late Map<String, List<Map<String, Object?>>> before;
        final transport = remote(
          handler: (r) async {
            final response = ledger.apply(r);
            switch (invalid) {
              case 'origin':
                await db.customStatement(
                  'UPDATE water_v2_intents SET origin_epoch = ? WHERE mutation_id = ?',
                  [epochB, idB],
                );
              case 'queue':
                await db.customStatement(
                  "UPDATE sync_queue_table SET payload_json = '{}' WHERE id = ?",
                  [b.id],
                );
              case 'owner':
                await db.customStatement(
                  "UPDATE sync_queue_table SET owner_uid = 'other' WHERE id = ?",
                  [b.id],
                );
              case 'link':
                await db.customStatement(
                  'UPDATE water_v2_intents SET sync_queue_id = ? WHERE mutation_id = ?',
                  [a.id, idB],
                );
              case 'status':
                await db.customStatement(
                  "UPDATE sync_queue_table SET status = 'rejected' WHERE id = ?",
                  [b.id],
                );
              case 'immutable':
                await db.customStatement(
                  'UPDATE water_v2_intents SET occurred_at_utc = ? WHERE mutation_id = ?',
                  ['2026-08-21T11:00:00.123Z', idB],
                );
              case 'deleted':
                await db.customStatement(
                  'DELETE FROM water_v2_intents WHERE mutation_id = ?',
                  [idB],
                );
            }
            before = snapshot();
            return response;
          },
        );
        expect(
          (await processor(
            transport,
          ).reconcileDay(uid, day, canSend: () => true)).shouldRetry,
          isTrue,
        );
        expect(snapshot(), before);
        expect(
          (await db.getSyncItemById(a.id) as SyncQueueTableData).status,
          'pending',
        );
      },
    );
  }
  for (final invalid in [
    'nullOrigin',
    'unknownEpoch',
    'unlinked',
    'legacyPayload',
    'attemptedNotSent',
  ]) {
    test(
      'R2CB $invalid local state stays quarantined without adoption or conversion',
      () async {
        final a = await seed(origin: invalid == 'nullOrigin' ? null : epoch);
        switch (invalid) {
          case 'unknownEpoch':
            await db.customStatement(
              'UPDATE water_v2_intents SET origin_epoch = ?',
              [epochB],
            );
          case 'unlinked':
            await db.customStatement(
              'UPDATE water_v2_intents SET sync_queue_id = NULL',
            );
          case 'legacyPayload':
            await db.customStatement(
              "UPDATE sync_queue_table SET payload_json = '{\"waterIntakeMl\":1250}'",
            );
          case 'attemptedNotSent':
            await db.customStatement(
              'UPDATE sync_queue_table SET attempt_count = 1',
            );
        }
        final before = snapshot();
        final result = await processor().reconcileDay(
          uid,
          day,
          canSend: () => true,
        );
        expect(result.shouldRetry, isTrue);
        expect(snapshot(), before);
        if (invalid != 'attemptedNotSent') expect(requests, isEmpty);
        expect(
          (await db.getSyncItemById(a.id) as SyncQueueTableData).status,
          'pending',
        );
        expect(ledger.writes, 0);
      },
    );
  }
  test(
    'R2CB independent processors serialize reconcile and increment on the same database lane',
    () async {
      final a = await seed();
      final b = await seed(id: idB);
      await makeUncertain(a);
      final reached = Completer<void>();
      final release = Completer<void>();
      final first = processor(
        remote(
          handler: (r) async {
            final response = ledger.apply(r);
            reached.complete();
            await release.future;
            return response;
          },
        ),
      ).reconcileDay(uid, day, canSend: () => true);
      await reached.future;
      final second = processor().process(uid, b, canSend: () => true);
      expect(requests, hasLength(1));
      release.complete();
      expect((await first).isSuccess, isTrue);
      expect((await second).isSuccess, isTrue);
      expect(requests.map((r) => jsonDecode(r.body)['operation']), [
        'reconcile_water',
        'increment_water',
      ]);
      await checkConfirmed([a, b]);
      expect(ledger.writes, 2);
    },
  );
  test(
    'R2CB queued reconcile retains old admission across aborted logout',
    () async {
      final a = await seed();
      await makeUncertain(a);
      final reached = Completer<void>();
      final release = Completer<void>();
      final first = processor(
        remote(
          handler: (r) async {
            final response = ledger.apply(r);
            reached.complete();
            await release.future;
            return response;
          },
        ),
      ).reconcileDay(uid, day, canSend: () => true);
      await reached.future;
      final queued = processor().reconcileDay(uid, day, canSend: () => true);
      final q = db.localMutations.beginQuiesce(uid);
      await q.drain();
      q.finish(signOutConfirmed: false);
      release.complete();
      expect((await first).code, 'SESSION_STOPPED');
      expect((await queued).code, 'SESSION_STOPPED');
      expect(requests, hasLength(1));
      pending(a);
      expect(
        (await processor().reconcileDay(
          uid,
          day,
          canSend: () => true,
        )).isSuccess,
        isTrue,
      );
    },
  );
  test(
    'R2CB manager epoch error stays pending with sanitized code and one HTTP attempt',
    () async {
      final a = await seed();
      ledger.serverEpoch = epochB;
      final queue = _Queue(db);
      final other = _OtherRemote();
      final manager = SyncManager(
        queueStore: queue,
        remoteDataSource: other,
        currentUserId: () => auth.uid,
        waterV2Processor: processor(),
      );
      addTearDown(manager.dispose);
      expect(await manager.processPendingItems(), isFalse);
      final item = await db.getSyncItemById(a.id) as SyncQueueTableData;
      expect(item.status, 'pending');
      expect(item.lastErrorCode, 'WATER_EPOCH_MISMATCH');
      expect(item.attemptCount, 1);
      expect(requests, hasLength(1));
      expect(queue.genericAcks, 0);
      expect(other.calls, 0);
      expect(ledger.writes, 0);
    },
  );
  test(
    'R2CB reconciliation leaves a pending legacy absolute row entirely unchanged',
    () async {
      final a = await seed();
      await makeUncertain(a);
      final legacy = await db.insertSyncItem(
        ownerUid: uid,
        collection: 'health_info',
        docId: day,
        operationType: 'update',
        payloadJson: ' {"waterIntakeMl":1250} ',
      );
      final before = await db.getSyncItemById(legacy);
      final logs = <String>[];
      void listen(OutputEvent event) => logs.addAll(event.lines);
      Logger.addOutputListener(listen);
      addTearDown(() => Logger.removeOutputListener(listen));
      expect(
        (await processor().reconcileDay(
          uid,
          day,
          canSend: () => true,
        )).isSuccess,
        isTrue,
      );
      expect(await db.getSyncItemById(legacy), before);
      expect(db.schemaVersion, 10);
      expect(logs.join(), isNot(matches('fake-secret|$uid|$idA|$instant')));
    },
  );
  test(
    'R2CB raw reconcile transport errors never leak secrets or modify pending identities',
    () async {
      final a = await seed();
      await makeUncertain(a);
      final before = snapshot();
      final logs = <String>[];
      void listen(OutputEvent event) => logs.addAll(event.lines);
      Logger.addOutputListener(listen);
      addTearDown(() => Logger.removeOutputListener(listen));
      final result = await processor(
        remote(
          handler: (_) async => http.Response(
            '{"error":"fake-secret $uid $instant","code":"fake-secret","retryable":false}',
            409,
          ),
        ),
      ).reconcileDay(uid, day, canSend: () => true);
      expect(result.code, 'WATER_HTTP_409');
      expect(result.message, isNull);
      expect(snapshot(), before);
      expect(logs.join(), isNot(matches('fake-secret|$uid|$instant')));
    },
  );

  for (final defect in [
    'fingerprint',
    'fingerprintCase',
    'fingerprintMissing',
    'receiptExtra',
    'delta',
    'deltaFloat',
    'day',
    'timestamp',
    'offset',
    'uuid',
    'foreign',
    'duplicate',
    'crossDuplicate',
    'coverage',
    'complete',
    'envelopeExtra',
    'epoch',
    'revision',
    'appliedZero',
    'appliedFuture',
    'credit',
    'creditBelowCap',
  ]) {
    test(
      'R2CB malformed reconcile $defect never ACKs even a valid sibling',
      () async {
        final a = await seed();
        final b = await seed(id: idB);
        await makeUncertain(a);
        await makeUncertain(b);
        final before = snapshot();
        final transport = remote(
          handler: (r) async {
            final wire =
                jsonDecode(ledger.apply(r).body) as Map<String, dynamic>;
            final proof =
                (wire['recognized'] as List).last as Map<String, dynamic>;
            switch (defect) {
              case 'fingerprint':
                proof['fingerprint'] = 'f' * 64;
              case 'fingerprintCase':
                proof['fingerprint'] = (proof['fingerprint'] as String)
                    .toUpperCase();
              case 'fingerprintMissing':
                proof.remove('fingerprint');
              case 'receiptExtra':
                proof['extra'] = true;
              case 'delta':
                proof['deltaMl'] = 500;
              case 'deltaFloat':
                proof['deltaMl'] = 250.0;
              case 'day':
                proof['healthDay'] = '2026-08-22';
              case 'timestamp':
                proof['occurredAt'] = '2026-08-21T11:00:00.123Z';
              case 'offset':
                proof['timeZoneOffsetMinutes'] = 180;
              case 'uuid':
                proof['mutationId'] = idB.toUpperCase();
              case 'foreign':
                proof['mutationId'] = idC;
              case 'duplicate':
                (wire['recognized'] as List).add(
                  Map<String, dynamic>.from(proof),
                );
              case 'crossDuplicate':
                wire['unrecognizedMutationIds'] = [idA];
              case 'coverage':
                (wire['recognized'] as List).removeLast();
              case 'complete':
                wire['complete'] = false;
              case 'envelopeExtra':
                wire['extra'] = true;
              case 'epoch':
                wire['epoch'] = epochB;
              case 'revision':
                wire['revision'] = -1;
              case 'appliedZero':
                proof['appliedRevision'] = 0;
              case 'appliedFuture':
                proof['appliedRevision'] = 3;
              case 'credit':
                proof['effectiveCreditMl'] = 251;
              case 'creditBelowCap':
                proof['effectiveCreditMl'] = 0;
            }
            return http.Response(jsonEncode(wire), 200);
          },
        );
        expect(
          (await processor(
            transport,
          ).reconcileDay(uid, day, canSend: () => true)).code,
          'WATER_INVALID_RESPONSE',
        );
        expect(snapshot(), before);
        expect(ledger.writes, 2);
      },
    );
  }
  for (final field in ['occurredAt', 'timeZoneOffsetMinutes']) {
    test(
      'R2CB self-consistent remote $field and hash must still match persisted local intent',
      () async {
        final a = await seed();
        final b = await seed(id: idB);
        await makeUncertain(a);
        await makeUncertain(b);
        final before = snapshot();
        final transport = remote(
          handler: (r) async {
            final wire =
                jsonDecode(ledger.apply(r).body) as Map<String, dynamic>;
            final receipt =
                (wire['recognized'] as List).last as Map<String, dynamic>;
            receipt[field] = field == 'occurredAt'
                ? '2026-08-21T11:00:00.123Z'
                : 180;
            receipt['fingerprint'] = WaterV2Fingerprint.calculate(
              mutationId: receipt['mutationId'],
              healthDay: receipt['healthDay'],
              deltaMl: receipt['deltaMl'],
              occurredAt: receipt['occurredAt'],
              timeZoneOffsetMinutes: receipt['timeZoneOffsetMinutes'],
            );
            return http.Response(jsonEncode(wire), 200);
          },
        );
        expect(
          (await processor(
            transport,
          ).reconcileDay(uid, day, canSend: () => true)).code,
          'WATER_MUTATION_CONFLICT',
        );
        expect(snapshot(), before);
      },
    );
  }
  for (final known in [0, 2]) {
    test(
      'R2CB actual snapshot revision two is accepted with minimum $known',
      () async {
        final a = await seed();
        final b = await seed(id: idB);
        await makeUncertain(a);
        await makeUncertain(b);
        if (known > 0)
          await store.persistConfirmedState(
            ownerUid: uid,
            healthDay: day,
            epoch: epoch,
            revision: known,
            confirmedWaterIntakeMl: 1500,
            reconciledAtUtc: instant,
          );
        expect(
          (await processor().reconcileDay(
            uid,
            day,
            canSend: () => true,
          )).isSuccess,
          isTrue,
        );
        expect(jsonDecode(requests.single.body)['expectedRevision'], known);
        await checkConfirmed([a, b]);
      },
    );
  }
  test(
    'R2CB remote revision below captured minimum is rejected before any ACK',
    () async {
      final a = await seed();
      await makeUncertain(a);
      await store.persistConfirmedState(
        ownerUid: uid,
        healthDay: day,
        epoch: epoch,
        revision: 2,
        confirmedWaterIntakeMl: 1250,
        reconciledAtUtc: instant,
      );
      final before = snapshot();
      expect(
        (await processor().reconcileDay(uid, day, canSend: () => true)).code,
        'WATER_SNAPSHOT_MISMATCH',
      );
      expect(snapshot(), before);
    },
  );
  for (final changed in ['revision', 'total']) {
    test(
      'R2CB snapshot $changed cannot regress the latest local confirmed state',
      () async {
        final a = await seed();
        final b = await seed(id: idB);
        await makeUncertain(a);
        await makeUncertain(b);
        late Map<String, List<Map<String, Object?>>> before;
        final transport = remote(
          handler: (r) async {
            final wire =
                jsonDecode(ledger.apply(r).body) as Map<String, dynamic>;
            if (changed == 'revision') {
              await store.persistConfirmedState(
                ownerUid: uid,
                healthDay: day,
                epoch: epoch,
                revision: 3,
                confirmedWaterIntakeMl: 1750,
                reconciledAtUtc: instant,
              );
              await db
                  .update(db.healthEntries)
                  .write(
                    const HealthEntriesCompanion(waterIntakeMl: Value(1750)),
                  );
            } else {
              wire['waterIntakeMl'] = 900;
            }
            before = snapshot();
            return http.Response(jsonEncode(wire), 200);
          },
        );
        expect(
          (await processor(
            transport,
          ).reconcileDay(uid, day, canSend: () => true)).code,
          changed == 'revision'
              ? 'WATER_REVISION_REGRESSION'
              : 'WATER_SNAPSHOT_CONFLICT',
        );
        expect(snapshot(), before);
      },
    );
  }
  for (final changed in [
    'uid',
    'a-b-a',
    'logout',
    'aborted',
    'quiescence',
    'generation',
  ]) {
    test(
      'R2CB $changed during reconcile HTTP invalidates original admission and preserves every row',
      () async {
        final a = await seed();
        await makeUncertain(a);
        final before = snapshot();
        final reached = Completer<void>();
        final release = Completer<void>();
        var generation = 0;
        final captured = generation;
        final transport = remote(
          handler: (r) async {
            final response = ledger.apply(r);
            reached.complete();
            await release.future;
            return response;
          },
        );
        final oldPermit = transport.capturePermit(
          uid,
          () => generation == captured,
        );
        final operation = processor(
          transport,
        ).reconcileDay(uid, day, canSend: () => generation == captured);
        await reached.future;
        LocalMutationQuiescence? q;
        switch (changed) {
          case 'uid':
            auth.uid = 'owner-b';
            db.localMutations.observeSession(auth.uid);
          case 'a-b-a':
            auth.uid = 'owner-b';
            db.localMutations.observeSession(auth.uid);
            auth.uid = uid;
            db.localMutations.observeSession(uid);
            db.localMutations.openPreparedSession();
          case 'logout':
            q = db.localMutations.beginQuiesce(uid);
            await q.drain();
            q.finish(signOutConfirmed: true);
          case 'aborted':
            q = db.localMutations.beginQuiesce(uid);
            await q.drain();
            q.finish(signOutConfirmed: false);
          case 'quiescence':
            q = db.localMutations.beginQuiesce(uid);
            await q.drain();
          case 'generation':
            generation++;
        }
        release.complete();
        expect((await operation).code, 'SESSION_STOPPED');
        expect(snapshot(), before);
        expect(oldPermit.isCurrent, isFalse);
        if (changed == 'quiescence') q!.finish(signOutConfirmed: false);
        auth.uid = uid;
        db.localMutations.observeSession(uid);
        db.localMutations.openPreparedSession();
        expect(
          (await processor().reconcileDay(
            uid,
            day,
            canSend: () => true,
          )).isSuccess,
          isTrue,
        );
        await checkConfirmed([a], revision: 1, total: 1250);
        expect(ledger.writes, 1);
      },
    );
  }
  for (final duringApp in [false, true]) {
    test(
      'R2CB aborted logout during reconcile ${duringApp ? 'App Check' : 'ID Token'} stops old preflight',
      () async {
        final a = await seed();
        await makeUncertain(a);
        final before = snapshot();
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
        final operation = processor(
          transport,
        ).reconcileDay(uid, day, canSend: () => true);
        await reached.future;
        final q = db.localMutations.beginQuiesce(uid);
        await q.drain();
        q.finish(signOutConfirmed: false);
        release.complete('fake');
        expect((await operation).code, 'SESSION_STOPPED');
        expect(requests, isEmpty);
        expect(snapshot(), before);
        expect(
          (await processor().reconcileDay(
            uid,
            day,
            canSend: () => true,
          )).isSuccess,
          isTrue,
        );
      },
    );
  }
  for (final code in ['AUTHENTICATION_REQUIRED', 'APP_CHECK_REQUIRED']) {
    test('R2CB reconcile $code prevents HTTP and mutations', () async {
      final a = await seed();
      await makeUncertain(a);
      final before = snapshot();
      final transport = remote(
        token: (_, _) async =>
            code == 'AUTHENTICATION_REQUIRED' ? null : 'fake',
        app: () async => code == 'APP_CHECK_REQUIRED' ? null : 'fake',
      );
      expect(
        (await processor(
          transport,
        ).reconcileDay(uid, day, canSend: () => true)).code,
        code,
      );
      expect(requests, isEmpty);
      expect(snapshot(), before);
    });
  }
  test(
    'R2CB UID change before reconcile produces no tokens, HTTP or local mutations',
    () async {
      final a = await seed();
      await makeUncertain(a);
      final before = snapshot();
      auth.uid = 'owner-b';
      expect(
        (await processor().reconcileDay(uid, day, canSend: () => true)).code,
        'SESSION_STOPPED',
      );
      expect(tokenCalls, 0);
      expect(requests, isEmpty);
      expect(snapshot(), before);
    },
  );
  test(
    'R2CB rotated server epoch is recoverable and never replaces persisted origin',
    () async {
      final a = await seed();
      ledger.serverEpoch = epochB;
      final p = processor();
      final result = await p.process(uid, a, canSend: () => true);
      expect(result.code, 'WATER_EPOCH_MISMATCH');
      expect(result.shouldRetry, isTrue);
      expect(ledger.writes, 0);
      final before = snapshot();
      expect(
        (await p.reconcileDay(uid, day, canSend: () => true)).code,
        'WATER_SNAPSHOT_MISMATCH',
      );
      expect(snapshot(), before);
      expect(
        (await db.select(db.waterV2Intents).getSingle()).originEpoch,
        epoch,
      );
      expect(jsonDecode(requests.first.body)['originEpoch'], epoch);
    },
  );
  test(
    'R2CB default reconcile gate closes before database, token or HTTP work',
    () async {
      final a = await seed();
      await makeUncertain(a);
      final before = snapshot();
      expect(
        (await processor(
          WaterV2RemoteDataSource(auth),
        ).reconcileDay(uid, day, canSend: () => true)).code,
        'WATER_V2_DISABLED',
      );
      expect(snapshot(), before);
      expect(requests, isEmpty);
      expect(tokenCalls, 0);
    },
  );

  for (final vector in <(String, int, String)>[
    (
      '2026-08-21T10:00:00.000Z',
      0,
      '4746ff0a42ce8ecf80440c58f92e321904a8308463998482ec8af640cd36fe44',
    ),
    (
      '2026-08-21T10:00:00.123Z',
      -180,
      '1f36d7419353e415e565df205ab213de26c212734aef4c55af429a5dd3fca97a',
    ),
    (
      '2026-08-22T01:00:00.000Z',
      -180,
      'e8d721a4ac8e768e1b98616c817a20e49daeff528cacef78f2213b11dd70ad37',
    ),
    (
      '2026-08-20T23:00:00.000Z',
      120,
      '149dca28fe7a283d3f9ccfb77ed45af1123db75974ef6d84100c33e086469d7a',
    ),
    (
      '2026-08-21T00:00:00.000Z',
      840,
      'fdfa45e9695dc61ff2a022de012746dc2a04ecde5c2390fc3ce34fda54339496',
    ),
    (
      '2026-08-21T14:00:00.000Z',
      -840,
      'e00edcc987e21562dfb990de29a3833c75ab8b74cc7694c4320f9f6ad3566b58',
    ),
  ]) {
    test('R2CB SHA-256 golden offset ${vector.$2} at ${vector.$1}', () async {
      final item = await seed(offset: vector.$2, occurred: vector.$1);
      final row = await db.select(db.waterV2Intents).getSingle();
      final request = WaterV2IncrementRequest.fromIntent(row);
      expect(request.fingerprint, vector.$3);
      await makeUncertain(item);
      expect(ledger.recognized(idA)['fingerprint'], vector.$3);
      expect(
        (await processor().reconcileDay(
          uid,
          day,
          canSend: () => true,
        )).isSuccess,
        isTrue,
      );
      await checkConfirmed([item], revision: 1, total: 1250);
    });
  }
  test(
    'R2CB two lost responses reconcile without resending or duplicate credit',
    () async {
      final a = await seed();
      final b = await seed(id: idB);
      final p = processor(
        remote(
          handler: (r) async {
            final response = ledger.apply(r);
            if (jsonDecode(r.body)['operation'] == 'increment_water')
              throw http.ClientException('fake-secret-lost');
            return response;
          },
        ),
      );
      expect(
        (await p.process(uid, a, canSend: () => true)).code,
        'NETWORK_ERROR',
      );
      expect(
        (await p.process(uid, b, canSend: () => true)).code,
        'NETWORK_ERROR',
      );
      final health = await db.select(db.healthEntries).getSingle();
      expect(
        (await p.reconcileDay(uid, day, canSend: () => true)).isSuccess,
        isTrue,
      );
      await checkConfirmed([a, b]);
      expect(ledger.writes, 2);
      expect(await db.select(db.healthEntries).getSingle(), health);
      expect(requests.map((r) => jsonDecode(r.body)['operation']), [
        'increment_water',
        'increment_water',
        'reconcile_water',
      ]);
      expect(
        (await p.reconcileDay(uid, day, canSend: () => true)).isSuccess,
        isTrue,
      );
      expect(requests, hasLength(3));
      expect(ledger.writes, 2);
    },
  );
  test(
    'R2CB known applied and missing uncertain refuse the complete ACK until original UUID replay',
    () async {
      final a = await seed();
      final b = await seed(id: idB);
      await makeUncertain(a);
      await makeUncertain(b, applied: false);
      final before = snapshot();
      final p = processor();
      expect(
        (await p.reconcileDay(uid, day, canSend: () => true)).code,
        'WATER_RECONCILIATION_REQUIRED',
      );
      expect(snapshot(), before);
      expect(ledger.writes, 1);
      expect(
        (await p.process(uid, b, canSend: () => true)).code,
        'WATER_RECONCILIATION_REQUIRED',
      );
      expect(snapshot(), before);
      expect(ledger.writes, 2);
      expect(jsonDecode(requests[1].body), jsonDecode(b.payloadJson));
      expect(
        (await p.reconcileDay(uid, day, canSend: () => true)).isSuccess,
        isTrue,
      );
      await checkConfirmed([a, b]);
      expect(ledger.writes, 2);
      expect(ledger.receipts.keys.toSet(), {idA, idB});
    },
  );
  test(
    'R2CB recognized plus proven not_sent missing preserves local delta without confirming missing',
    () async {
      final a = await seed();
      final b = await seed(id: idB);
      await makeUncertain(a);
      final health = await db.select(db.healthEntries).getSingle();
      expect(
        (await processor().reconcileDay(
          uid,
          day,
          canSend: () => true,
        )).isSuccess,
        isTrue,
      );
      await checkConfirmed([a], revision: 1, total: 1250);
      expect(await db.select(db.healthEntries).getSingle(), health);
      expect(
        (await db.getSyncItemById(b.id) as SyncQueueTableData).status,
        'pending',
      );
      expect(
        (await (db.select(
          db.waterV2Intents,
        )..where((t) => t.mutationId.equals(idB))).getSingle()).localStatus,
        'not_sent',
      );
      expect(ledger.writes, 1);
      expect(
        (await processor().process(uid, b, canSend: () => true)).isSuccess,
        isTrue,
      );
      expect(ledger.total, 1500);
      expect(ledger.writes, 2);
    },
  );
  test(
    'R2CB three mixed intents never partially ACK or drop an uncertain missing UUID',
    () async {
      final a = await seed();
      final b = await seed(id: idB);
      final c = await seed(id: idC);
      await makeUncertain(a);
      await makeUncertain(b, applied: false);
      final before = snapshot();
      final p = processor();
      expect(
        (await p.reconcileDay(uid, day, canSend: () => true)).code,
        'WATER_RECONCILIATION_REQUIRED',
      );
      expect(snapshot(), before);
      expect(
        (await p.process(uid, b, canSend: () => true)).code,
        'WATER_RECONCILIATION_REQUIRED',
      );
      expect(
        (await p.reconcileDay(uid, day, canSend: () => true)).isSuccess,
        isTrue,
      );
      await checkConfirmed([a, b]);
      expect(
        (await db.select(db.healthEntries).getSingle()).waterIntakeMl,
        1750,
      );
      expect(
        (await db.getSyncItemById(c.id) as SyncQueueTableData).status,
        'pending',
      );
      expect(ledger.total, 1500);
      expect(ledger.writes, 2);
    },
  );
  test(
    'R2CB remote snapshot includes an unqueried other-device increment',
    () async {
      final a = await seed();
      await makeUncertain(a);
      final other = jsonDecode(a.payloadJson) as Map<String, dynamic>;
      other['mutationId'] = idC;
      ledger.apply(
        http.Request('POST', Uri.https('fake.invalid'))
          ..body = jsonEncode(other),
      );
      expect(
        (await processor().reconcileDay(
          uid,
          day,
          canSend: () => true,
        )).isSuccess,
        isTrue,
      );
      await checkConfirmed([a], revision: 2, total: 1500);
      expect(
        (await db.select(db.healthEntries).getSingle()).waterIntakeMl,
        1500,
      );
      expect(jsonDecode(requests.single.body)['pendingMutationIds'], [idA]);
      expect(ledger.writes, 2);
    },
  );
  test(
    'R2CB intent created during reconcile HTTP is projected only while provably not_sent',
    () async {
      final a = await seed();
      await makeUncertain(a);
      final before = await db.select(db.healthEntries).getSingle();
      final reached = Completer<void>();
      final release = Completer<void>();
      final operation = processor(
        remote(
          handler: (r) async {
            final response = ledger.apply(r);
            reached.complete();
            await release.future;
            return response;
          },
        ),
      ).reconcileDay(uid, day, canSend: () => true);
      await reached.future;
      final b = await seed(id: idB);
      release.complete();
      expect((await operation).isSuccess, isTrue);
      await checkConfirmed([a], revision: 1, total: 1250);
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
    },
  );
  test(
    'R2CB a new uncertain intent during HTTP blocks every reconciliation write',
    () async {
      final a = await seed();
      await makeUncertain(a);
      final reached = Completer<void>();
      final release = Completer<void>();
      final operation = processor(
        remote(
          handler: (r) async {
            final response = ledger.apply(r);
            reached.complete();
            await release.future;
            return response;
          },
        ),
      ).reconcileDay(uid, day, canSend: () => true);
      await reached.future;
      final b = await seed(id: idB);
      await makeUncertain(b, applied: false);
      final before = snapshot();
      release.complete();
      expect((await operation).code, 'WATER_RECONCILIATION_REQUIRED');
      expect(snapshot(), before);
    },
  );
  test(
    'R2CB more than 100 pending intents are quarantined without HTTP or paging',
    () async {
      for (var i = 0; i < 101; i++)
        await seed(
          id: '${i.toRadixString(16).padLeft(8, '0')}-0000-4000-8000-000000000000',
        );
      final before = snapshot();
      expect(
        (await processor().reconcileDay(uid, day, canSend: () => true)).code,
        'WATER_RECONCILIATION_LIMIT',
      );
      expect(snapshot(), before);
      expect(requests, isEmpty);
      expect(ledger.writes, 0);
    },
  );
  test(
    'R2CB exactly 100 complete proofs commit one snapshot and no duplicate credits',
    () async {
      final items = <SyncQueueTableData>[];
      for (var i = 0; i < 100; i++) {
        final item = await seed(
          id: '${i.toRadixString(16).padLeft(8, '0')}-0000-4000-8000-000000000000',
        );
        items.add(item);
        await makeUncertain(item);
      }
      expect(
        (await processor().reconcileDay(
          uid,
          day,
          canSend: () => true,
        )).isSuccess,
        isTrue,
      );
      await checkConfirmed(items, revision: 100, total: 26000);
      expect(
        (await db.select(db.healthEntries).getSingle()).waterIntakeMl,
        26000,
      );
      expect(ledger.writes, 100);
      expect(requests, hasLength(1));
    },
  );
  for (final mid in [true, false]) {
    test(
      'R2CB SQLite ${mid ? 'middle queue write' : 'commit'} rollback permits complete proof replay',
      () async {
        final a = await seed();
        final b = await seed(id: idB);
        await makeUncertain(a);
        await makeUncertain(b);
        final evidence = await reconciliationProof();
        final before = snapshot();
        writes.failQueue = mid;
        writes.failCommit = !mid;
        await expectLater(
          store.acknowledgeReconciliation(
            evidence.proof,
            plan: evidence.plan,
            admission: evidence.ticket,
            permit: evidence.permit,
            observedAtUtc: instant,
          ),
          throwsStateError,
        );
        expect(snapshot(), before);
        writes.failQueue = false;
        writes.failCommit = false;
        await store.acknowledgeReconciliation(
          evidence.proof,
          plan: evidence.plan,
          admission: evidence.ticket,
          permit: evidence.permit,
          observedAtUtc: instant,
        );
        await checkConfirmed([a, b]);
        expect(ledger.writes, 2);
      },
    );
  }
  test(
    'R2CB processor recovers after first ACK commit failure without renewing UUIDs or doubling remote credits',
    () async {
      final a = await seed();
      final b = await seed(id: idB);
      await makeUncertain(a);
      await makeUncertain(b);
      var inject = true;
      final p = processor(
        remote(
          handler: (r) async {
            final response = ledger.apply(r);
            if (inject) writes.failCommit = true;
            return response;
          },
        ),
      );
      final before = snapshot();
      expect(
        (await p.reconcileDay(uid, day, canSend: () => true)).code,
        'WATER_LOCAL_ACK_FAILED',
      );
      expect(snapshot(), before);
      inject = false;
      writes.failCommit = false;
      expect(
        (await p.reconcileDay(uid, day, canSend: () => true)).isSuccess,
        isTrue,
      );
      expect(requests[0].body, requests[1].body);
      await checkConfirmed([a, b]);
      expect(ledger.writes, 2);
    },
  );
  test(
    'R2CB duplicate reconcile proof leaves a newer local gesture and ACK counters unchanged',
    () async {
      final a = await seed();
      await makeUncertain(a);
      final evidence = await reconciliationProof();
      await store.acknowledgeReconciliation(
        evidence.proof,
        plan: evidence.plan,
        admission: evidence.ticket,
        permit: evidence.permit,
        observedAtUtc: instant,
      );
      await seed(id: idB);
      final before = snapshot();
      await store.acknowledgeReconciliation(
        evidence.proof,
        plan: evidence.plan,
        admission: evidence.ticket,
        permit: evidence.permit,
        observedAtUtc: instant,
      );
      expect(snapshot(), before);
      expect(ledger.writes, 1);
    },
  );
  for (final [start, credit] in [
    [999900, 100],
    [1000000, 0],
  ]) {
    test(
      'R2CB reconciles cap credit $credit using full original identity',
      () async {
        await store.persistConfirmedState(
          ownerUid: uid,
          healthDay: day,
          epoch: epoch,
          revision: 1,
          confirmedWaterIntakeMl: start,
          reconciledAtUtc: instant,
        );
        await db
            .update(db.healthEntries)
            .write(HealthEntriesCompanion(waterIntakeMl: Value(start)));
        ledger.total = start;
        ledger.revision = 1;
        final a = await seed();
        final b = await seed(id: idB);
        await makeUncertain(a);
        await makeUncertain(b);
        expect(ledger.recognized(idA)['effectiveCreditMl'], credit);
        expect(ledger.recognized(idB)['effectiveCreditMl'], 0);
        expect(
          (await processor().reconcileDay(
            uid,
            day,
            canSend: () => true,
          )).isSuccess,
          isTrue,
        );
        await checkConfirmed([a, b], revision: 3, total: 1000000);
        expect(
          (await db.select(db.healthEntries).getSingle()).waterIntakeMl,
          1000000,
        );
      },
    );
  }

  test(
    'R2CB increment includes exactly eight fields from persisted identity',
    () async {
      final a = await seed();
      final row = await db.select(db.waterV2Intents).getSingle();
      final payload = WaterV2IncrementRequest.fromIntent(row).toJson();
      expect(payload.keys.toSet(), {
        'operation',
        'version',
        'mutationId',
        'healthDay',
        'deltaMl',
        'occurredAt',
        'timeZoneOffsetMinutes',
        'originEpoch',
      });
      expect(payload['originEpoch'], row.originEpoch);
      expect(payload['mutationId'], a.docId);
    },
  );
  test(
    'R2CB reconcile accepts revision two and full proof above minimum zero',
    () async {
      await preparedProof(await seed());
      await preparedProof(await seed(id: idB));
      final req = WaterV2ReconcileRequest(
        ownerUid: uid,
        healthDay: day,
        expectedEpoch: epoch,
        expectedRevision: 0,
        pendingMutationIds: [idA, idB],
      );
      final transport = remote(
        handler: (_) async => http.Response(
          jsonEncode({
            'success': true,
            'operation': 'reconcile_water',
            'version': 2,
            'healthDay': day,
            'epoch': epoch,
            'revision': ledger.revision,
            'waterIntakeMl': ledger.total,
            'complete': true,
            'recognized': [ledger.recognized(idA), ledger.recognized(idB)],
            'unrecognizedMutationIds': [],
          }),
          200,
        ),
      );
      final result = await transport.reconcile(
        req,
        transport.capturePermit(uid, () => true),
      );
      expect(result.error, isNull);
      expect(result.value!.revision, 2);
      expect(result.value!.epoch, epoch);
      expect(result.value!.recognized.map((r) => r.mutationId), [idA, idB]);
    },
  );
  test(
    'R2CB resolves two remotely applied uncertain intents atomically',
    () async {
      final a = await seed();
      final b = await seed(id: idB);
      await preparedProof(a);
      await preparedProof(b);
      final beforeHealth = await db.select(db.healthEntries).getSingle();
      final result = await processor().reconcileDay(
        uid,
        day,
        canSend: () => true,
      );
      expect(result.isSuccess, isTrue);
      expect((await db.select(db.waterV2DailyStates).getSingle()).revision, 2);
      expect(
        (await db.select(db.waterV2Intents).get()).every(
          (r) => r.localStatus == 'receipt_confirmed',
        ),
        isTrue,
      );
      expect(
        (await db.select(db.syncQueueTable).get()).every(
          (r) => r.status == 'succeeded',
        ),
        isTrue,
      );
      expect(await db.select(db.healthEntries).getSingle(), beforeHealth);
      expect(ledger.total, 1500);
      expect(ledger.writes, 2);
    },
  );

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
      ledger.apply(
        http.Request('POST', Uri.https('fake.invalid'))..body = a.payloadJson,
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
            'recognized': [ledger.recognized(idA)],
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
        expectedRevision: 1,
        pendingMutationIds: [idA],
      );
      final data = <String, dynamic>{
        'success': true,
        'operation': 'reconcile_water',
        'version': 2,
        'healthDay': day,
        'epoch': epoch,
        'revision': 1,
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
          data['revision'] = 0;
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
