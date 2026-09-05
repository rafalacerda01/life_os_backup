import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/features/health/data/models/health_model.dart';
import 'package:life_os/features/health/presentation/providers/health_provider.dart';
import 'package:life_os/features/home/presentation/providers/home_provider.dart';
import 'package:life_os/features/dashboard/domain/entities/models/insight_model.dart';
import 'package:life_os/features/dashboard/domain/entities/models/insight_engine.dart';

final insightEngineProvider = Provider<InsightEngine>((ref) => InsightEngine());

HealthInsightDataState classifyHealthInsightDataState(
  AsyncValue<HealthModel> health,
) {
  // Refresh/error states must not use a previously cached value as evidence.
  if (health.isLoading) return HealthInsightDataState.loading;
  if (health.hasError) return HealthInsightDataState.unavailable;

  final data = health.asData?.value;
  final mood = data?.mood.trim() ?? '';
  final hasMood = mood.isNotEmpty && mood != '—' && mood != 'Sem registro';
  return hasMood || (data?.waterIntakeMl ?? 0) > 0
      ? HealthInsightDataState.realData
      : HealthInsightDataState.noData;
}

final currentInsightProvider = Provider<InsightModel>((ref) {
  final engine = ref.watch(insightEngineProvider);
  final homeState = ref.watch(homeStateProvider);
  final dashboard = homeState.dashboard;
  final health = ref.watch(healthStreamProvider);

  final context = InsightContext(
    productivityScore: dashboard.productivityScore,
    healthScore: dashboard.healthScore,
    healthDataState: classifyHealthInsightDataState(health),
    financialScore: dashboard.financialScore,
    studyStreak: dashboard.studyStreak,
    currentTime: DateTime.now(),
    isPremium: true,
  );

  return engine.getBestInsight(context);
});
