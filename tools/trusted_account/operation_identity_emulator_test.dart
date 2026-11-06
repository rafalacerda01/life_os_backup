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
    'distinct installations retain distinct durable intentions and original ACKs',
    () async {
      final v =
          jsonDecode(
                await File(
                  Platform.environment['R5_FLUTTER_FIXTURE']!,
                ).readAsString(),
              )
              as Map<String, dynamic>;
      final claims =
          jsonDecode(
                utf8.decode(
                  base64Url.decode(
                    base64Url.normalize((v['token'] as String).split('.')[1]),
                  ),
                ),
              )
              as Map<String, dynamic>;
      final identity = LocalDatabaseIdentity.bound(
        projectId: 'demo-life-os',
        databaseId: '(default)',
        uid: v['uid'] as String,
        generation: v['generation'] as String,
      );
      final dbs = <AppDatabase>[],
          containers = <ProviderContainer>[],
          auths = <Auth>[],
          transports = <GenerationalHttpTransport>[],
          clients = <http.Client>[],
          stores = <GenerationalHttpStore>[];
      for (var n = 0; n < 3; n++) {
        final db = AppDatabase.forUser(
              identity: identity,
              executor: NativeDatabase.memory(),
            ),
            container = ProviderContainer(),
            auth = Auth(identity.uid, claims),
            client = http.Client();
        final session = container.read(localAccountSessionProvider.notifier)
              ..bind(identity),
            store = GenerationalHttpStore(db);
        dbs.add(db);
        containers.add(container);
        auths.add(auth);
        clients.add(client);
        stores.add(store);
        transports.add(
          GenerationalHttpTransport(
            store: store,
            lease: session.capture(),
            auth: auth,
            client: client,
            appCheckToken: () async => 'synthetic-app-check-port',
            baseUri: Uri.parse(v['baseUrl'] as String),
            timeout: const Duration(seconds: 5),
            idToken: (u, r) async => v['token'] as String,
          ),
        );
      }
      Future<SyncQueueTableData> enqueue(
        int device,
        bool completed,
        int time,
      ) async {
        final id = await dbs[device].insertSyncItem(
          ownerUid: identity.uid,
          collection: 'tasks',
          docId: 'shared',
          operationType: 'update',
          payloadJson: jsonEncode({'isCompleted': completed}),
          createdAt: time,
        );
        return await dbs[device].getSyncItemById(id) as SyncQueueTableData;
      }

      Future<GenerationalHttpIntent> prepared(
        int device,
        SyncQueueTableData row,
        bool completed,
      ) => stores[device].prepare(
        stableKey: 'sync/${row.id}',
        route: 'sync',
        body: {
          'operation': 'update_task',
          'taskId': 'shared',
          'isCompleted': completed,
        },
        syncRow: row,
      );
      Future<bool> send(int device, SyncQueueTableData row) async =>
          (await FirestoreSyncRemoteDataSource(
            FirestorePort(),
            auths[device],
            trustedTransport: transports[device],
          ).process(identity.uid, row)).isSuccess;
      try {
        final a1 = await enqueue(0, true, 1000),
            ia = await prepared(0, a1, true);
        expect(await send(0, a1), isTrue);
        final a2 = await enqueue(0, false, 1001);
        expect(await send(0, a2), isTrue);
        final b1 = await enqueue(1, true, 2000),
            ib = await prepared(1, b1, true);
        final acceptedB = await send(1, b1);
        final bRow = await dbs[1].getSyncItemById(b1.id) as SyncQueueTableData;
        final c1 = await enqueue(2, false, 3000),
            ic = await prepared(2, c1, false);
        final cRow = await dbs[2].getSyncItemById(c1.id) as SyncQueueTableData;
        final evidence = {
          'uidSame': true,
          'generationSame': true,
          'independentDatabases': 3,
          'rowIds': [a1.id, b1.id, c1.id],
          'operationIds': [ia.operationId, ib.operationId],
          'sameOperationId': ia.operationId == ib.operationId,
          'distinctIntentCreatedAt': [a1.createdAt, b1.createdAt],
          'bSuccess': acceptedB,
          'bSynced': bRow.isSynced,
          'cContext': ic.context,
          'cSynced': cRow.isSynced,
        };
        await File(
          v['evidenceFile'] as String,
        ).writeAsString(jsonEncode(evidence));
      } finally {
        for (final t in transports) await t.close();
        for (final c in clients) c.close();
        for (final a in auths) await a.events.close();
        for (final db in dbs) await db.close();
        for (final c in containers) c.dispose();
      }
    },
  );
}
