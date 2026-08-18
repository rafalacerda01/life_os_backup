import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/network/activity_remote_data_source.dart';
import 'package:life_os/features/habits/data/repositories/habits_repository.dart';
import 'package:life_os/features/tasks/presentation/providers/tasks_provider.dart';
import 'package:mockito/mockito.dart';

class MockFirebaseAuth extends Mock implements FirebaseAuth {}

class MockFirebaseUser extends Mock implements User {}

class MockFirebaseFirestore extends Mock implements FirebaseFirestore {}

class FakeActivityRemoteDataSource extends ActivityRemoteDataSource {
  int taskCalls = 0;
  int habitCalls = 0;
  Object? taskError;
  Object? habitError;

  FakeActivityRemoteDataSource()
    : super(
        client: MockClient((_) async => throw UnimplementedError()),
        idTokenProvider: () async => 'token',
      );

  @override
  Future<ActivityTaskCompletionResponse> completeTask({
    required String taskId,
  }) async {
    taskCalls += 1;
    if (taskError != null) throw taskError!;
    return ActivityTaskCompletionResponse(
      resourceId: taskId,
      occurredAt: DateTime.utc(2026, 8, 18),
      replayed: false,
    );
  }

  @override
  Future<ActivityHabitCompletionResponse> completeHabit({
    required String habitId,
  }) async {
    habitCalls += 1;
    if (habitError != null) throw habitError!;
    return ActivityHabitCompletionResponse(
      resourceId: habitId,
      dayKey: '2026-08-18',
      occurredAt: DateTime.utc(2026, 8, 18),
      replayed: false,
    );
  }
}

Future<void> _settleCompetitiveCall() => Future<void>.delayed(Duration.zero);

void main() {
  late AppDatabase db;
  late MockFirebaseAuth auth;
  late MockFirebaseFirestore firestore;
  late FakeActivityRemoteDataSource activityRemote;
  late TasksRepository tasks;
  late HabitsRepository habits;

  setUp(() {
    db = AppDatabase(executor: NativeDatabase.memory());
    auth = MockFirebaseAuth();
    firestore = MockFirebaseFirestore();
    activityRemote = FakeActivityRemoteDataSource();
    when(auth.currentUser).thenReturn(MockFirebaseUser());
    tasks = TasksRepository(db, firestore, auth, activityRemote);
    habits = HabitsRepository(db, firestore, auth, activityRemote);
  });

  tearDown(() async {
    await db.closeDatabase();
  });

  group('TasksRepository', () {
    test(
      'completion updates Drift and personal SyncQueue before reporting once',
      () async {
        await _insertTask(db, 'task-1', isCompleted: false);

        await tasks.toggleTaskStatus('task-1', false);
        await _settleCompetitiveCall();

        final task = (await db.select(db.taskTable).get()).single;
        final pending = await db.getPendingSyncItems();
        expect(task.isCompleted, isTrue);
        expect(pending.single.collection, 'tasks');
        expect(pending.single.operationType, 'update');
        expect(activityRemote.taskCalls, 1);
      },
    );

    test('uncompletion stays personal and does not report activity', () async {
      await _insertTask(db, 'task-2', isCompleted: true);

      await tasks.toggleTaskStatus('task-2', true);
      await _settleCompetitiveCall();

      final task = (await db.select(db.taskTable).get()).single;
      expect(task.isCompleted, isFalse);
      expect(activityRemote.taskCalls, 0);
    });

    test('remote failure never reverts Task or personal SyncQueue', () async {
      activityRemote.taskError = const ActivityRemoteException(
        statusCode: 404,
        code: 'TASK_NOT_FOUND',
        message: 'not found',
        isRetryable: false,
      );
      await _insertTask(db, 'task-3', isCompleted: false);

      await tasks.toggleTaskStatus('task-3', false);
      await _settleCompetitiveCall();

      final task = (await db.select(db.taskTable).get()).single;
      final pending = await db.getPendingSyncItems();
      expect(task.isCompleted, isTrue);
      expect(pending.single.operationType, 'update');
      expect(activityRemote.taskCalls, 1);
    });

    test(
      're-completion reports again and leaves idempotency to backend',
      () async {
        await _insertTask(db, 'task-4', isCompleted: false);

        await tasks.toggleTaskStatus('task-4', false);
        await _settleCompetitiveCall();
        await tasks.toggleTaskStatus('task-4', true);
        await _settleCompetitiveCall();
        await tasks.toggleTaskStatus('task-4', false);
        await _settleCompetitiveCall();

        expect(activityRemote.taskCalls, 2);
      },
    );

    test('addTask and deleteTask never report competitive activity', () async {
      await tasks.addTask('Nova tarefa', 'medium');
      final task = (await db.select(db.taskTable).get()).single;
      await tasks.deleteTask(task.id);
      await _settleCompetitiveCall();

      expect(activityRemote.taskCalls, 0);
    });
  });

  group('HabitsRepository', () {
    test(
      'today completion updates Drift and SyncQueue before reporting once',
      () async {
        await _insertHabit(db, 'habit-1', const []);

        await habits.toggleHabitToday('habit-1', const []);
        await _settleCompetitiveCall();

        final habit = (await db.select(db.habits).get()).single;
        final pending = await db.getPendingSyncItems();
        expect(jsonDecode(habit.completedDates), contains(_today()));
        expect(pending.single.collection, 'habits');
        expect(pending.single.operationType, 'update');
        expect(activityRemote.habitCalls, 1);
      },
    );

    test(
      'today uncompletion stays personal and does not report activity',
      () async {
        await _insertHabit(db, 'habit-2', [_today()]);

        await habits.toggleHabitToday('habit-2', [_today()]);
        await _settleCompetitiveCall();

        final habit = (await db.select(db.habits).get()).single;
        expect(jsonDecode(habit.completedDates), isEmpty);
        expect(activityRemote.habitCalls, 0);
      },
    );

    test('remote failure never reverts Habit or personal SyncQueue', () async {
      activityRemote.habitError = const ActivityRemoteException(
        statusCode: 409,
        code: 'ACTIVITY_EVENT_STATE_CONFLICT',
        message: 'conflict',
        isRetryable: false,
      );
      await _insertHabit(db, 'habit-3', const []);

      await habits.toggleHabitToday('habit-3', const []);
      await _settleCompetitiveCall();

      final habit = (await db.select(db.habits).get()).single;
      final pending = await db.getPendingSyncItems();
      expect(jsonDecode(habit.completedDates), contains(_today()));
      expect(pending.single.operationType, 'update');
      expect(activityRemote.habitCalls, 1);
    });

    test(
      'historical and today updateHabitDates never report activity',
      () async {
        await _insertHabit(db, 'habit-4', const []);

        await habits.updateHabitDates('habit-4', const ['2020-01-01']);
        await habits.updateHabitDates('habit-4', [_today()]);
        await _settleCompetitiveCall();

        expect(activityRemote.habitCalls, 0);
      },
    );

    test(
      'addHabit and deleteHabit never report competitive activity',
      () async {
        await habits.addHabit('Meditar');
        final habit = (await db.select(db.habits).get()).single;
        await habits.deleteHabit(habit.id, habit.title);
        await _settleCompetitiveCall();

        expect(activityRemote.habitCalls, 0);
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
