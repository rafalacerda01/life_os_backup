import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/features/finance/presentation/providers/finance_provider.dart';
import 'package:life_os/features/habits/data/models/habit_model.dart';
import 'package:life_os/features/habits/presentation/providers/habits_provider.dart';
import 'package:life_os/features/health/data/models/health_model.dart';
import 'package:life_os/features/health/presentation/providers/health_provider.dart';
import 'package:life_os/features/tasks/presentation/providers/tasks_provider.dart';
import 'package:life_os/features/tasks/data/models/task_model.dart';

typedef LocalAnalyticsSummary = ({
  int tasks,
  int completedTasks,
  int habitDays,
  int possibleHabitDays,
  FinanceSummary finance,
  int waterMl,
  int waterGoalMl,
});

LocalAnalyticsSummary summarizeLocalAnalytics({
  required Iterable<TaskModel> tasks,
  required Iterable<HabitModel> habits,
  required Iterable<Transaction> transactions,
  required HealthModel health,
  required int waterGoalMl,
  required DateTime now,
}) {
  final local = now.toLocal();
  final format = DateFormat('yyyy-MM-dd');
  final recentDays = {
    for (var offset = 0; offset < 7; offset++)
      format.format(DateTime(local.year, local.month, local.day - offset)),
  };
  return (
    tasks: tasks.length,
    completedTasks: tasks.where((task) => task.isCompleted).length,
    habitDays: habits.fold(
      0,
      (sum, habit) =>
          sum + habit.completedDates.toSet().intersection(recentDays).length,
    ),
    possibleHabitDays: habits.length * recentDays.length,
    finance: calculateFinanceSummary(transactions),
    waterMl: health.waterIntakeMl,
    waterGoalMl: waterGoalMl,
  );
}

final localAnalyticsProvider = Provider<AsyncValue<LocalAnalyticsSummary>>((
  ref,
) {
  final tasks = ref.watch(tasksStreamProvider);
  final habits = ref.watch(habitsStreamProvider);
  final transactions = ref.watch(financeStreamProvider);
  final health = ref.watch(healthStreamProvider);
  final goal = ref.watch(localWaterGoalProvider);
  final values = <AsyncValue<Object?>>[
    tasks,
    habits,
    transactions,
    health,
    goal,
  ];
  for (final value in values) {
    if (value.hasError) return AsyncError(value.error!, value.stackTrace!);
  }
  if (values.any((value) => !value.hasValue)) return const AsyncLoading();
  return AsyncData(
    summarizeLocalAnalytics(
      tasks: tasks.requireValue,
      habits: habits.requireValue,
      transactions: transactions.requireValue,
      health: health.requireValue,
      waterGoalMl: goal.requireValue,
      now: ref.watch(healthDayClockProvider)(),
    ),
  );
});

class LocalAnalyticsScreen extends ConsumerWidget {
  const LocalAnalyticsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = ref.watch(localAnalyticsProvider);
    final currency = NumberFormat.currency(locale: 'pt_BR', symbol: 'R\$');
    return Scaffold(
      appBar: AppBar(title: const Text('Análises')),
      body: summary.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => Center(
          child: FilledButton(
            onPressed: () {
              ref.invalidate(tasksStreamProvider);
              ref.invalidate(habitsStreamProvider);
              ref.invalidate(financeStreamProvider);
              ref.invalidate(healthStreamProvider);
              ref.invalidate(localWaterGoalProvider);
            },
            child: const Text('Recarregar análises'),
          ),
        ),
        data: (data) => ListView(
          padding: const EdgeInsets.all(20),
          children: [
            ListTile(
              leading: const Icon(Icons.checklist),
              title: const Text('Tarefas concluídas'),
              subtitle: Text('${data.completedTasks} de ${data.tasks}'),
            ),
            ListTile(
              leading: const Icon(Icons.repeat),
              title: const Text('Hábitos nos últimos sete dias'),
              subtitle: Text(
                '${data.habitDays} de ${data.possibleHabitDays} registros possíveis',
              ),
            ),
            ListTile(
              leading: const Icon(Icons.water_drop_outlined),
              title: const Text('Hidratação de hoje'),
              subtitle: Text('${data.waterMl} ml de ${data.waterGoalMl} ml'),
            ),
            ListTile(
              leading: const Icon(Icons.account_balance_wallet_outlined),
              title: const Text('Saldo dos lançamentos'),
              subtitle: Text(currency.format(data.finance.balance)),
            ),
          ],
        ),
      ),
    );
  }
}
