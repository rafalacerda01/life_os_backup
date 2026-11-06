import 'package:life_os/features/checkin/data/repositories/checkin_repository.dart';
import 'package:life_os/core/services/sync_manager.dart';
import 'package:life_os/core/services/sync_queue_store.dart';
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
    'real Sync data source maps admitted modules and ACKs original rows only',
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
      final operations = <(String, String, String, Map<String, dynamic>)>[
        (
          'transactions',
          'money',
          'create',
          {
            'title': 'Decimal',
            'amount': 12.34,
            'type': 'expense',
            'category': 'Food',
            'date': '2026-11-03T12:00:00.000Z',
          },
        ),
        ('transactions', 'money', 'delete', {}),
        (
          'goals',
          'goal',
          'create',
          {
            'title': 'Goal',
            'period': 'DIÁRIA',
            'targetValue': 7,
            'createdAt': '2026-11-03T12:00:00.000Z',
          },
        ),
        ('goals', 'goal', 'delete', {}),
        (
          'medications',
          'med',
          'create',
          {
            'name': 'Medicine',
            'startDate': '2026-11-03T12:00:00.000Z',
            'durationDays': null,
            'endDate': null,
          },
        ),
        ('medications', 'med', 'delete', {}),
        (
          'subjects',
          'study',
          'create',
          {'title': 'Study', 'hasExam': false, 'examDate': null},
        ),
        (
          'review_queue',
          'card',
          'create',
          {
            'creationProtocolVersion': 1,
            'cardId': 'card',
            'subjectId': 'study',
            'question': 'Question',
            'answer': 'Answer',
            'createdAt': '2026-11-03T12:00:00.000Z',
          },
        ),
        (
          'review_queue',
          'card',
          'update',
          {
            'subjectId': 'study',
            'lastReviewed': '2026-11-03T12:01:00.000Z',
            'timeZoneOffsetMinutes': 0,
          },
        ),
        (
          'study_activity',
          'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
          'create',
          {
            'subjectId': 'study',
            'progressDelta': 0.05,
            'occurredAt': '2026-11-03T12:02:00.000Z',
            'timeZoneOffsetMinutes': 0,
          },
        ),
        (
          'study_progress_reset',
          'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
          'create',
          {'occurredAt': '2026-11-03T12:03:00.000Z'},
        ),
      ];
      final manager = SyncManager(
        queueStore: AppDatabaseSyncQueueStore(db),
        remoteDataSource: source,
        currentUserId: () => identity.uid,
      );
      try {
        final checkin = CheckInRepository(
          db,
          FirestorePort(),
          auth,
          replaySyncQueue: manager.processPendingItems,
        );
        await checkin.saveDailyMetrics(
          energy: 1.25,
          focus: 2.5,
          motivation: 3.75,
        );
        expect(await checkin.syncPendingCheckIns(), true);
        expect((await db.select(db.checkInTable).getSingle()).isSynced, true);
        expect(await db.getPendingCheckIns(), isEmpty);
        var time = 0;
        for (final op in operations) {
          final id = await db.insertSyncItem(
            ownerUid: identity.uid,
            collection: op.$1,
            docId: op.$2,
            operationType: op.$3,
            payloadJson: jsonEncode(op.$4),
            createdAt: ++time,
          );
          final row = await db.getSyncItemById(id) as SyncQueueTableData,
              result = await source.process(identity.uid, row);
          expect(
            result.isSuccess,
            isTrue,
            reason: '$op code=${result.code}',
          );
          expect(result.acknowledgedByTransport, isTrue);
          expect(
            (await db.getSyncItemById(id) as SyncQueueTableData).isSynced,
            isTrue,
          );
        }
        expect(await store.pending(), isEmpty);
        for (final blocked in [
          ('study_info', 'main', 'update'),
          ('subjects', 'study', 'delete'),
        ]) {
          final id = await db.insertSyncItem(
            ownerUid: identity.uid,
            collection: blocked.$1,
            docId: blocked.$2,
            operationType: blocked.$3,
            payloadJson: '{}',
            createdAt: ++time,
          );
          final result = await source.process(
            identity.uid,
            await db.getSyncItemById(id) as SyncQueueTableData,
          );
          expect(result.isSuccess, isFalse);
          expect(
            (await db.getSyncItemById(id) as SyncQueueTableData).isSynced,
            isFalse,
          );
        }
      } finally {
        manager.dispose();
        await transport.close();
        client.close();
        await auth.events.close();
        await db.close();
        container.dispose();
      }
    },
  );
}
