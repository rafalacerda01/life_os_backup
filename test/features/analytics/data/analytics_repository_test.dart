import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:life_os/features/analytics/data/analytics_repository.dart';
import 'package:life_os/features/analytics/domain/entities/analytics_entity.dart';

class _Habit {
  const _Habit(this.completedDates);

  final List<String> completedDates;
}

void main() {
  final repository = AnalyticsRepository();

  AnalyticsEntity generate({
    bool isPremium = true,
    List<_Habit> habits = const [],
  }) {
    return repository.generateAnalytics(
      isPremium: isPremium,
      tasks: [],
      health: null,
      transactions: [],
      habits: habits,
    );
  }

  test('Premium without habits has no weekly evolution', () {
    expect(generate().weeklyEvolution, isEmpty);
  });

  test('Premium without habits retains zero habit consistency', () {
    expect(generate().habitConsistency, 0.0);
  });

  test('Premium with habits retains the last seven day labels', () {
    final evolution = generate(habits: [const _Habit([])]).weeklyEvolution;
    const labels = ['Seg', 'Ter', 'Qua', 'Qui', 'Sex', 'Sáb', 'Dom'];
    final today = DateTime.now();

    expect(evolution, hasLength(7));
    expect(
      evolution.map((day) => day.dayName),
      List.generate(
        7,
        (index) =>
            labels[today.subtract(Duration(days: 6 - index)).weekday - 1],
      ),
    );
  });

  test('Premium completion today reflects the actual fraction of habits', () {
    final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
    final analytics = generate(
      habits: [
        _Habit([today]),
        const _Habit([]),
        const _Habit([]),
      ],
    );

    expect(
      analytics.weeklyEvolution.last.scorePercentage,
      closeTo(1 / 3, 1e-10),
    );
    expect(
      analytics.weeklyEvolution.take(6).map((day) => day.scorePercentage),
      everyElement(0.0),
    );
    expect(analytics.habitConsistency, closeTo(100 / 21, 1e-10));
  });

  test('Premium without completions derives zero scores from habits', () {
    final analytics = generate(habits: [const _Habit([])]);

    expect(analytics.weeklyEvolution, hasLength(7));
    expect(
      analytics.weeklyEvolution.map((day) => day.scorePercentage),
      everyElement(0.0),
    );
    expect(analytics.habitConsistency, 0.0);
  });

  test('Free retains its gated placeholder indices and weekly evolution', () {
    expect(
      generate(isPremium: false),
      const AnalyticsEntity(
        productivityIndex: 50.0,
        healthIndex: 50.0,
        financeIndex: 50.0,
        habitConsistency: 50.0,
        weeklyEvolution: [
          DailyPerformance(dayName: 'Seg', scorePercentage: 0.5),
          DailyPerformance(dayName: 'Ter', scorePercentage: 0.5),
          DailyPerformance(dayName: 'Qua', scorePercentage: 0.5),
          DailyPerformance(dayName: 'Qui', scorePercentage: 0.0),
          DailyPerformance(dayName: 'Sex', scorePercentage: 0.0),
          DailyPerformance(dayName: 'Sáb', scorePercentage: 0.0),
          DailyPerformance(dayName: 'Dom', scorePercentage: 0.0),
        ],
      ),
    );
  });
}
