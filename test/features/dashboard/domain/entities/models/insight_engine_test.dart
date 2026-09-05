import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/features/dashboard/domain/entities/models/insight_engine.dart';
import 'package:life_os/features/dashboard/domain/entities/models/insight_model.dart';

InsightContext _context(
  HealthInsightDataState state, {
  double healthScore = 0,
  int hour = 15,
  int studyStreak = 0,
}) => InsightContext(
  productivityScore: 0,
  healthScore: healthScore,
  healthDataState: state,
  financialScore: 0,
  studyStreak: studyStreak,
  currentTime: DateTime(2026, 9, 4, hour),
);

void main() {
  for (final state in [
    HealthInsightDataState.noData,
    HealthInsightDataState.loading,
    HealthInsightDataState.unavailable,
  ]) {
    test('$state with zero score never produces a critical health insight', () {
      final context = _context(state);
      expect(CriticalHealthRule().evaluate(context), 0.0);
      final engine = InsightEngine();
      for (var i = 0; i < 3; i++) {
        expect(
          engine.getBestInsight(context).id,
          isNot('critical_health_warning'),
        );
      }
    });
  }

  test('real data preserves every existing health threshold', () {
    final rule = CriticalHealthRule();
    for (final entry in {
      0.0: 1.0,
      29.0: 1.0,
      30.0: 0.7,
      49.0: 0.7,
      50.0: 0.0,
    }.entries) {
      expect(
        rule.evaluate(
          _context(HealthInsightDataState.realData, healthScore: entry.key),
        ),
        entry.value,
      );
    }
    final insight = InsightEngine().getBestInsight(
      _context(HealthInsightDataState.realData, healthScore: 20),
    );
    expect(insight.id, 'critical_health_warning');
    expect(insight.priority, InsightPriority.critical);
  });

  test('no data offers a low priority, non-warning invitation', () {
    final insight = InsightEngine().getBestInsight(
      _context(HealthInsightDataState.noData),
    );
    expect(insight.id, 'health_no_data');
    expect(insight.priority, InsightPriority.low);
    expect(insight.category, InsightCategory.health);
    expect(insight.title, 'Comece pelo básico');
    expect(
      insight.message,
      'Comece registrando seu bem-estar para acompanhar sua rotina ao longo dos dias.',
    );
  });

  test('no-data invitation does not override productivity or study', () {
    expect(
      InsightEngine()
          .getBestInsight(_context(HealthInsightDataState.noData, hour: 8))
          .id,
      'morning_momentum',
    );
    expect(
      InsightEngine()
          .getBestInsight(
            _context(HealthInsightDataState.noData, studyStreak: 3),
          )
          .id,
      'study_streak_motivation',
    );
  });

  test('no-data invitation is not used for loading, errors or real data', () {
    for (final state in [
      HealthInsightDataState.loading,
      HealthInsightDataState.unavailable,
      HealthInsightDataState.realData,
    ]) {
      expect(HealthNoDataRule().evaluate(_context(state)), 0.0);
    }
  });
}
