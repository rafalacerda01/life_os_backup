import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/testing.dart';

import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/network/activity_remote_data_source.dart';
import 'package:life_os/features/habits/data/repositories/habits_repository.dart';

class MockFirebaseAuth extends Mock implements FirebaseAuth {}

class MockFirebaseUser extends Mock implements User {
  @override
  String get uid => 'user-123';
}

class MockFirebaseFirestore extends Mock implements FirebaseFirestore {}

void main() {
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

    repository = HabitsRepository(
      db,
      firestore,
      auth,
      ActivityRemoteDataSource(
        client: MockClient((_) async => throw UnimplementedError()),
        idTokenProvider: () async => 'token',
      ),
    );
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
