import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/features/habits/data/repositories/habits_repository.dart';
import 'package:life_os/features/tasks/presentation/providers/tasks_provider.dart';
import 'package:mockito/mockito.dart';

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
  late TasksRepository tasks;
  late HabitsRepository habits;

  setUp(() {
    db = AppDatabase(executor: NativeDatabase.memory());
    auth = MockFirebaseAuth();
    firestore = MockFirebaseFirestore();
    final user = MockFirebaseUser();
    when(auth.currentUser).thenReturn(user);
    tasks = TasksRepository(db, firestore, auth);
    habits = HabitsRepository(db, firestore, auth);
  });

  tearDown(() async {
    await db.closeDatabase();
  });

  group('TasksRepository', () {
    test(
      'completion updates Drift and persists competitive work only in SyncQueue',
      () async {
        await _insertTask(db, 'task-1', isCompleted: false);

        await tasks.toggleTaskStatus('task-1', false);

        final task = (await db.select(db.taskTable).get()).single;
        final pending = await db.getPendingSyncItems('user-123');
        expect(task.isCompleted, isTrue);
        expect(pending.single.collection, 'tasks');
        expect(pending.single.operationType, 'update');
        expect(jsonDecode(pending.single.payloadJson), {'isCompleted': true});
      },
    );

    test('uncompletion stays personal and does not report activity', () async {
      await _insertTask(db, 'task-2', isCompleted: true);

      await tasks.toggleTaskStatus('task-2', true);

      final task = (await db.select(db.taskTable).get()).single;
      expect(task.isCompleted, isFalse);
    });

    test('offline Task completion remains pending for durable retry', () async {
      await _insertTask(db, 'task-3', isCompleted: false);

      await tasks.toggleTaskStatus('task-3', false);

      final task = (await db.select(db.taskTable).get()).single;
      final pending = await db.getPendingSyncItems('user-123');
      expect(task.isCompleted, isTrue);
      expect(pending.single.operationType, 'update');
      expect(pending.single.status, SyncQueuePersistenceStatus.pending);
    });

    test(
      're-completion remains represented by durable sync operations',
      () async {
        await _insertTask(db, 'task-4', isCompleted: false);

        await tasks.toggleTaskStatus('task-4', false);
        await tasks.toggleTaskStatus('task-4', true);
        await tasks.toggleTaskStatus('task-4', false);

        final pending = await db.getPendingSyncItems('user-123');
        expect(pending, hasLength(3));
      },
    );

    test('addTask and deleteTask never report competitive activity', () async {
      await tasks.addTask('Nova tarefa', 'medium');
      final task = (await db.select(db.taskTable).get()).single;
      await tasks.deleteTask(task.id);
      expect(await db.getPendingSyncItems('user-123'), isNotEmpty);
    });
  });

  group('HabitsRepository', () {
    test(
      'today completion persists competitive work only in SyncQueue',
      () async {
        await _insertHabit(db, 'habit-1', const []);

        await habits.toggleHabitToday('habit-1', const []);

        final habit = (await db.select(db.habits).get()).single;
        final pending = await db.getPendingSyncItems('user-123');
        expect(jsonDecode(habit.completedDates), contains(_today()));
        expect(pending.single.collection, 'habits');
        expect(pending.single.operationType, 'update');
        final payload = jsonDecode(pending.single.payloadJson);
        expect(payload['completedDates'], contains(_today()));
        expect(
          payload['competitiveCompletionId'],
          matches(
            RegExp(
              r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab]'
              r'[0-9a-f]{3}-[0-9a-f]{12}$',
              caseSensitive: false,
            ),
          ),
        );
      },
    );

    test(
      'today uncompletion stays personal and does not report activity',
      () async {
        await _insertHabit(db, 'habit-2', [_today()]);

        await habits.toggleHabitToday('habit-2', [_today()]);

        final habit = (await db.select(db.habits).get()).single;
        final pending = await db.getPendingSyncItems('user-123');
        expect(jsonDecode(habit.completedDates), isEmpty);
        expect(jsonDecode(pending.single.payloadJson), {
          'completedDates': <String>[],
        });
      },
    );

    test(
      'offline Habit completion remains pending for durable retry',
      () async {
        await _insertHabit(db, 'habit-3', const []);

        await habits.toggleHabitToday('habit-3', const []);

        final habit = (await db.select(db.habits).get()).single;
        final pending = await db.getPendingSyncItems('user-123');
        expect(jsonDecode(habit.completedDates), contains(_today()));
        expect(pending.single.operationType, 'update');
        expect(pending.single.status, SyncQueuePersistenceStatus.pending);
      },
    );

    test(
      'historical and today updateHabitDates never report activity',
      () async {
        await _insertHabit(db, 'habit-4', const []);

        await habits.updateHabitDates('habit-4', const ['2020-01-01']);
        await habits.updateHabitDates('habit-4', [_today()]);
        final pending = await db.getPendingSyncItems('user-123');
        expect(pending, hasLength(2));
        for (final item in pending) {
          final payload = jsonDecode(item.payloadJson) as Map<String, dynamic>;
          expect(payload.containsKey('competitiveCompletionId'), isFalse);
        }
      },
    );

    test(
      'addHabit and deleteHabit never report competitive activity',
      () async {
        await habits.addHabit('Meditar');
        final habit = (await db.select(db.habits).get()).single;
        await habits.deleteHabit(habit.id, habit.title);
        expect(await db.getPendingSyncItems('user-123'), isNotEmpty);
      },
    );
  });
}

String _today() => DateTime.now().toIso8601String().split('T')[0];

Future<void> _insertTask(
  AppDatabase db,
  String id, {
  required bool isCompleted,
}) {
  return db
      .into(db.taskTable)
      .insert(
        TaskTableCompanion.insert(
          id: id,
          title: 'Task',
          priority: 'medium',
          isCompleted: Value(isCompleted),
          date: DateTime(2026, 8, 18),
        ),
      );
}

Future<void> _insertHabit(AppDatabase db, String id, List<String> dates) {
  return db
      .into(db.habits)
      .insert(
        HabitsCompanion.insert(
          id: id,
          title: 'Habit',
          completedDates: jsonEncode(dates),
        ),
      );
}
