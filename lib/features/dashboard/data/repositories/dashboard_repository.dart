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
      final hasProductivityData = hasTasks || hasStudyGoals;

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
      final double waterScore = _calculateWaterScore(healthData);
      final double moodScore = _calculateMoodScore(healthData);
      final hasWaterData = _hasWaterData(healthData);
      final hasMoodData = _hasMoodData(healthData);
      final hasHealthData = hasWaterData || hasMoodData;
      final double healthScore;
      if (hasWaterData && hasMoodData) {
        healthScore = waterScore + moodScore;
      } else if (hasWaterData) {
        healthScore = waterScore / 50 * 100;
      } else if (hasMoodData) {
        healthScore = moodScore / 50 * 100;
      } else {
        healthScore = 0.0;
      }

      final hasFinancialData = transactions.isNotEmpty;
      final double financialScore = incomeSum > 0
          ? ((financeBalance / incomeSum) * 100).clamp(0.0, 100.0)
          : 0.0;

      return DashboardModel(
        productivityScore: productivityScore,
        hasProductivityData: hasProductivityData,
        healthScore: healthScore.clamp(0.0, 100.0),
        hasHealthData: hasHealthData,
        financialScore: financialScore,
        hasFinancialData: hasFinancialData,
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
        hasProductivityData: false,
        healthScore: 0.0,
        hasHealthData: false,
        financialScore: 0.0,
        hasFinancialData: false,
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

  double _calculateWaterScore(dynamic healthData) {
    final rawWaterIntake = healthData?.waterIntakeMl;
    final waterIntakeMl = _readPositiveInt(rawWaterIntake, fallback: 0);

    return ((waterIntakeMl.clamp(0, 3000) / 3000) * 50).toDouble();
  }

  double _calculateMoodScore(dynamic healthData) {
    final mood = healthData?.mood?.toString().trim();

    switch (mood) {
      case 'Radiante':
        return 50.0;
      case 'Focado':
        return 40.0;
      case 'Neutro':
        return 30.0;
      case 'Cansado':
        return 20.0;
      case 'Estressado':
        return 10.0;
      case null:
      case '':
      case '—':
      case 'Sem registro':
        return 0.0;
      default:
        return 0.0;
    }
  }

  bool _hasWaterData(dynamic healthData) {
    return _readPositiveInt(healthData?.waterIntakeMl, fallback: 0) > 0;
  }

  bool _hasMoodData(dynamic healthData) {
    final mood = healthData?.mood?.toString().trim() ?? '';
    return mood.isNotEmpty && mood != '—' && mood != 'Sem registro';
  }

  int _readPositiveInt(dynamic value, {required int fallback}) {
    if (value is num) {
      return value.toInt();
    }

    return int.tryParse(value?.toString() ?? '') ?? fallback;
  }
}
