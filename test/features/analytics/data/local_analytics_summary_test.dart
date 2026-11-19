import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/features/analytics/presentation/local_analytics.dart';
import 'package:life_os/features/habits/data/models/habit_model.dart';
import 'package:life_os/features/health/data/models/health_model.dart';
import 'package:life_os/features/tasks/data/models/task_model.dart';

void main() {
  final now = DateTime(2026, 11, 18, 12);
  HealthModel health(int waterMl) => HealthModel(
    mood: '—',
    waterIntakeMl: waterMl,
    hasTakenPillToday: false,
    date: now,
  );

  test('empty offline metrics contain no fabricated progress or score', () {
    final result = summarizeLocalAnalytics(
      tasks: [],
      habits: [],
      transactions: [],
      health: health(0),
      waterGoalMl: 2500,
      now: now,
    );
    expect(
      (
        result.completedTasks,
        result.tasks,
        result.habitDays,
        result.possibleHabitDays,
      ),
      (0, 0, 0, 0),
    );
    expect(
      (result.waterMl, result.waterGoalMl, result.finance.balance),
      (0, 2500, 0.0),
    );
  });

  test(
    'basic metrics count distinct days within the rolling civil week and sum saved transactions',
    () {
      final result = summarizeLocalAnalytics(
        tasks: [
          TaskModel(
            id: '1',
            title: 'Terminada',
            priority: 'low',
            isCompleted: true,
            date: now,
          ),
          TaskModel(
            id: '2',
            title: 'Aberta',
            priority: 'low',
            isCompleted: false,
            date: now,
          ),
        ],
        habits: [
          HabitModel(
            id: 'habit',
            title: 'Ler',
            completedDates: [
              '2026-11-12',
              '2026-11-12',
              '2026-11-18',
              '2026-11-11',
              '2026-11-19',
            ],
          ),
        ],
        transactions: [
          Transaction(
            isDeleted: false,
            id: 1,
            title: 'Entrada',
            amount: 70,
            type: 'income',
            category: 'Trabalho',
            date: now,
          ),
          Transaction(
            isDeleted: false,
            id: 2,
            title: 'Saída',
            amount: 25.5,
            type: 'expense',
            category: 'Outros',
            date: now,
          ),
        ],
        health: health(1000),
        waterGoalMl: 2500,
        now: now,
      );
      expect(
        (
          result.completedTasks,
          result.tasks,
          result.habitDays,
          result.possibleHabitDays,
        ),
        (1, 2, 2, 7),
      );
      expect(
        (result.waterMl, result.waterGoalMl, result.finance.balance),
        (1000, 2500, 44.5),
      );
    },
  );
}
