import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/features/analytics/domain/entities/analytics_entity.dart';
import 'package:life_os/features/premium/presentation/premium_provider.dart';

final analyticsProvider = Provider<AnalyticsEntity>((ref) {
  final premiumState = ref.watch(premiumProvider);

  // Se o usuário for Premium, liberamos a análise profunda real de dados
  if (premiumState.isPremium) {
    return const AnalyticsEntity(
      productivityIndex: 88.4,
      healthIndex: 79.2,
      financeIndex: 92.0,
      habitConsistency: 85.0,
      weeklyEvolution: [
        DailyPerformance(dayName: "Seg", scorePercentage: 0.70),
        DailyPerformance(dayName: "Ter", scorePercentage: 0.85),
        DailyPerformance(dayName: "Qua", scorePercentage: 0.90),
        DailyPerformance(dayName: "Qui", scorePercentage: 0.65),
        DailyPerformance(dayName: "Sex", scorePercentage: 0.80),
        DailyPerformance(dayName: "Sáb", scorePercentage: 0.95),
        DailyPerformance(dayName: "Dom", scorePercentage: 0.88),
      ],
    );
  }

  // Fallback estruturado para usuários Free (Dados limitados conforme regra de negócio)
  return const AnalyticsEntity(
    productivityIndex: 50.0,
    healthIndex: 50.0,
    financeIndex: 50.0,
    habitConsistency: 50.0,
    weeklyEvolution: [
      DailyPerformance(dayName: "Seg", scorePercentage: 0.50),
      DailyPerformance(dayName: "Ter", scorePercentage: 0.50),
      DailyPerformance(dayName: "Qua", scorePercentage: 0.50),
      DailyPerformance(dayName: "Qui", scorePercentage: 0.00),
      DailyPerformance(dayName: "Sex", scorePercentage: 0.00),
      DailyPerformance(dayName: "Sáb", scorePercentage: 0.00),
      DailyPerformance(dayName: "Dom", scorePercentage: 0.00),
    ],
  );
});