import 'package:life_os/features/checkin/data/repositories/checkin_repository.dart';
import '../../helpers/observed_gate.dart';
import 'package:life_os/core/database/database_provider.dart';
import 'package:life_os/core/services/firebase_auth_provider.dart';
import 'package:life_os/features/focus/presentation/providers/providers/focus_provider.dart';
import 'package:life_os/core/network/generational_http_provider.dart';
import 'package:life_os/core/services/sync_manager.dart';
import 'package:life_os/core/services/sync_queue_store.dart';
import 'package:life_os/core/services/sync_operation_result.dart';
// ignore_for_file: subtype_of_sealed_class, must_be_immutable
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Value;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:life_os/core/database/app_database.dart' hide Transaction;
import 'package:life_os/core/database/local_account_session.dart';
import 'package:life_os/core/database/local_database_identity.dart';
import 'package:life_os/core/network/generational_http_store.dart';
import 'package:life_os/core/network/generational_http_transport.dart';
import 'package:life_os/core/network/activity_remote_data_source.dart';
import 'package:life_os/features/focus/data/remote/focus_remote_data_source.dart';
import 'package:life_os/core/services/sync_remote_data_source.dart';

// Synthetic token port checks consistency, NOT Auth authority. Emulator tests
// separately use verified provider-created accounts and production gateways.
const ga = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    gb = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
LocalDatabaseIdentity identity(String g, {String uid = 'same'}) =>
    LocalDatabaseIdentity.bound(
      projectId: 'demo-life-os',
      databaseId: '(default)',
      uid: uid,
      generation: g,
    );
String token(
  String g, {
  String uid = 'same',
  String project = 'demo-life-os',
  String? tenant,
}) {
  String e(Object v) =>
      base64Url.encode(utf8.encode(jsonEncode(v))).replaceAll('=', '');
  return '${e({'alg': 'none'})}.${e({
    'sub': uid,
    'aud': project,
    'iss': 'https://securetoken.google.com/$project',
    'lifeos_generation': g,
    'firebase': {'tenant': ?tenant},
  })}.';
}

class App extends Fake implements FirebaseApp {
  @override
  FirebaseOptions get options => const FirebaseOptions(
    apiKey: 'demo',
    appId: 'demo',
    messagingSenderId: 'demo',
    projectId: 'demo-life-os',
  );
}

class TokenResult extends Fake implements IdTokenResult {
  TokenResult(this.id, this.generation);
  final String id, generation;
  @override
  Map<String, dynamic> get claims =>
      jsonDecode(
            utf8.decode(
              base64Url.decode(
                base64Url.normalize(token(generation, uid: id).split('.')[1]),
              ),
            ),
          )
          as Map<String, dynamic>;
}

class Person extends Fake implements User {
  Person(this.id, [this.generation = ga]);
  final String id, generation;
  @override
  String get uid => id;
  @override
  Future<IdTokenResult> getIdTokenResult([bool forceRefresh = false]) async =>
      TokenResult(id, generation);
}

class Auth extends Fake implements FirebaseAuth {
  User? person = Person('same');
  final events = StreamController<User?>.broadcast(sync: true);
  @override
  User? get currentUser => person;
  @override
  FirebaseApp get app => App();
  @override
  String? get tenantId => null;
  @override
  Stream<User?> authStateChanges() => events.stream;
  void change(User? next) {
    person = next;
    events.add(next);
  }
}

class Store extends Fake implements FirebaseFirestore {}

class NoSdk extends Fake implements FirebaseFirestore {
  int calls = 0;
  @override
  CollectionReference<Map<String, dynamic>> collection(String path) {
    calls++;
    throw StateError('SDK must remain unused');
  }
}

http.Response success(
  http.Request request, {
  Map<String, dynamic>? body,
  bool missing = false,
  bool wrong = false,
}) {
  final b = body ?? {'ok': true};
  final c =
      jsonDecode(
            utf8.decode(
              base64Url.decode(
                base64Url.normalize(request.headers['X-LifeOS-Operation']!),
              ),
            ),
          )
          as Map<String, dynamic>;
  final ack = {
    ...c,
    'status': 200,
    'responseHash': httpDigest(b),
    'operationReplay': false,
  };
  if (wrong) ack['operationId'] = '0' * 64;
  return http.Response(
    jsonEncode(b),
    200,
    headers: {
      if (!missing)
        'x-lifeos-operation-ack': base64Url
            .encode(utf8.encode(httpCanonical(ack)))
            .replaceAll('=', ''),
    },
  );
}

class Fixture {
  Fixture({
    this.generation = ga,
    this.requestTimeout = const Duration(milliseconds: 100),
  });
  final Duration requestTimeout;
  final String generation;
  late final container = ProviderContainer();
  late final scope = identity(generation);
  late final session = container.read(localAccountSessionProvider.notifier)
    ..bind(scope);
  late final db = AppDatabase.forUser(
    identity: scope,
    executor: NativeDatabase.memory(),
  );
  late final auth = Auth();
  late final store = GenerationalHttpStore(db);
  Future<String?> Function(User, bool) load = (u, r) async => token(ga);
  Future<String?> Function() appCheck = () async => 'synthetic-app-check';
  late final transport = GenerationalHttpTransport(
    store: store,
    lease: session.capture(),
    auth: auth,
    client: MockClient((r) => handler(r)),
    appCheckToken: () => appCheck(),
    baseUri: Uri.parse('http://127.0.0.1:1'),
    timeout: requestTimeout,
    idToken: (u, r) => load(u, r),
  );
  Future<http.Response> Function(http.Request) handler = (r) async =>
      success(r);
  Future<GenerationalHttpIntent> intent({String key = 'one'}) => store.prepare(
    stableKey: key,
    route: 'activity/task-complete',
    body: {'taskId': 'task'},
  );
  Future<SyncQueueTableData> row() async {
    final id = await db.insertSyncItem(
      ownerUid: 'same',
      collection: 'tasks',
      docId: 'task',
      operationType: 'update',
      payloadJson: '{"isCompleted":true}',
      createdAt: 1234,
    );
    return await db.getSyncItemById(id) as SyncQueueTableData;
  }

  Future<void> close() async {
    await transport.close();
    await auth.events.close();
    await db.close();
    container.dispose();
  }
}

class AfterLocalCommit extends Fake implements SyncRemoteDataSource {
  AfterLocalCommit(this.db);
  final AppDatabase db;
  @override
  Future<SyncOperationResult> process(
    String uid,
    SyncQueueTableData row,
  ) async {
    await db.markSyncItemAsSucceeded(row.id, uid);
    return const SyncOperationResult.retryable(
      code: 'SIMULATED_LOCAL_REPLY_LOSS',
      preserveQueueState: true,
    );
  }
}

void main() {
  test(
    'Check-in local edit and outbox roll back together when enqueue fails',
    () async {
      final f = Fixture();
      addTearDown(f.close);
      final repo = CheckInRepository(f.db, NoSdk(), f.auth);
      await repo.saveDailyMetrics(energy: 1.25, focus: 2.5, motivation: 3.75);
      await repo.syncPendingCheckIns();
      final previous = await f.db.select(f.db.checkInTable).getSingle(),
          queue = await f.db.getPendingSyncItems('same');
      await f.db.customStatement(
        "CREATE TRIGGER block_checkin_enqueue BEFORE INSERT ON sync_queue_table WHEN NEW.collection='checkins' BEGIN SELECT RAISE(ABORT,'injected Check-in outbox failure'); END",
      );
      await expectLater(
        repo.saveDailyMetrics(energy: 4, focus: 5, motivation: 6),
        throwsA(anything),
      );
      expect(await f.db.select(f.db.checkInTable).getSingle(), previous);
      expect(await f.db.getPendingSyncItems('same'), queue);
      await f.db.customStatement('DROP TRIGGER block_checkin_enqueue');
    },
  );
  test(
    'generation change before Check-in response preserves pending domain and queue',
    () async {
      final f = Fixture(requestTimeout: const Duration(seconds: 5));
      addTearDown(f.close);
      final repo = CheckInRepository(f.db, NoSdk(), f.auth);
      await repo.saveDailyMetrics(energy: 1.25, focus: 2.5, motivation: 3.75);
      await repo.syncPendingCheckIns();
      final row =
              (await f.db.getPendingSyncItems('same')).single
                  as SyncQueueTableData,
          reached = Completer<http.Request>(),
          reply = Completer<http.Response>();
      addTearDown(() {
        if (!reply.isCompleted) reply.complete(http.Response('{}', 503));
      });
      f.handler = (r) {
        reached.complete(r);
        return reply.future;
      };
      final source = FirestoreSyncRemoteDataSource(
            Store(),
            f.auth,
            trustedTransport: f.transport,
          ),
          sending = source.process('same', row);
      final request = await observedGate(reached.future, sending);
      f.session.bind(identity(gb));
      reply.complete(
        success(
          request,
          body: {
            ...jsonDecode(request.body) as Map<String, dynamic>,
            'success': true,
          },
        ),
      );
      expect((await sending).isSuccess, false);
      expect(
        (await f.db.getSyncItemById(row.id) as SyncQueueTableData).isSynced,
        false,
      );
      expect(
        (await f.db.select(f.db.checkInTable).getSingle()).isSynced,
        false,
      );
    },
  );

  test(
    'bound Check-in persists its existing queue and never falls back to SDK',
    () async {
      final f = Fixture();
      addTearDown(f.close);
      final sdk = NoSdk();
      final repo = CheckInRepository(f.db, sdk, f.auth);
      await repo.saveDailyMetrics(energy: 1.25, focus: 2.5, motivation: 3.75);
      expect(await repo.syncPendingCheckIns(), false);
      final row =
          (await f.db.getPendingSyncItems('same')).single as SyncQueueTableData;
      expect(row.collection, 'checkins');
      expect(row.operationType, 'update');
      expect(jsonDecode(row.payloadJson)['localRowId'], isPositive);
      expect((await f.db.getPendingCheckIns()).length, 1);
      expect(sdk.calls, 0);
    },
  );
  for (final wrong in [false, true])
    test(
      'Check-in domain ACK and queue commit atomically; wrong=$wrong',
      () async {
        final f = Fixture();
        addTearDown(f.close);
        final repo = CheckInRepository(f.db, NoSdk(), f.auth);
        await repo.saveDailyMetrics(energy: 1.25, focus: 2.5, motivation: 3.75);
        await repo.syncPendingCheckIns();
        final row =
            (await f.db.getPendingSyncItems('same')).single
                as SyncQueueTableData;
        f.handler = (r) async {
          final b = jsonDecode(r.body) as Map<String, dynamic>;
          expect(b['operation'], 'upsert_checkin');
          expect(b.containsKey('localRowId'), false);
          return success(
            r,
            body: {...b, 'success': true, if (wrong) 'energy': 9.5},
          );
        };
        final source = FirestoreSyncRemoteDataSource(
          Store(),
          f.auth,
          trustedTransport: f.transport,
        );
        final result = await source.process('same', row);
        expect(result.isSuccess, !wrong);
        expect(
          (await f.db.getSyncItemById(row.id) as SyncQueueTableData).isSynced,
          !wrong,
        );
        expect(
          (await f.db.select(f.db.checkInTable).getSingle()).isSynced,
          !wrong,
        );
        if (wrong) expect(result.code, 'CHECKIN_ACK_INVALID');
      },
    );
  test(
    'an old Check-in ACK cannot mark an identical later edit as synchronized',
    () async {
      final f = Fixture(requestTimeout: const Duration(seconds: 5));
      addTearDown(f.close);
      final repo = CheckInRepository(f.db, NoSdk(), f.auth);
      await repo.saveDailyMetrics(energy: 1.25, focus: 2.5, motivation: 3.75);
      await repo.syncPendingCheckIns();
      final old =
          (await f.db.getPendingSyncItems('same')).single as SyncQueueTableData;
      final reached = Completer<http.Request>(),
          release = Completer<http.Response>();
      addTearDown(() {
        if (!release.isCompleted) release.complete(http.Response('{}', 503));
      });
      f.handler = (r) {
        if (!reached.isCompleted) reached.complete(r);
        return release.future;
      };
      final source = FirestoreSyncRemoteDataSource(
            Store(),
            f.auth,
            trustedTransport: f.transport,
          ),
          sending = source.process('same', old);
      final request = await observedGate(reached.future, sending);
      await repo.saveDailyMetrics(energy: 1.25, focus: 2.5, motivation: 3.75);
      await repo.syncPendingCheckIns();
      final rows = (await f.db.getPendingSyncItems(
        'same',
      )).cast<SyncQueueTableData>();
      expect(rows.length, 2);
      final b = jsonDecode(request.body) as Map<String, dynamic>;
      release.complete(success(request, body: {...b, 'success': true}));
      expect((await sending).isSuccess, true);
      expect(
        (await f.db.select(f.db.checkInTable).getSingle()).isSynced,
        false,
      );
      expect(
        (await f.db.getSyncItemById(rows.last.id) as SyncQueueTableData)
            .isSynced,
        false,
      );
      f.handler = (r) async => success(
        r,
        body: {...jsonDecode(r.body) as Map<String, dynamic>, 'success': true},
      );
      expect((await source.process('same', rows.last)).isSuccess, true);
      expect((await f.db.select(f.db.checkInTable).getSingle()).isSynced, true);
    },
  );
  test(
    'Check-in SQL failure rolls back domain and queue ACK; retry reuses the ID',
    () async {
      final f = Fixture();
      addTearDown(f.close);
      final repo = CheckInRepository(f.db, NoSdk(), f.auth);
      await repo.saveDailyMetrics(energy: 1.25, focus: 2.5, motivation: 3.75);
      await repo.syncPendingCheckIns();
      final row =
              (await f.db.getPendingSyncItems('same')).single
                  as SyncQueueTableData,
          ids = <String>[];
      f.handler = (r) async {
        final c =
            jsonDecode(
                  utf8.decode(
                    base64Url.decode(
                      base64Url.normalize(r.headers['X-LifeOS-Operation']!),
                    ),
                  ),
                )
                as Map;
        ids.add(c['operationId'] as String);
        return success(
          r,
          body: {
            ...jsonDecode(r.body) as Map<String, dynamic>,
            'success': true,
          },
        );
      };
      await f.db.customStatement(
        "CREATE TRIGGER block_checkin_ack BEFORE UPDATE ON check_in_table WHEN NEW.is_synced=1 BEGIN SELECT RAISE(ABORT,'injected Check-in ACK failure'); END",
      );
      final source = FirestoreSyncRemoteDataSource(
        Store(),
        f.auth,
        trustedTransport: f.transport,
      );
      expect((await source.process('same', row)).isSuccess, false);
      expect(
        (await f.db.getSyncItemById(row.id) as SyncQueueTableData).isSynced,
        false,
      );
      expect(
        (await f.db.select(f.db.checkInTable).getSingle()).isSynced,
        false,
      );
      await f.db.customStatement('DROP TRIGGER block_checkin_ack');
      expect((await source.process('same', row)).isSuccess, true);
      expect(ids.length, 2);
      expect(ids.first, ids.last);
      expect((await f.db.select(f.db.checkInTable).getSingle()).isSynced, true);
    },
  );
  test(
    'read-only reconciliation cannot execute a domain mutation ACK',
    () async {
      final f = Fixture();
      addTearDown(f.close);
      final intent = await f.intent();
      var called = false;
      await expectLater(
        f.transport.send(
          intent,
          acknowledgeDomain: () async {
            called = true;
          },
        ),
        throwsStateError,
      );
      expect(called, false);
      expect((await f.store.pending()).length, 1);
    },
  );

  for (final outcome in ['DELETED', 'ABSENT', 'OBSOLETE', 'WRONG_KEY']) {
    test(
      'notification HTTP exact domain ACK before queue retirement: $outcome',
      () async {
        final f = Fixture();
        addTearDown(f.close);
        final key = jsonEncode([1, 'habit_daily', 'habits', 1760000000123456]);
        final id = await f.db.insertSyncItem(
          ownerUid: 'same',
          collection: 'notifications',
          docId: 'habit_daily',
          operationType: 'delete',
          payloadJson: jsonEncode({'occurrenceKey': key}),
          createdAt: 1234,
        );
        final row = await f.db.getSyncItemById(id) as SyncQueueTableData;
        var sends = 0;
        f.handler = (request) async {
          sends++;
          expect(jsonDecode(request.body), {
            'operation': 'delete_notification',
            'notificationId': 'habit_daily',
            'occurrenceKey': key,
          });
          return success(
            request,
            body: {
              'success': true,
              'operation': 'delete_notification',
              'notificationId': 'habit_daily',
              'occurrenceKey': outcome == 'WRONG_KEY' ? 'wrong' : key,
              'outcome': outcome == 'WRONG_KEY' ? 'DELETED' : outcome,
            },
          );
        };
        final source = FirestoreSyncRemoteDataSource(
          Store(),
          f.auth,
          trustedTransport: f.transport,
        );
        final result = await source.process('same', row);
        expect(sends, 1);
        if (outcome == 'WRONG_KEY') {
          expect(result.isSuccess, false);
          expect(result.code, 'NOTIFICATION_DELETE_ACK_INVALID');
          expect(
            (await f.db.getSyncItemById(id) as SyncQueueTableData).isSynced,
            false,
          );
        } else {
          expect(result.isSuccess, true);
          expect(result.acknowledgedByTransport, true);
          expect(
            (await f.db.getSyncItemById(id) as SyncQueueTableData).isSynced,
            true,
          );
        }
      },
    );
  }

  TestWidgetsFlutterBinding.ensureInitialized();
  late Fixture f;
  setUp(() => f = Fixture());
  tearDown(() => f.close());
  test(
    'independent installations and a recreated database never alias an intent',
    () async {
      final second = Fixture(), third = Fixture();
      addTearDown(second.close);
      addTearDown(third.close);
      final a = await f.row(), b = await second.row(), c = await third.row();
      expect([a.id, b.id, c.id], [1, 1, 1]);
      final ids = <String>{};
      for (final pair in [(f, a), (second, b), (third, c)]) {
        final i = await pair.$1.store.prepare(
          stableKey: 'sync/1',
          route: 'sync',
          body: {
            'operation': 'update_task',
            'taskId': 'task',
            'isCompleted': true,
          },
          syncRow: pair.$2,
        );
        ids.add(i.operationId);
        expect(
          (await pair.$1.store.prepare(
            stableKey: 'sync/1',
            route: i.route,
            body: i.body,
            syncRow: pair.$2,
          )).operationId,
          i.operationId,
        );
      }
      expect(ids, hasLength(3));
      expect(ids.every((id) => RegExp(r'^[a-f0-9]{64}$').hasMatch(id)), isTrue);
    },
  );
  test(
    'remote reply loss and 409 never mint a new intent or ACK UNKNOWN',
    () async {
      final original = await f.intent();
      final contexts = <String>[];
      f.handler = (request) async {
        contexts.add(request.headers['X-LifeOS-Operation']!);
        if (contexts.length == 1)
          throw http.ClientException('reply lost after remote commit');
        if (contexts.length == 2) return http.Response('{}', 409);
        return success(request);
      };
      for (var attempt = 0; attempt < 2; attempt++) {
        final retry = await f.intent();
        expect(retry.operationId, original.operationId);
        await expectLater(
          f.transport.send(retry),
          throwsA(isA<HttpCustodyException>()),
        );
        expect(
          (await f.store.pending()).single.operationId,
          original.operationId,
        );
      }
      await f.transport.send(await f.intent());
      expect(contexts.toSet(), hasLength(1));
      expect(await f.store.pending(), isEmpty);
    },
  );
  for (final phase in ['PENDING', 'CONFIRMED']) {
    test(
      'legacy $phase is preserved without rekey, dispatch or ambiguous ACK',
      () async {
        final id = httpDigest({'binding': f.scope.toBinding(), 'key': 'one'});
        await f.db.customStatement(
          '''CREATE TABLE generational_http_intents_v1 (
        operation_id TEXT NOT NULL PRIMARY KEY, route TEXT NOT NULL,
        body_json TEXT NOT NULL, binding_json TEXT NOT NULL,
        sync_fingerprint TEXT, sync_id INTEGER, phase TEXT NOT NULL,
        response_json TEXT, ack_json TEXT)''',
        );
        await f.db.customStatement(
          'INSERT INTO generational_http_intents_v1 '
          '(operation_id,route,body_json,binding_json,phase) VALUES (?,?,?,?,?)',
          [
            id,
            'activity/task-complete',
            httpCanonical({'taskId': 'task'}),
            httpCanonical(f.scope.toBinding()),
            phase,
          ],
        );
        await expectLater(
          f.intent(),
          throwsA(
            predicate(
              (e) =>
                  e.toString().contains('HTTP_LEGACY_INTENT_REVIEW_REQUIRED'),
            ),
          ),
        );
        final rows = await f.db
            .customSelect('SELECT * FROM generational_http_intents_v1')
            .get();
        expect(rows, hasLength(1));
        expect(rows.single.read<String>('operation_id'), id);
        expect(rows.single.read<String>('phase'), phase);
        expect(rows.single.readNullable<String>('intent_key'), isNull);
        final review = (await f.store.legacyForReview()).single;
        expect(review.protocolVersion, 1);
        expect(review.context['v'], 1);
        expect(review.operationId, id);
        if (phase == 'PENDING') {
          var dispatched = false;
          f.handler = (r) async {
            dispatched = true;
            return success(r);
          };
          await expectLater(
            f.transport.send((await f.store.pending()).single),
            throwsStateError,
          );
          expect(dispatched, isFalse);
        }
      },
    );
  }
  ProviderContainer focusContainer() {
    final transport = f.transport; // bind the existing fixture before build.
    return ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(f.db),
        firebaseAuthProvider.overrideWithValue(f.auth),
        focusRemoteDataSourceProvider.overrideWith((ref) {
          final source = FocusRemoteDataSource(trustedTransport: transport);
          ref.onDispose(source.close);
          return source;
        }),
      ],
    );
  }

  Map<String, dynamic> focusStart() => {
    'status': 'RUNNING',
    'sessionId': 's',
    'plannedDurationSeconds': 60,
    'startedAt': '2026-11-03T12:00:00.000Z',
    'expiresAt': '2026-11-03T12:11:00.000Z',
    'reused': false,
  };
  Map<String, dynamic> focusStatus(String status) => {
    'status': status,
    'sessionId': 's',
    'targetId': 'task',
    'targetType': 'TASK',
    'plannedDurationSeconds': 60,
    'remainingSeconds': status == 'RUNNING' ? 42 : 0,
  };
  for (final terminal in [false, true]) {
    test(
      'Focus controller persists start then reconciles current ${terminal ? 'terminal' : 'running'} state before timer',
      () async {
        final container = focusContainer();
        addTearDown(container.dispose);
        final statusEntered = Completer<http.Request>(),
            release = Completer<http.Response>();
        f.handler = (r) async {
          if (r.url.path.endsWith('/status')) {
            statusEntered.complete(r);
            return release.future;
          }
          return success(r, body: focusStart());
        };
        final notifier = container.read(focusProvider.notifier);
        notifier.selectTarget('task', 'Task', FocusTargetType.task);
        notifier.setCustomDuration(1);
        notifier.startTimer();
        final request = await statusEntered.future;
        expect(container.read(focusProvider).isRunning, isFalse);
        release.complete(
          success(
            request,
            body: focusStatus(terminal ? 'CANCELLED' : 'RUNNING'),
          ),
        );
        await pumpEventQueue(times: 30);
        final state = container.read(focusProvider);
        expect(state.isRunning, isTrue);
        expect(state.isVerified, !terminal);
        expect(state.durationRemaining, terminal ? 60 : 42);
        expect(await f.store.pending(), isEmpty);
      },
    );
  }
  test(
    'Focus lost start response survives controller restart without new ID or false verification',
    () async {
      var container = focusContainer();
      final ids = <String>[];
      f.handler = (r) async {
        if (r.url.path.endsWith('/start')) {
          ids.add(r.headers['X-LifeOS-Operation']!);
          if (ids.length == 1)
            throw http.ClientException('committed start reply lost');
          return success(r, body: focusStart());
        }
        return success(r, body: focusStatus('CANCELLED'));
      };
      void start(ProviderContainer c) {
        final n = c.read(focusProvider.notifier);
        n.selectTarget('task', 'Task', FocusTargetType.task);
        n.setCustomDuration(1);
        n.startTimer();
      }

      start(container);
      await pumpEventQueue(times: 40);
      expect(container.read(focusProvider).isVerified, isFalse);
      expect((await f.store.pending()).single.route, 'focus/start');
      container.dispose();
      container = focusContainer();
      addTearDown(container.dispose);
      start(container);
      await pumpEventQueue(times: 40);
      expect(ids, hasLength(2));
      expect(ids.first, ids.last);
      expect(container.read(focusProvider).isVerified, isFalse);
      expect(await f.store.pending(), isEmpty);
    },
  );
  test('domain receipt refusal precedes transport SQL ACK', () async {
    final i = await f.intent();
    await expectLater(
      f.transport.send(
        i,
        validateResponse: (_) {
          throw const HttpCustodyException('DOMAIN_ACK_INVALID');
        },
      ),
      throwsA(isA<HttpCustodyException>()),
    );
    expect((await f.store.pending()).single.operationId, i.operationId);
  });
  test(
    'trusted F01 requires its domain receipt before the Sync row ACK',
    () async {
      final id = await f.db.insertSyncItem(
        ownerUid: 'same',
        collection: 'review_queue',
        docId: 'card',
        operationType: 'create',
        payloadJson: jsonEncode({
          'creationProtocolVersion': 1,
          'cardId': 'card',
          'subjectId': 'study',
          'question': 'Q',
          'answer': 'A',
          'createdAt': '2026-11-03T12:00:00.000Z',
        }),
        createdAt: 1,
      );
      final source = FirestoreSyncRemoteDataSource(
        Store(),
        f.auth,
        trustedTransport: f.transport,
      );
      // The HTTP context/hash is correct; the server domain confirmation is not.
      f.handler = (r) async => success(r, body: {'ok': true});
      final result = await source.process(
        'same',
        await f.db.getSyncItemById(id) as SyncQueueTableData,
      );
      expect(result.isSuccess, isFalse);
      expect(result.code, 'REVIEW_CREATE_ACK_INVALID');
      expect(
        (await f.db.getSyncItemById(id) as SyncQueueTableData).isSynced,
        isFalse,
      );
      expect((await f.store.pending()).single.syncId, id);
    },
  );
  test('read contexts cannot acknowledge a pending mutation row', () async {
    final row = await f.row();
    await expectLater(
      f.store.prepare(
        stableKey: 'wrong-route',
        route: 'focus/status',
        body: {'sessionId': 's'},
        syncRow: row,
      ),
      throwsStateError,
    );
    expect(
      (await f.db.getSyncItemById(row.id) as SyncQueueTableData).isSynced,
      isFalse,
    );
    expect(await f.store.pending(), isEmpty);
  });
  for (final phase in ['PENDING', 'CONFIRMED']) {
    test(
      'intermediate keyed v1 $phase keeps original ID/context and requires review',
      () async {
        const id =
            'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff';
        await f.db.customStatement(
          '''CREATE TABLE generational_http_intents_v1 (
        operation_id TEXT NOT NULL PRIMARY KEY, route TEXT NOT NULL,
        body_json TEXT NOT NULL, binding_json TEXT NOT NULL,
        sync_fingerprint TEXT, sync_id INTEGER, phase TEXT NOT NULL,
        response_json TEXT, ack_json TEXT, intent_key TEXT UNIQUE)''',
        );
        await f.db.customStatement(
          'INSERT INTO generational_http_intents_v1 '
          '(operation_id,route,body_json,binding_json,phase,intent_key) VALUES (?,?,?,?,?,?)',
          [
            id,
            'activity/task-complete',
            httpCanonical({'taskId': 'task'}),
            httpCanonical(f.scope.toBinding()),
            phase,
            'one',
          ],
        );
        await expectLater(
          f.intent(),
          throwsA(
            predicate(
              (e) =>
                  e.toString().contains('HTTP_LEGACY_INTENT_REVIEW_REQUIRED'),
            ),
          ),
        );
        final review = (await f.store.legacyForReview()).single;
        expect(review.operationId, id);
        expect(review.context['v'], 1);
        expect(
          (await f.db
                  .customSelect(
                    'SELECT phase FROM generational_http_intents_v1',
                  )
                  .getSingle())
              .read<String>('phase'),
          phase,
        );
        var sends = 0;
        f.handler = (r) async {
          sends++;
          return success(r);
        };
        await expectLater(f.transport.send(review), throwsStateError);
        expect(sends, 0);
      },
    );
  }
  test(
    'original A token and operation ACK confirm only original durable intent',
    () async {
      final i = await f.intent();
      expect(i.context['v'], 2);
      expect((await f.store.pending()).single.operationId, i.operationId);
      expect(await f.transport.send(i), {'ok': true});
      expect(await f.store.pending(), isEmpty);
    },
  );
  test(
    'SDK-style fresh User wrappers do not stand in for generation proof',
    () async {
      f.auth.person = Person('same');
      final i = await f.intent();
      await f.transport.send(i);
      expect(await f.store.pending(), isEmpty);
    },
  );
  for (final which in [
    'different UID',
    'same UID new generation',
    'project',
    'tenant',
  ])
    test('token mismatch $which refuses before HTTP', () async {
      final i = await f.intent();
      int sends = 0;
      f.handler = (r) async {
        sends++;
        return success(r);
      };
      f.load = (u, r) async => switch (which) {
        'different UID' => token(ga, uid: 'B'),
        'project' => token(ga, project: 'demo-other'),
        'tenant' => token(ga, tenant: 'B'),
        _ => token(gb),
      };
      await expectLater(
        f.transport.send(i),
        throwsA(isA<HttpCustodyException>()),
      );
      expect(sends, 0);
      expect(await f.store.pending(), hasLength(1));
    });
  test(
    '401 refresh retains original User, operation ID, body and authorization generation',
    () async {
      final i = await f.intent();
      final ids = <String>[];
      final users = <User>[];
      final refresh = <bool>[];
      f.load = (u, r) async {
        users.add(u);
        refresh.add(r);
        return token(ga);
      };
      f.handler = (r) async {
        ids.add(r.headers['X-LifeOS-Operation']!);
        return ids.length == 1 ? http.Response('{}', 401) : success(r);
      };
      await f.transport.send(i);
      expect(ids, hasLength(2));
      expect(ids.first, ids.last);
      expect(identical(users.first, users.last), isTrue);
      expect(refresh, [false, true]);
    },
  );
  test(
    '401 refresh returning B same UID is refused before second dispatch',
    () async {
      final i = await f.intent();
      int sends = 0;
      f.handler = (r) async {
        sends++;
        return http.Response('{}', 401);
      };
      f.load = (u, r) async => token(r ? gb : ga);
      await expectLater(
        f.transport.send(i),
        throwsA(isA<HttpCustodyException>()),
      );
      expect(sends, 1);
      expect(await f.store.pending(), hasLength(1));
    },
  );
  test(
    'same UID SDK session changes generation without an Auth event; active claims still refuse',
    () async {
      final i = await f.intent(),
          entered = Completer<void>(),
          release = Completer<void>();
      f.appCheck = () async {
        entered.complete();
        await release.future;
        return 'synthetic';
      };
      int sends = 0;
      f.handler = (r) async {
        sends++;
        return success(r);
      };
      final send = f.transport.send(i);
      final error = expectLater(send, throwsA(isA<HttpCustodyException>()));
      await entered.future;
      f.auth.person = Person('same', gb);
      release.complete();
      await error;
      expect(sends, 0);
      expect(await f.store.pending(), hasLength(1));
    },
  );
  test(
    'Auth A to B to A invalidates captured attempt despite UID equality',
    () async {
      final i = await f.intent(),
          entered = Completer<void>(),
          release = Completer<void>();
      f.appCheck = () async {
        entered.complete();
        await release.future;
        return 'synthetic';
      };
      int sends = 0;
      f.handler = (r) async {
        sends++;
        return success(r);
      };
      final send = f.transport.send(i);
      final error = expectLater(send, throwsA(isA<HttpCustodyException>()));
      await entered.future;
      f.auth.change(Person('same'));
      f.auth.change(Person('same'));
      release.complete();
      await error;
      expect(sends, 0);
    },
  );
  test(
    'timeout then late response never ACKs or deletes pending intent',
    () async {
      final i = await f.intent(),
          late = Completer<http.Response>(),
          entered = Completer<http.Request>();
      f.handler = (r) {
        entered.complete(r);
        return late.future;
      };
      final send = f.transport.send(i);
      final request = await entered.future;
      await expectLater(
        send,
        throwsA(predicate((e) => e.toString() == 'HTTP_UNKNOWN_TIMEOUT')),
      );
      late.complete(success(request));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(await f.store.pending(), hasLength(1));
    },
  );
  for (final wrong in [false, true])
    test(
      'UNKNOWN ${wrong ? 'mismatched' : 'missing'} ACK preserves intent',
      () async {
        final i = await f.intent();
        f.handler = (r) async => success(r, missing: !wrong, wrong: wrong);
        await expectLater(
          f.transport.send(i),
          throwsA(isA<HttpCustodyException>()),
        );
        expect(await f.store.pending(), hasLength(1));
      },
    );
  test(
    'late A response after local B binding cannot ACK A or touch B',
    () async {
      final i = await f.intent(),
          response = Completer<http.Response>(),
          entered = Completer<http.Request>();
      f.handler = (r) {
        entered.complete(r);
        return response.future;
      };
      final send = f.transport.send(i);
      final error = expectLater(send, throwsA(isA<StateError>()));
      final r = await entered.future;
      f.session.bind(identity(gb));
      response.complete(success(r));
      await error;
      expect(await f.store.pending(), hasLength(1));
    },
  );
  test('intent payload cannot be rebound on retry', () async {
    final i = await f.intent();
    await expectLater(
      f.store.prepare(stableKey: 'one', route: i.route, body: {'taskId': 'B'}),
      throwsStateError,
    );
    expect((await f.store.pending()).single.body, {'taskId': 'task'});
  });
  test(
    'Sync row ACK and receipt commit together through real Sync mapping',
    () async {
      final row = await f.row();
      final source = FirestoreSyncRemoteDataSource(
        Store(),
        f.auth,
        trustedTransport: f.transport,
      );
      final result = await source.process('same', row);
      expect(result.isSuccess, isTrue);
      expect(result.acknowledgedByTransport, isTrue);
      final saved = await f.db.getSyncItemById(row.id) as SyncQueueTableData;
      expect(saved.isSynced, isTrue);
      expect(saved.attemptCount, 1);
      expect(await f.store.pending(), isEmpty);
    },
  );
  test(
    'Sync row replacement while in flight cannot receive the old ACK',
    () async {
      final row = await f.row(),
          response = Completer<http.Response>(),
          entered = Completer<http.Request>();
      f.handler = (r) {
        entered.complete(r);
        return response.future;
      };
      final source = FirestoreSyncRemoteDataSource(
        Store(),
        f.auth,
        trustedTransport: f.transport,
      );
      final send = source.process('same', row);
      final r = await entered.future;
      await f.db.transaction(
        () =>
            (f.db.update(
              f.db.syncQueueTable,
            )..where((t) => t.id.equals(row.id))).write(
              const SyncQueueTableCompanion(
                payloadJson: Value('{"isCompleted":false}'),
              ),
            ),
      );
      response.complete(success(r));
      expect((await send).shouldRetry, isTrue);
      final saved = await f.db.getSyncItemById(row.id) as SyncQueueTableData;
      expect(saved.isSynced, isFalse);
      expect(saved.payloadJson, '{"isCompleted":false}');
      expect(await f.store.pending(), hasLength(1));
    },
  );
  test(
    'trusted Sync never falls through to generic SDK; HOLD bytes remain',
    () async {
      final row = await f.row();
      final held = row.copyWith(collection: 'study_info', docId: 'main');
      final source = FirestoreSyncRemoteDataSource(
        Store(),
        f.auth,
        trustedTransport: f.transport,
      );
      expect(
        (await source.process('same', held)).code,
        'STUDY_INFO_LEGACY_HOLD',
      );
      final sdk = row.copyWith(collection: 'health_info');
      expect(
        (await source.process('same', sdk)).code,
        'HTTP_CUSTODY_ROUTE_CLOSED',
      );
      expect(
        (await f.db.getSyncItemById(row.id) as SyncQueueTableData).isSynced,
        isFalse,
      );
    },
  );
  test(
    'Activity real client implementation uses prepared intent and validates response',
    () async {
      final activity = ActivityRemoteDataSource(trustedTransport: f.transport);
      addTearDown(activity.close);
      final i = await activity.prepareTrusted(
        stableKey: 'activity',
        operation: 'task-complete',
        payload: {'taskId': 'task'},
      );
      f.handler = (r) async => success(
        r,
        body: {
          'type': 'TASK_COMPLETION',
          'resourceId': 'task',
          'occurredAt': '2026-11-02T12:00:00.000Z',
          'replayed': false,
        },
      );
      expect(
        (await activity.completeTask(taskId: 'task', intent: i)).resourceId,
        'task',
      );
      await expectLater(
        activity.completeTask(taskId: 'task'),
        throwsA(isA<HttpCustodyException>()),
      );
    },
  );
  test(
    'Focus start/cancel/finish use original durable handles without changing body contracts',
    () async {
      final focus = FocusRemoteDataSource(trustedTransport: f.transport);
      addTearDown(focus.close);
      final start = await focus.prepareTrusted(
        stableKey: 'focus/1',
        operation: 'start',
        payload: {
          'targetId': 'task',
          'targetType': 'TASK',
          'plannedDurationSeconds': 60,
        },
      );
      f.handler = (r) async => success(
        r,
        body: {
          'status': 'RUNNING',
          'sessionId': 's',
          'plannedDurationSeconds': 60,
          'startedAt': '2026-11-02T12:00:00.000Z',
          'expiresAt': '2026-11-02T12:11:00.000Z',
          'reused': false,
        },
      );
      expect(
        (await focus.startFocus(
          targetId: 'task',
          targetType: FocusRemoteTargetType.task,
          plannedDurationSeconds: 60,
          intent: start,
        )).sessionId,
        's',
      );
      final cancel = await focus.prepareTrusted(
        stableKey: 'focus/1/cancel',
        operation: 'cancel',
        payload: {'sessionId': 's'},
      );
      f.handler = (r) async => success(
        r,
        body: {
          'status': 'CANCELLED',
          'sessionId': 's',
          'cancelledAt': '2026-11-02T12:01:00.000Z',
          'replayed': false,
        },
      );
      expect(
        (await focus.cancelFocus(sessionId: 's', intent: cancel)).sessionId,
        's',
      );
      final finish = await focus.prepareTrusted(
        stableKey: 'focus/2/finish',
        operation: 'finish',
        payload: {'sessionId': 's2'},
      );
      f.handler = (r) async => success(
        r,
        body: {
          'status': 'COMPLETED',
          'sessionId': 's2',
          'completedAt': '2026-11-02T12:01:00.000Z',
          'verifiedDurationSeconds': 60,
          'replayed': false,
        },
      );
      expect(
        (await focus.finishFocus(sessionId: 's2', intent: finish)).sessionId,
        's2',
      );
    },
  );
  test(
    'process restart retains original SyncQueue, intent ID and binding on disk',
    () async {
      final dir = await Directory.systemTemp.createTemp('lifeos-http-test-'),
          file = File('${dir.path}/scope.sqlite');
      try {
        final db = AppDatabase.forUser(
          identity: identity(ga),
          executor: NativeDatabase(file),
        );
        final store = GenerationalHttpStore(db);
        final id = await db.insertSyncItem(
          ownerUid: 'same',
          collection: 'tasks',
          docId: 'task',
          operationType: 'update',
          payloadJson: '{"isCompleted":true}',
          createdAt: 1234,
        );
        final row = await db.getSyncItemById(id) as SyncQueueTableData;
        final i = await store.prepare(
          stableKey: 'sync/$id',
          route: 'sync',
          body: {
            'operation': 'update_task',
            'taskId': 'task',
            'isCompleted': true,
          },
          syncRow: row,
        );
        await db.close();
        final reopened = AppDatabase.forUser(
          identity: identity(ga),
          executor: NativeDatabase(file),
        );
        try {
          final resumed = GenerationalHttpStore(reopened);
          expect((await resumed.pending()).single.operationId, i.operationId);
          expect(
            (await reopened.getSyncItemById(id) as SyncQueueTableData).isSynced,
            isFalse,
          );
          expect((await resumed.pending()).single.context, i.context);
        } finally {
          await reopened.close();
        }
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );
  test(
    'actual Manager never reopens an ACKed row after a lost local completion response',
    () async {
      final row = await f.row();
      final manager = SyncManager(
        queueStore: AppDatabaseSyncQueueStore(f.db),
        remoteDataSource: AfterLocalCommit(f.db),
        currentUserId: () => 'same',
      );
      try {
        expect(await manager.processPendingItems(), isFalse);
        final saved = await f.db.getSyncItemById(row.id) as SyncQueueTableData;
        expect(saved.isSynced, isTrue);
        expect(saved.status, SyncQueuePersistenceStatus.succeeded);
        expect(saved.attemptCount, 1);
      } finally {
        manager.dispose();
      }
    },
  );
  test(
    'actual Manager with real trusted Sync performs exactly one SQL ACK',
    () async {
      final row = await f.row();
      final manager = SyncManager(
        queueStore: AppDatabaseSyncQueueStore(f.db),
        remoteDataSource: FirestoreSyncRemoteDataSource(
          Store(),
          f.auth,
          trustedTransport: f.transport,
        ),
        currentUserId: () => 'same',
      );
      try {
        expect(await manager.processPendingItems(), isTrue);
        final saved = await f.db.getSyncItemById(row.id) as SyncQueueTableData;
        expect(saved.isSynced, isTrue);
        expect(saved.attemptCount, 1);
      } finally {
        manager.dispose();
      }
    },
  );
  test(
    'concurrent same UID A/B transports use independent bindings, journals and ACKs',
    () async {
      final b = Fixture(generation: gb);
      b.auth.person = Person('same', gb);
      b.load = (u, r) async => token(gb);
      addTearDown(b.close);
      final aIntent = await f.intent(), bIntent = await b.intent();
      expect(aIntent.operationId, isNot(bIntent.operationId));
      final results = await Future.wait([
        f.transport.send(aIntent),
        b.transport.send(bIntent),
      ]);
      expect(results, [
        {'ok': true},
        {'ok': true},
      ]);
      expect(await f.store.pending(), isEmpty);
      expect(await b.store.pending(), isEmpty);
    },
  );
  test(
    'legacy Activity provider requires neither Firebase nor a prepared generation database',
    () {
      final container = ProviderContainer();
      try {
        expect(container.read(generationalHttpTransportProvider), isNull);
        expect(
          container.read(activityRemoteDataSourceProvider),
          isA<ActivityRemoteDataSource>(),
        );
      } finally {
        container.dispose();
      }
    },
  );
}
