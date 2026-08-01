import 'package:intl/intl.dart';
import 'package:life_os/core/utils/app_logger.dart';
import 'package:life_os/features/analytics/domain/entities/analytics_entity.dart';

import 'package:life_os/features/tasks/domain/entities/task_entity.dart';
import 'package:life_os/features/health/domain/entities/health_log_entity.dart';
import 'package:life_os/features/finance/domain/entities/transaction_entity.dart';
import 'package:life_os/features/habits/domain/entities/habit_entity.dart';

class AnalyticsRepository {
  AnalyticsEntity generateAnalytics({
    required bool isPremium,
    required List<dynamic> tasks, // Substitua 'dynamic' por 'TaskEntity'
    required dynamic health, // Substitua 'dynamic' por 'HealthEntity'
    required List<dynamic> transactions, // Substitua por 'TransactionEntity'
    required List<dynamic> habits, // Substitua por 'HabitEntity'
  }) {
    try {
      if (!isPremium) {
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
      }

      // 1. Produtividade
      double calculatedProductivity = 0.0;
      if (tasks.isNotEmpty) {
        final completedCount = tasks.where((t) => t.isCompleted).length;
        calculatedProductivity = (completedCount / tasks.length) * 100;
      }

      // 2. Saúde
      double calculatedHealth = 0.0;
      if (health != null) {
        final waterProgress = (health.waterIntakeMl / 2000.0).clamp(0.0, 1.0);
        calculatedHealth = waterProgress * 100;
      }

      // 3. Finanças
      double calculatedFinance = 0.0;
      if (transactions.isNotEmpty) {
        double totalIncome = 0;
        double totalExpense = 0;
        for (var tx in transactions) {
          if (tx.type == 'income') {
            totalIncome += tx.amount;
          } else {
            totalExpense += tx.amount;
          }
        }
        if (totalIncome > 0) {
          final ratio = (1 - (totalExpense / totalIncome)).clamp(0.0, 1.0);
          calculatedFinance = ratio * 100;
        }
      }

      // 4. Consistência de Hábitos Real
      double calculatedHabitsConsistency = 0.0;
      if (habits.isNotEmpty) {
        int totalPossibleChecks = habits.length * 7;
        int totalCompletedChecks = 0;

        final now = DateTime.now();
        for (int i = 0; i < 7; i++) {
          final targetDate = now.subtract(Duration(days: i));
          final dateStr = DateFormat('yyyy-MM-dd').format(targetDate);

          for (var habit in habits) {
            if (habit.completedDates.contains(dateStr)) {
              totalCompletedChecks++;
            }
          }
        }
        calculatedHabitsConsistency = totalPossibleChecks > 0
            ? (totalCompletedChecks / totalPossibleChecks) * 100
            : 0.0;
      }

      // 5. Evolução Semanal Dinâmica
      final now = DateTime.now();
      List<DailyPerformance> dynamicWeeklyEvolution = [];

      for (int i = 6; i >= 0; i--) {
        final dayDate = now.subtract(Duration(days: i));
        final dayStr = DateFormat('yyyy-MM-dd').format(dayDate);

        String dayNameLabel = _getShortDayName(dayDate.weekday);

        double dayScore = 0.0;
        if (habits.isNotEmpty) {
          int completedOnThatDay = 0;
          for (var habit in habits) {
            if (habit.completedDates.contains(dayStr)) {
              completedOnThatDay++;
            }
          }
          dayScore = (completedOnThatDay / habits.length).clamp(0.0, 1.0);
        } else {
          dayScore = 0.5;
        }

        dynamicWeeklyEvolution.add(
          DailyPerformance(dayName: dayNameLabel, scorePercentage: dayScore),
        );
      }

      return AnalyticsEntity(
        productivityIndex: calculatedProductivity,
        healthIndex: calculatedHealth,
        financeIndex: calculatedFinance,
        habitConsistency: calculatedHabitsConsistency,
        weeklyEvolution: dynamicWeeklyEvolution,
      );
    } catch (e, stack) {
      AppLogger.e('Erro ao calcular Analytics', e, stack);
      // Retorno de fallback seguro em caso de erro no cálculo
      return const AnalyticsEntity(
        productivityIndex: 0,
        healthIndex: 0,
        financeIndex: 0,
        habitConsistency: 0,
        weeklyEvolution: [],
      );
    }
  }

  String _getShortDayName(int weekday) {
    switch (weekday) {
      case 1:
        return "Seg";
      case 2:
        return "Ter";
      case 3:
        return "Qua";
      case 4:
        return "Qui";
      case 5:
        return "Sex";
      case 6:
        return "Sáb";
      case 7:
        return "Dom";
      default:
        return "";
    }
  }
}
