import 'package:life_os/core/utils/app_logger.dart';
import 'package:life_os/features/dashboard/data/models/dashboard_model.dart';

class DashboardRepository {
  DashboardModel generateDashboard({
    required List<dynamic> transactions,
    required dynamic studyData,
    required dynamic healthData,
    required List<dynamic> taskList,
    required List<dynamic> medicationsList,
  }) {
    try {
      // 1. Cálculos de Finanças
      double transactionsCount = transactions.length.toDouble();
      double incomeSum = 0;
      double expenseSum = 0;

      for (var t in transactions) {
        if (t.type == 'income') {
          incomeSum += t.amount;
        } else {
          expenseSum += t.amount;
        }
      }
      double financeBalance = incomeSum - expenseSum;

      // 2. Cálculos de produtividade e scores
      double studyProgress = studyData?.progress ?? 0.0;
      double studyRatio = studyProgress * 100;
      double productivityScore = 0.0;

      bool hasTasks = taskList.isNotEmpty;
      bool hasStudyGoals =
          studyProgress > 0.0 ||
          (studyData != null && studyData.reviewQueue > 0);

      if (!hasTasks && !hasStudyGoals) {
        productivityScore = 0.0;
      } else if (!hasTasks) {
        productivityScore = studyRatio.clamp(0.0, 100.0);
      } else if (!hasStudyGoals) {
        final completed = taskList.where((t) => t.isCompleted).length;
        double taskCompletionRatio = (completed / taskList.length) * 100;
        productivityScore = taskCompletionRatio.clamp(0.0, 100.0);
      } else {
        final completed = taskList.where((t) => t.isCompleted).length;
        double taskCompletionRatio = (completed / taskList.length) * 100;

        productivityScore = ((taskCompletionRatio * 0.7) + (studyRatio * 0.3))
            .clamp(0.0, 100.0);
      }

      // 3. Cálculos de Saúde e Finanças (Scores)
      double waterBonus = (healthData != null)
          ? (healthData.waterIntakeMl / 3000) * 40
          : 0;
      double moodBonus =
          (healthData?.mood == 'Radiante' || healthData?.mood == 'Focado')
          ? 10
          : 0;
      double healthScore = (50.0 + waterBonus + moodBonus).clamp(0.0, 100.0);
      double financialScore = financeBalance >= 0 ? 95.0 : 40.0;

      return DashboardModel(
        productivityScore: productivityScore,
        healthScore: healthScore,
        financialScore: financialScore,
        studyStreak: studyData?.streak ?? 0,
        studyReviewQueue: studyData?.reviewQueue ?? 0,
        studyProgress: studyProgress,
        activeMedications: medicationsList.length,
        mood: healthData?.mood ?? "—",
        financeBalance: financeBalance,
        transactionsCount: transactionsCount.toInt(),
      );
    } catch (e, stack) {
      AppLogger.e('Erro ao gerar dados do Dashboard', e, stack);
      // Retorno de fallback seguro em caso de erro nos cálculos
      return const DashboardModel(
        productivityScore: 0.0,
        healthScore: 50.0,
        financialScore: 50.0,
        studyStreak: 0,
        studyReviewQueue: 0,
        studyProgress: 0.0,
        activeMedications: 0,
        mood: "—",
        financeBalance: 0.0,
        transactionsCount: 0,
      );
    }
  }
}
