import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/features/ai_companion/data/models/ai_insight.dart';
import 'package:life_os/features/ai_companion/data/repositories/ai_companion_repository.dart';
import 'package:life_os/features/ai_companion/data/services/ai_insight_context_builder.dart';

void main() {
  late AppDatabase db;
  String? uid;
  late AIInsightContextBuilder builder;
  final now = DateTime(2026, 9, 22, 12);

  setUp(() {
    db = AppDatabase(executor: NativeDatabase.memory());
    uid = 'user-a';
    builder = AIInsightContextBuilder(
      db,
      currentUserIdProvider: () => uid,
      clock: () => now,
    );
  });
  tearDown(() async => db.close());

  Future<void> task(String id, String priority, {bool completed = false}) => db
      .into(db.taskTable)
      .insert(
        TaskTableCompanion.insert(
          id: id,
          title: 'SECRET_TASK_TITLE',
          priority: priority,
          isCompleted: Value(completed),
          date: now,
        ),
      );

  Future<void> habit(String id, String dates) => db
      .into(db.habits)
      .insert(
        HabitsCompanion.insert(
          id: id,
          title: 'SECRET_HABIT_TITLE',
          completedDates: dates,
        ),
      );

  Future<void> focus(DateTime at, int seconds) => db
      .into(db.focusLogs)
      .insert(
        FocusLogsCompanion.insert(
          targetId: 'SECRET_TARGET_ID',
          targetType: 'task',
          durationSeconds: seconds,
          timestamp: at.millisecondsSinceEpoch,
        ),
      );

  Future<void> transaction(
    DateTime at,
    double amount,
    String type,
    String category, {
    bool deleted = false,
  }) => db
      .into(db.transactions)
      .insert(
        TransactionsCompanion.insert(
          title: 'SECRET_TRANSACTION_DESCRIPTION',
          firestoreId: const Value('SECRET_TRANSACTION_ID'),
          amount: amount,
          type: type,
          category: category,
          date: at,
          isDeleted: Value(deleted),
        ),
      );

  test('empty daily summary is local and zero-valued', () async {
    final context = await builder.buildContext(
      AIInsightIntent.dailyOverview,
      expectedUserId: 'user-a',
    );
    expect(context['tasks'], {'pending': 0, 'high_priority_pending': 0});
    expect(context['habits'], {'active': 0, 'completed_today': 0});
    expect(context['focus'], {'minutes_today': 0, 'sessions_today': 0});
    expect(context, isNot(contains('checkin')));
    expect(context, isNot(contains('study')));
    final summary = await builder.buildLocalSummary(expectedUserId: 'user-a');
    expect(summary.pendingTasks, 0);
    expect(summary.energy, isNull);
  });

  test(
    'daily aggregates omit identifiers, titles and malformed habits',
    () async {
      await task('SECRET_TASK_ID', ' HIGH ');
      await task('completed', 'high', completed: true);
      await habit('today', '["2026-09-22"]');
      await habit('broken', 'not-json');
      await focus(DateTime(2026, 9, 22), 125);
      await focus(DateTime(2026, 9, 21, 23, 59, 59), 600);
      await db
          .into(db.checkInTable)
          .insert(
            CheckInTableCompanion.insert(
              id: 'secret-checkin',
              energy: 4,
              focus: 3,
              motivation: 5,
              createdAt: DateTime(2026, 9, 22, 10),
            ),
          );
      await db
          .into(db.studyStats)
          .insert(
            StudyStatsCompanion.insert(
              id: 'main',
              streak: 3,
              reviewQueue: 7,
              progress: 0.75,
            ),
          );
      await db
          .into(db.healthEntries)
          .insert(
            HealthEntriesCompanion.insert(
              docId: '2026-09-22',
              date: DateTime(2026, 9, 22, 9),
              mood: const Value('Radiante'),
              waterIntakeMl: const Value(1750),
            ),
          );
      await db
          .into(db.goals)
          .insert(
            GoalsCompanion.insert(
              id: 'SECRET_GOAL_ID',
              title: 'SECRET_GOAL_TITLE',
              period: 'daily',
              currentValue: 2,
              targetValue: 4,
              createdAt: now.millisecondsSinceEpoch,
              lastReset: now.millisecondsSinceEpoch,
            ),
          );
      final context = await builder.buildContext(
        AIInsightIntent.dailyOverview,
        expectedUserId: 'user-a',
      );
      expect(context['tasks'], {'pending': 1, 'high_priority_pending': 1});
      expect(context['habits'], {'active': 2, 'completed_today': 1});
      expect(context['focus'], {'minutes_today': 2, 'sessions_today': 1});
      expect(context['checkin'], {
        'energy': 4.0,
        'focus': 3.0,
        'motivation': 5.0,
      });
      expect(context['study'], {
        'streak': 3,
        'review_queue': 7,
        'progress_percent': 75.0,
      });
      expect(context['health'], {'hydration_ml': 1750, 'mood': 'radiante'});
      expect(context['goals'], {'active': 1, 'average_progress_percent': 50.0});
      final serialized = jsonEncode(context);
      for (final marker in [
        'SECRET_TASK_TITLE',
        'SECRET_HABIT_TITLE',
        'SECRET_GOAL_TITLE',
        'SECRET_TARGET_ID',
        'SECRET_TASK_ID',
        'SECRET_GOAL_ID',
        'secret-checkin',
        'uid',
        'email',
      ]) {
        expect(serialized, isNot(contains(marker)));
      }
    },
  );

  test('weekly uses seven local calendar days and current snapshot', () async {
    await task('current', 'high');
    await habit('weekly', '["2026-09-16","2026-09-22","2026-09-15"]');
    await focus(DateTime(2026, 9, 16), 120);
    await focus(DateTime(2026, 9, 15, 23, 59, 59), 600);
    await transaction(DateTime(2026, 9, 16), 20, 'income', 'Outros');
    await transaction(DateTime(2026, 9, 22), 5, 'expense', 'Outros');
    await transaction(
      DateTime(2026, 9, 22),
      99,
      'expense',
      'Outros',
      deleted: true,
    );
    final context = await builder.buildContext(
      AIInsightIntent.weeklyOverview,
      expectedUserId: 'user-a',
    );
    expect(context['habits'], {'active': 1, 'completions_last_7_days': 2});
    expect(context['focus'], {
      'minutes_last_7_days': 2,
      'sessions_last_7_days': 1,
    });
    expect(context['finance'], {
      'income_last_7_days': 20.0,
      'expense_last_7_days': 5.0,
      'transaction_count_last_7_days': 2,
    });
    expect((context['current'] as Map)['pending_tasks'], 1);
    expect(
      jsonEncode(context),
      isNot(contains('SECRET_TRANSACTION_DESCRIPTION')),
    );
  });

  test(
    'unknown daily mood is omitted and latest valid check-in wins',
    () async {
      await db
          .into(db.healthEntries)
          .insert(
            HealthEntriesCompanion.insert(
              docId: '2026-09-22',
              date: DateTime(2026, 9, 22),
              mood: const Value('PRIVATE_UNKNOWN_MOOD'),
            ),
          );
      await db
          .into(db.checkInTable)
          .insert(
            CheckInTableCompanion.insert(
              id: 'old',
              energy: 2,
              focus: 2,
              motivation: 2,
              createdAt: DateTime(2026, 9, 22, 8),
            ),
          );
      await db
          .into(db.checkInTable)
          .insert(
            CheckInTableCompanion.insert(
              id: 'latest',
              energy: 5,
              focus: 4,
              motivation: 3,
              createdAt: DateTime(2026, 9, 22, 11),
            ),
          );
      final context = await builder.buildContext(
        AIInsightIntent.dailyOverview,
        expectedUserId: 'user-a',
      );
      expect(context['health'], {'hydration_ml': 0});
      expect(context['checkin'], {
        'energy': 5.0,
        'focus': 4.0,
        'motivation': 3.0,
      });
      expect(jsonEncode(context), isNot(contains('PRIVATE_UNKNOWN_MOOD')));
    },
  );

  test(
    'weekly health and check-ins aggregate; tied official moods become misto',
    () async {
      for (final (day, mood, water) in [
        (16, 'Radiante', 0),
        (22, 'Estressado', 2000),
        (15, 'Cansado', 10000),
      ]) {
        await db
            .into(db.healthEntries)
            .insert(
              HealthEntriesCompanion.insert(
                docId: '2026-09-$day',
                date: DateTime(2026, 9, day),
                mood: Value(mood),
                waterIntakeMl: Value(water),
              ),
            );
      }
      for (final (id, day, value) in [
        ('first', 16, 2.0),
        ('last', 22, 4.0),
        ('outside', 15, 5.0),
      ]) {
        await db
            .into(db.checkInTable)
            .insert(
              CheckInTableCompanion.insert(
                id: id,
                energy: value,
                focus: value,
                motivation: value,
                createdAt: DateTime(2026, 9, day),
              ),
            );
      }
      final context = await builder.buildContext(
        AIInsightIntent.weeklyOverview,
        expectedUserId: 'user-a',
      );
      expect(context['health'], {
        'entries_last_7_days': 2,
        'average_hydration_ml': 1000.0,
        'mood_summary': 'misto',
      });
      expect(context['checkin'], {
        'entries_last_7_days': 2,
        'average_energy': 3.0,
        'average_focus': 3.0,
        'average_motivation': 3.0,
      });
    },
  );

  test(
    'month includes exact boundaries and canonicalizes top categories',
    () async {
      await transaction(DateTime(2026, 9, 1), 100, 'income', 'Outros');
      await transaction(
        DateTime(2026, 9, 30, 23, 59, 59),
        40,
        'expense',
        'alimentacao',
      );
      await transaction(
        DateTime(2026, 9, 2),
        30,
        'expense',
        'unknown private category',
      );
      await transaction(DateTime(2026, 9, 3), 20, 'expense', 'Transporte');
      await transaction(DateTime(2026, 9, 4), 10, 'expense', 'Moradia');
      await transaction(
        DateTime(2026, 8, 31, 23, 59),
        900,
        'expense',
        'Outros',
      );
      await transaction(DateTime(2026, 10, 1), 900, 'expense', 'Outros');
      await transaction(
        DateTime(2026, 9, 10),
        900,
        'expense',
        'Outros',
        deleted: true,
      );
      final context = await builder.buildContext(
        AIInsightIntent.financeMonthSummary,
        expectedUserId: 'user-a',
      );
      final finance = context['finance'] as Map<String, Object?>;
      expect(finance['income'], 100);
      expect(finance['expense'], 100);
      expect(finance['balance'], 0);
      expect(finance['transaction_count'], 5);
      expect(finance['top_expense_categories'], [
        {'category': 'Alimentação', 'amount': 40.0},
        {'category': 'Outros', 'amount': 30.0},
        {'category': 'Transporte', 'amount': 20.0},
      ]);
      expect(jsonEncode(context), isNot(contains('unknown private category')));
    },
  );

  test(
    'different or absent session fails closed before local data leaves',
    () async {
      await expectLater(
        builder.buildContext(
          AIInsightIntent.dailyOverview,
          expectedUserId: 'user-b',
        ),
        throwsA(isA<AIAuthenticationException>()),
      );
      uid = null;
      await expectLater(
        builder.buildLocalSummary(expectedUserId: 'user-a'),
        throwsA(isA<AIAuthenticationException>()),
      );
    },
  );
}
