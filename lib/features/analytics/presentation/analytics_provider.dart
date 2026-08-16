import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/features/analytics/domain/entities/analytics_entity.dart';
import 'package:life_os/features/analytics/data/analytics_repository.dart';
import 'package:life_os/features/premium/presentation/premium_provider.dart';
import 'package:life_os/features/tasks/presentation/providers/tasks_provider.dart';
import 'package:life_os/features/health/presentation/providers/health_provider.dart';
import 'package:life_os/features/finance/presentation/providers/finance_provider.dart';
import 'package:life_os/features/habits/presentation/providers/habits_provider.dart';
import 'package:life_os/features/premium/domain/services/feature_gate.dart';

// --- INJEÇÃO DO REPOSITÓRIO ---
final analyticsRepositoryProvider = Provider((ref) {
  return AnalyticsRepository();
});

// --- PROVIDER DE ESTADO ---
final analyticsProvider = Provider<AnalyticsEntity>((ref) {
  // 1. Escuta as mudanças
  final premiumState = ref.watch(premiumProvider);
  final tasksAsync = ref.watch(tasksStreamProvider);
  final healthAsync = ref.watch(healthStreamProvider);
  final financeAsync = ref.watch(financeStreamProvider);
  final habitsAsync = ref.watch(habitsStreamProvider);

  // 2. Extrai os dados
  final tasks = tasksAsync.asData?.value ?? [];
  final health = healthAsync.asData?.value;
  final transactions = financeAsync.asData?.value ?? [];
  final habits = habitsAsync.asData?.value ?? [];

  // 3. Delega o cálculo para o Repositório
  return ref
      .watch(analyticsRepositoryProvider)
      .generateAnalytics(
        isPremium: const FeatureGate().canAccess(
          status: premiumState,
          feature: PremiumFeature.analyticsAdvanced,
        ),
        tasks: tasks,
        health: health,
        transactions: transactions,
        habits: habits,
      );
});
