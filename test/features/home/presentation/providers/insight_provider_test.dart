import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/features/dashboard/data/models/dashboard_model.dart';
import 'package:life_os/features/dashboard/domain/entities/models/insight_engine.dart';
import 'package:life_os/features/dashboard/domain/entities/models/insight_model.dart';
import 'package:life_os/features/health/data/models/health_model.dart';
import 'package:life_os/features/health/presentation/providers/health_provider.dart';
import 'package:life_os/features/home/presentation/providers/home_provider.dart';
import 'package:life_os/features/home/presentation/providers/insight_provider.dart';

class _RecordingEngine extends InsightEngine {
  late InsightContext context;

  @override
  InsightModel getBestInsight(InsightContext context) {
    this.context = context;
    return super.getBestInsight(context);
  }
}

HealthModel _health({String mood = '—', int water = 0}) => HealthModel(
  mood: mood,
  waterIntakeMl: water,
  hasTakenPillToday: false,
  date: DateTime(2026, 9, 4),
);

void main() {
  for (final mood in ['', '—', 'Sem registro', '  —  ', '  ']) {
    test('placeholder mood "$mood" with no water is noData', () {
      expect(
        classifyHealthInsightDataState(AsyncData(_health(mood: mood))),
        HealthInsightDataState.noData,
      );
    });
  }

  test('real mood alone is realData', () {
    expect(
      classifyHealthInsightDataState(AsyncData(_health(mood: 'Cansado'))),
      HealthInsightDataState.realData,
    );
  });

  test('water alone is realData', () {
    expect(
      classifyHealthInsightDataState(AsyncData(_health(water: 1))),
      HealthInsightDataState.realData,
    );
  });

  test('cycle and pill do not establish score data', () {
    for (final health in [
      _health().copyWith(menstrualCycle: {'isEnabled': true}),
      _health().copyWith(hasTakenPillToday: true),
      _health().copyWith(
        menstrualCycle: {'isEnabled': true},
        hasTakenPillToday: true,
      ),
    ]) {
      expect(
        classifyHealthInsightDataState(AsyncData(health)),
        HealthInsightDataState.noData,
      );
    }
  });

  test('AsyncLoading is classified as loading', () {
    const loading = AsyncLoading<HealthModel>();
    expect(
      classifyHealthInsightDataState(loading),
      HealthInsightDataState.loading,
    );
  });

  test('AsyncError is classified as unavailable', () {
    final error = AsyncError<HealthModel>(
      StateError('unavailable'),
      StackTrace.empty,
    );
    expect(
      classifyHealthInsightDataState(error),
      HealthInsightDataState.unavailable,
    );
  });

  test(
    'current insight observes health transitions and preserves dashboard scores',
    () async {
      final stream = StreamController<HealthModel>.broadcast();
      final engine = _RecordingEngine();
      final container = ProviderContainer(
        overrides: [
          insightEngineProvider.overrideWithValue(engine),
          homeStateProvider.overrideWith(
            (ref) => HomeStateData(
              dashboard: const DashboardModel(
                productivityScore: 85,
                healthScore: 20,
                financialScore: 65,
                studyStreak: 3,
                studyReviewQueue: 0,
                studyProgress: 0,
                activeMedications: 0,
                transactionsCount: 0,
                financeBalance: 0,
              ),
              completedHabitsToday: 0,
              totalHabits: 0,
              nextExam: null,
              medicationCount: 0,
            ),
          ),
          healthStreamProvider.overrideWith((ref) => stream.stream),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await stream.close();
      });
      container.listen(currentInsightProvider, (_, _) {});

      void expectState(HealthInsightDataState state) {
        final insight = container.read(currentInsightProvider);
        expect(engine.context.healthDataState, state);
        expect(engine.context.healthScore, 20);
        expect(engine.context.productivityScore, 85);
        expect(engine.context.financialScore, 65);
        expect(engine.context.studyStreak, 3);
        expect(
          insight.id,
          state == HealthInsightDataState.realData
              ? 'critical_health_warning'
              : isNot('critical_health_warning'),
        );
      }

      expectState(HealthInsightDataState.loading);
      stream.add(_health());
      await container.pump();
      expectState(HealthInsightDataState.noData);
      stream.add(_health(mood: 'Cansado'));
      await container.pump();
      expectState(HealthInsightDataState.realData);
      stream.addError(StateError('unavailable'));
      await container.pump();
      expect(container.read(healthStreamProvider).hasValue, isTrue);
      expectState(HealthInsightDataState.unavailable);
      stream.add(_health());
      await container.pump();
      expectState(HealthInsightDataState.noData);
      stream.add(_health(water: 1));
      await container.pump();
      expectState(HealthInsightDataState.realData);
      container.invalidate(healthStreamProvider);
      expectState(HealthInsightDataState.loading);
      expect(container.read(healthStreamProvider).hasValue, isTrue);
    },
  );
}
