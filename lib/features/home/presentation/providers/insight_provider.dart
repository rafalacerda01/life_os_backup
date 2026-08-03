import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/features/home/presentation/providers/home_provider.dart';
import 'package:life_os/features/dashboard/domain/entities/models/insight_model.dart';
import 'package:life_os/features/dashboard/domain/entities/models/insight_engine.dart';

final insightEngineProvider = Provider<InsightEngine>((ref) => InsightEngine());

final currentInsightProvider = Provider<InsightModel>((ref) {
  final engine = ref.watch(insightEngineProvider);
  final homeState = ref.watch(homeStateProvider);
  final dashboard = homeState.dashboard;

  final context = InsightContext(
    productivityScore: dashboard.productivityScore,
    healthScore: dashboard.healthScore,
    financialScore: dashboard.financialScore,
    studyStreak: dashboard.studyStreak,
    currentTime: DateTime.now(),
    isPremium: true,
  );

  return engine.getBestInsight(context);
});
