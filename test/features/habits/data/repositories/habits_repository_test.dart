// ignore_for_file: subtype_of_sealed_class

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:life_os/core/database/session_database_coordinator.dart';
import 'package:life_os/core/database/local_mutation_gate.dart';
import 'package:life_os/core/services/sync_manager.dart';
import 'package:life_os/core/services/sync_queue_store.dart';
import 'package:life_os/core/services/sync_remote_data_source.dart';
import 'package:life_os/core/services/notification_preferences.dart';
import 'package:life_os/features/notifications/data/repositories/notifications_repository.dart';
import 'package:life_os/features/notifications/domain/providers/notification_engine.dart';
import '../../../../helpers/test_user_database_factory.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/features/habits/data/repositories/habits_repository.dart';

class MockFirebaseAuth extends Mock implements FirebaseAuth {}

class MockFirebaseUser extends Mock implements User {
  @override
  String get uid => 'user-123';
}

class MockFirebaseFirestore extends Mock implements FirebaseFirestore {}

class _NamedUser extends Fake implements User {
  _NamedUser(this.uid);
  @override
  final String uid;
}

class _MemoryFirestore extends Fake implements FirebaseFirestore {
  final documents = <String, Map<String, dynamic>>{};
  @override
  CollectionReference<Map<String, dynamic>> collection(String path) =>
      _MemoryCollection(this, path);
}

class _MemoryCollection extends Fake
    implements CollectionReference<Map<String, dynamic>> {
  _MemoryCollection(this.store, this.path);
  final _MemoryFirestore store;
  @override
  final String path;
  @override
  DocumentReference<Map<String, dynamic>> doc([String? id]) =>
      _MemoryDocument(store, '$path/${id!}');
  @override
  Future<QuerySnapshot<Map<String, dynamic>>> get([GetOptions? options]) async {
    final prefix = '$path/';
    return _MemorySnapshot([
      for (final entry in store.documents.entries)
        if (entry.key.startsWith(prefix) &&
            !entry.key.substring(prefix.length).contains('/'))
          _MemoryQueryDocument(
            entry.key.substring(prefix.length),
            Map.of(entry.value),
          ),
    ]);
  }
}

class _MemoryDocument extends Fake
    implements DocumentReference<Map<String, dynamic>> {
  _MemoryDocument(this.store, this.path);
  final _MemoryFirestore store;
  @override
  final String path;
  @override
  CollectionReference<Map<String, dynamic>> collection(String name) =>
      _MemoryCollection(store, '$path/$name');
  @override
  Future<void> set(Map<String, dynamic> values, [SetOptions? options]) async =>
      store.documents[path] = Map.of(values);
  @override
  Future<void> delete() async => store.documents.remove(path);
}

class _MemorySnapshot extends Fake
    implements QuerySnapshot<Map<String, dynamic>> {
  _MemorySnapshot(this.docs);
  @override
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> docs;
}

class _MemoryQueryDocument extends Fake
    implements QueryDocumentSnapshot<Map<String, dynamic>> {
  _MemoryQueryDocument(this.id, this.values);
  @override
  final String id;
  final Map<String, dynamic> values;
  @override
  Map<String, dynamic> data() => values;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late MockFirebaseAuth auth;
  late MockFirebaseFirestore firestore;
  late MockFirebaseUser user;
  late HabitsRepository repository;

  setUp(() {
    db = AppDatabase(executor: NativeDatabase.memory());

    auth = MockFirebaseAuth();
    firestore = MockFirebaseFirestore();
    user = MockFirebaseUser();

    when(auth.currentUser).thenReturn(user);

    repository = HabitsRepository(db, firestore, auth);
  });

  tearDown(() async {
    await db.closeDatabase();
  });

  test(
    'addHabit salva o hábito localmente e cria CREATE na SyncQueue',
    () async {
      await repository.addHabit('Beber água');

      final habits = await db.select(db.habits).get();

      expect(habits.length, 1);
      expect(habits.single.title, 'Beber água');
      expect(habits.single.completedDates, '[]');

      final pending = await db.getPendingSyncItems('user-123');

      expect(pending.length, 1);

      final syncItem = pending.single;

      expect(syncItem.collection, 'habits');
      expect(syncItem.docId, habits.single.id);
      expect(syncItem.operationType, 'create');
      expect(syncItem.isSynced, false);

      expect(
        syncItem.payloadJson,
        '{"title":"Beber água","completedDates":[]}',
      );
    },
  );

  test(
    'addHabit sem usuário autenticado não altera Drift nem SyncQueue',
    () async {
      when(auth.currentUser).thenReturn(null);

      await repository.addHabit('Hábito bloqueado');

      final habits = await db.select(db.habits).get();
      final pending = await db.getPendingSyncItems('user-123');

      expect(habits, isEmpty);
      expect(pending, isEmpty);
    },
  );
  for (final title in [
    'Meditar',
    '%',
    '_',
    'Treino 100%',
    'habit_test',
    '',
    '   ',
    'a%b_c[]💧',
  ]) {
    test(
      'deleteHabit uses exact IDs regardless of title: ${jsonEncode(title)}',
      () async {
        const habitId = '11111111-1111-4111-8111-111111111111';
        const otherHabitId = '22222222-2222-4222-8222-222222222222';
        for (final id in [habitId, otherHabitId]) {
          await db
              .into(db.habits)
              .insert(
                HabitsCompanion.insert(
                  id: id,
                  title: title,
                  completedDates: '[]',
                ),
              );
        }
        final notifications = <(String, String, String)>[
          (habitId, 'Título legado diferente', 'general'),
          ('habit_$habitId', 'Título atual diferente', 'habits'),
          (otherHabitId, title, 'habits'),
          ('habit_$otherHabitId', title, 'habits'),
          ('task-unrelated', title, 'tasks'),
          ('exam-unrelated', title, 'studies'),
          ('health-unrelated', title, 'health'),
          ('health_med_unrelated', title, 'health'),
          ('cycle-unrelated', title, 'health'),
          ('system-unrelated', title, 'general'),
          ('habit_$habitId-other', title, 'habits'),
          ('substring-unrelated', 'Antes $title depois', 'tasks'),
        ];
        for (final notification in notifications) {
          await db
              .into(db.notificationsTable)
              .insert(
                NotificationsTableCompanion.insert(
                  id: notification.$1,
                  title: notification.$2,
                  description: 'Preservar conteúdo',
                  priority: 'today',
                  moduleType: notification.$3,
                  route: '/',
                  createdAt: DateTime(2026, 10, 5),
                ),
              );
        }
        final expected = (await db.select(db.notificationsTable).get())
            .where((row) => row.id != habitId && row.id != 'habit_$habitId')
            .toList();

        await repository.deleteHabit(habitId, title);

        expect((await db.select(db.habits).get()).map((row) => row.id), [
          otherHabitId,
        ]);
        expect(await db.select(db.notificationsTable).get(), expected);
        final queue = await db.select(db.syncQueueTable).get();
        expect(queue, hasLength(1));
        final item = queue.single;
        expect(item.ownerUid, 'user-123');
        expect(item.docId, habitId);
        expect(item.collection, 'batch');
        expect(item.operationType, 'batch_delete');
        expect(item.status, SyncQueuePersistenceStatus.pending);
        expect(item.isSynced, isFalse);
        expect(jsonDecode(item.payloadJson), {
          'deletes': [
            {'collection': 'habits', 'docId': habitId},
            {'collection': 'notifications', 'docId': habitId},
            {'collection': 'notifications', 'docId': 'habit_$habitId'},
          ],
        });
        verifyZeroInteractions(firestore);
      },
    );
  }

  test(
    'confirmed habit delete survives detach/relogin and leaves B isolated',
    () async {
      final factory = TestUserDatabaseFactory();
      User? activeUser = _NamedUser('user-a');
      when(auth.currentUser).thenAnswer((_) => activeUser);
      final sessions = SessionDatabaseCoordinator(
        currentUserId: () => activeUser?.uid,
        openDatabase: factory.open,
      );
      addTearDown(() async {
        await sessions.dispose();
        await factory.dispose();
      });
      final remote = _MemoryFirestore();
      const habitId = 'habit-shared-id';
      const title = 'Treino 100%_';
      Future<void> seedAccount(AppDatabase database, String uid) async {
        await database
            .into(database.habits)
            .insert(
              HabitsCompanion.insert(
                id: habitId,
                title: title,
                completedDates: '[]',
              ),
            );
        remote.documents['users/$uid/habits/$habitId'] = {
          'title': title,
          'completedDates': <String>[],
        };
        for (final id in [habitId, 'habit_$habitId', 'system-unrelated']) {
          await database
              .into(database.notificationsTable)
              .insert(
                NotificationsTableCompanion.insert(
                  id: id,
                  title: title,
                  description: 'Fixture',
                  priority: 'today',
                  moduleType: id == 'system-unrelated' ? 'general' : 'habits',
                  route: '/',
                  createdAt: DateTime(2026, 10, 5),
                ),
              );
          remote.documents['users/$uid/notifications/$id'] = {
            'title': title,
            'description': 'Fixture',
            'priority': 'today',
            'moduleType': id == 'system-unrelated' ? 'general' : 'habits',
            'route': '/',
            'isRead': false,
            'isCompleted': false,
            'createdAt': Timestamp.fromDate(DateTime(2026, 10, 5)),
          };
        }
      }

      final a = await sessions.prepare('user-a');
      await seedAccount(a, 'user-a');
      final habitsA = HabitsRepository(a, remote, auth);
      await habitsA.deleteHabit(habitId, title);
      expect(
        (await a.select(a.notificationsTable).get()).map((row) => row.id),
        ['system-unrelated'],
      );
      expect(
        remote.documents.containsKey(
          'users/user-a/notifications/habit_$habitId',
        ),
        isTrue,
      );
      var requests = 0;
      final managerA = SyncManager(
        queueStore: AppDatabaseSyncQueueStore(a),
        currentUserId: () => activeUser?.uid,
        remoteDataSource: FirestoreSyncRemoteDataSource(
          remote,
          auth,
          idTokenProvider: (user, _) async => 'test-token-${user.uid}',
          appCheckTokenProvider: () async => 'test-app-check',
          clientFactory: () => MockClient((request) async {
            requests++;
            expect(
              request.headers['Authorization'],
              'Bearer test-token-user-a',
            );
            expect(jsonDecode(request.body), {
              'operation': 'delete_habit',
              'habitId': habitId,
            });
            for (final path in [
              'habits/$habitId',
              'notifications/$habitId',
              'notifications/habit_$habitId',
            ]) {
              remote.documents.remove('users/user-a/$path');
            }
            return http.Response('{}', 200);
          }),
        ),
      );
      addTearDown(managerA.dispose);
      expect(await managerA.processPendingItems(), isTrue);
      expect(requests, 1);
      expect(
        (await a.select(a.syncQueueTable).getSingle()).status,
        SyncQueuePersistenceStatus.succeeded,
      );
      await managerA.prepareForSessionDetach('user-a');
      activeUser = null;
      await sessions.detach(expectedUid: 'user-a');

      activeUser = _NamedUser('user-b');
      final b = await sessions.prepare('user-b');
      await seedAccount(b, 'user-b');
      final beforeB = await b.select(b.notificationsTable).get();
      await expectLater(
        habitsA.deleteHabit(habitId, title),
        throwsA(isA<LocalMutationUnavailable>()),
      );
      expect(await managerA.processPendingItems(), isFalse);
      expect(await b.select(b.notificationsTable).get(), beforeB);
      expect(await b.select(b.habits).get(), hasLength(1));
      expect(await b.select(b.syncQueueTable).get(), isEmpty);
      expect(
        remote.documents.containsKey(
          'users/user-b/notifications/habit_$habitId',
        ),
        isTrue,
      );
      activeUser = null;
      await sessions.detach(expectedUid: 'user-b');

      activeUser = _NamedUser('user-a');
      final reopened = await sessions.prepare('user-a');
      final notifications = NotificationsRepository(
        firestore: remote,
        auth: auth,
        localDao: reopened.notificationDao,
      );
      await HabitsRepository(
        reopened,
        remote,
        auth,
      ).syncHabitsFromFirebaseToLocal();
      await notifications.syncNotificationsFromFirebaseToLocal();
      await const NotificationModuleReconciler().sync(
        repository: notifications,
        db: reopened,
        preferences: const NotificationPreferences.enabled(),
      );
      await notifications.remoteEffects.sealAndDrain();
      expect(await reopened.select(reopened.habits).get(), isEmpty);
      expect(
        (await reopened.select(reopened.notificationsTable).get()).map(
          (row) => row.id,
        ),
        ['system-unrelated'],
      );
      expect(
        (await reopened.select(reopened.syncQueueTable).getSingle()).ownerUid,
        'user-a',
      );
      expect(
        (await reopened.select(reopened.syncQueueTable).getSingle()).status,
        SyncQueuePersistenceStatus.succeeded,
      );
      expect(requests, 1);
    },
  );

  test(
    'deleteHabit remove dados locais e cria batch_delete na SyncQueue',
    () async {
      const habitId = 'habit-delete-1';
      const habitTitle = 'Meditar';

      await db
          .into(db.habits)
          .insert(
            HabitsCompanion.insert(
              id: habitId,
              title: habitTitle,
              completedDates: '[]',
            ),
          );

      await db
          .into(db.notificationsTable)
          .insert(
            NotificationsTableCompanion.insert(
              id: habitId,
              title: habitTitle,
              description: 'Lembrete do hábito',
              priority: 'today',
              moduleType: 'habits',
              route: '/habits',
              createdAt: DateTime.now(),
            ),
          );

      await repository.deleteHabit(habitId, habitTitle);

      final habits = await db.select(db.habits).get();
      final notifications = await db.select(db.notificationsTable).get();
      final pending = await db.getPendingSyncItems('user-123');

      expect(habits, isEmpty);
      expect(notifications, isEmpty);

      expect(pending.length, 1);

      final syncItem = pending.single;

      expect(syncItem.collection, 'batch');
      expect(syncItem.docId, habitId);
      expect(syncItem.operationType, 'batch_delete');
      expect(syncItem.isSynced, false);

      expect(syncItem.payloadJson, contains('"collection":"habits"'));

      expect(syncItem.payloadJson, contains('"collection":"notifications"'));

      expect(syncItem.payloadJson, contains('"docId":"habit_$habitId"'));
    },
  );
}
