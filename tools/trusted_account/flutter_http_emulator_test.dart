// ignore_for_file: subtype_of_sealed_class, must_be_immutable
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:drift/native.dart';
import 'package:http/http.dart' as http;
import 'package:life_os/core/database/app_database.dart' hide Transaction;
import 'package:life_os/core/database/local_account_session.dart';
import 'package:life_os/core/database/local_database_identity.dart';
import 'package:life_os/core/network/generational_http_store.dart';
import 'package:life_os/core/network/generational_http_transport.dart';
import 'package:life_os/core/network/activity_remote_data_source.dart';
import 'package:life_os/core/services/sync_remote_data_source.dart';
import 'package:life_os/features/focus/data/remote/focus_remote_data_source.dart';

// Flutter Auth/plugin port supplies GENUINE demo Auth Emulator tokens. This is
// not a native Android/iOS Firebase SDK or Cloud App Check/IAM validation.
class App extends Fake implements FirebaseApp {
  @override
  FirebaseOptions get options => const FirebaseOptions(
    apiKey: 'demo-key',
    appId: 'demo-app',
    messagingSenderId: 'demo',
    projectId: 'demo-life-os',
  );
}

class Result extends Fake implements IdTokenResult {
  Result(this.value);
  final Map<String, dynamic> value;
  @override
  Map<String, dynamic> get claims => value;
}

class Person extends Fake implements User {
  Person(this.id, this.claims);
  final String id;
  final Map<String, dynamic> claims;
  @override
  String get uid => id;
  @override
  Future<IdTokenResult> getIdTokenResult([bool forceRefresh = false]) async =>
      Result(claims);
}

class Auth extends Fake implements FirebaseAuth {
  Auth(this.id, this.claims);
  final String id;
  final Map<String, dynamic> claims;
  final events = StreamController<User?>.broadcast(sync: true);
  @override
  User get currentUser => Person(id, claims); // Same behavior as SDK's new wrapper.
  @override
  FirebaseApp get app => App();
  @override
  String? get tenantId => null;
  @override
  Stream<User?> authStateChanges() => events.stream;
}

class FirestorePort extends Fake implements FirebaseFirestore {}

// Real loopback integration only: the default widget binding intercepts all
// HTTP as synthetic 400. The production transport still restricts demo+loopback.
class LoopbackHttpBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

void main() {
  LoopbackHttpBinding();
  test(
    'Flutter real HTTP -> actual gateways -> provider-created Auth and Firestore atomic receipts',
    () async {
      final input = Platform.environment['R5_FLUTTER_FIXTURE'];
      if (input == null) throw StateError('ISOLATED_EMULATOR_FIXTURE_REQUIRED');
      final v =
          jsonDecode(await File(input).readAsString()) as Map<String, dynamic>;
      final identity = LocalDatabaseIdentity.bound(
        projectId: 'demo-life-os',
        databaseId: '(default)',
        uid: v['uid'] as String,
        generation: v['generation'] as String,
      );
      final container = ProviderContainer(),
          auth = Auth(
            identity.uid,
            jsonDecode(
                  utf8.decode(
                    base64Url.decode(
                      base64Url.normalize((v['token'] as String).split('.')[1]),
                    ),
                  ),
                )
                as Map<String, dynamic>,
          ),
          db = AppDatabase.forUser(
            identity: identity,
            executor: NativeDatabase.memory(),
          ),
          client = http.Client();
      final session = container.read(localAccountSessionProvider.notifier)
            ..bind(identity),
          store = GenerationalHttpStore(db);
      final transport = GenerationalHttpTransport(
        store: store,
        lease: session.capture(),
        auth: auth,
        client: client,
        appCheckToken: () async => 'synthetic-app-check-port',
        baseUri: Uri.parse(v['baseUrl'] as String),
        timeout: const Duration(seconds: 5),
        idToken: (u, r) async => v['token'] as String,
      );
      final source = FirestoreSyncRemoteDataSource(
        FirestorePort(),
        auth,
        trustedTransport: transport,
      );
      try {
        final id = await db.insertSyncItem(
          ownerUid: identity.uid,
          collection: 'tasks',
          docId: 'flutter-task',
          operationType: 'create',
          payloadJson: jsonEncode({
            'title': 'Flutter genuine HTTP',
            'priority': 'low',
            'date': '2026-11-02T12:00:00.000Z',
          }),
          createdAt: 1234,
        );
        final row = await db.getSyncItemById(id) as SyncQueueTableData;
        final result = await source.process(identity.uid, row);
        expect(result.isSuccess, isTrue, reason: result.code);
        expect(result.acknowledgedByTransport, isTrue);
        expect(
          (await db.getSyncItemById(id) as SyncQueueTableData).isSynced,
          isTrue,
        );
        final update = await db.insertSyncItem(
          ownerUid: identity.uid,
          collection: 'tasks',
          docId: 'flutter-task',
          operationType: 'update',
          payloadJson: '{"isCompleted":true}',
          createdAt: 1235,
        );
        expect(
          (await source.process(
            identity.uid,
            await db.getSyncItemById(update) as SyncQueueTableData,
          )).isSuccess,
          isTrue,
        );
        final activity = ActivityRemoteDataSource(trustedTransport: transport);
        try {
          final i = await activity.prepareTrusted(
            stableKey: 'flutter-activity',
            operation: 'task-complete',
            payload: {'taskId': 'flutter-task'},
          );
          expect(
            (await activity.completeTask(
              taskId: 'flutter-task',
              intent: i,
            )).resourceId,
            'flutter-task',
          );
        } finally {
          activity.close();
        }
        final focus = FocusRemoteDataSource(trustedTransport: transport);
        try {
          final i = await focus.prepareTrusted(
            stableKey: 'flutter-focus',
            operation: 'start',
            payload: {
              'targetId': 'flutter-task',
              'targetType': 'TASK',
              'plannedDurationSeconds': 60,
            },
          );
          final first = await focus.startFocus(
            targetId: 'flutter-task',
            targetType: FocusRemoteTargetType.task,
            plannedDurationSeconds: 60,
            intent: i,
          );
          final cancel = await focus.prepareTrusted(
            stableKey: 'flutter-focus-cancel',
            operation: 'cancel',
            payload: {'sessionId': first.sessionId},
          );
          expect(
            (await focus.cancelFocus(
              sessionId: first.sessionId,
              intent: cancel,
            )).sessionId,
            first.sessionId,
          );
          expect(
            (await focus.startFocus(
              targetId: 'flutter-task',
              targetType: FocusRemoteTargetType.task,
              plannedDurationSeconds: 60,
              intent: i,
            )).sessionId,
            first.sessionId,
          );
        } finally {
          focus.close();
        }
        expect(await store.pending(), isEmpty);
      } finally {
        await transport.close();
        client.close();
        await auth.events.close();
        await db.close();
        container.dispose();
      }
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
