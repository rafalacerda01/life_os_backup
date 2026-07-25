import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/features/dashboard/data/models/dashboard_model.dart';
import 'package:life_os/features/finance/presentation/providers/finance_provider.dart';
import 'package:life_os/features/study/presentation/providers/study_provider.dart';
import 'package:life_os/features/health/presentation/providers/health_provider.dart';
import 'package:life_os/features/tasks/presentation/providers/tasks_provider.dart';

final dashboardStateProvider = Provider<DashboardModel>((ref) {
  // Observa os providers
  final financeAsync = ref.watch(financeStreamProvider);
  final studyAsync = ref.watch(studyStreamProvider);
  final healthAsync = ref.watch(healthStreamProvider);
  final tasksAsync = ref.watch(tasksStreamProvider);
  // Adicionamos o provider de medicamentos para contagem
  final medicationsAsync = ref.watch(medicationsStreamProvider);

  // Extração segura de dados
  final transactions = financeAsync.asData?.value ?? [];
  final studyData = studyAsync.asData?.value;
  final healthData = healthAsync.asData?.value;
  final taskList = tasksAsync.asData?.value ?? [];
  // Pegamos a lista de medicamentos para contar
  final medicationsList = medicationsAsync.asData?.value ?? [];

  // Cálculos de Finanças
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

  // Cálculos de produtividade e scores
  double studyProgress = studyData?.progress ?? 0.0;
  double studyRatio = studyProgress * 100;
  double productivityScore = 0.0;

  bool hasTasks = taskList.isNotEmpty;
  bool hasStudyGoals =
      studyProgress > 0.0 || (studyData != null && studyData.reviewQueue > 0);

  if (!hasTasks && !hasStudyGoals) {
    // Se não há absolutamente nada planejado para hoje
    productivityScore = 0.0;
  } else if (!hasTasks) {
    // Se tem apenas estudos, a produtividade diária reflete 100% o progresso dos estudos
    productivityScore = studyRatio.clamp(0.0, 100.0);
  } else if (!hasStudyGoals) {
    // Se tem apenas tarefas, a produtividade reflete 100% a conclusão das tarefas
    final completed = taskList.where((t) => t.isCompleted).length;
    double taskCompletionRatio = (completed / taskList.length) * 100;
    productivityScore = taskCompletionRatio.clamp(0.0, 100.0);
  } else {
    // Se tem AMBOS (Tarefas e Estudos), aplica a divisão ponderada (70% tarefas, 30% estudos)
    final completed = taskList.where((t) => t.isCompleted).length;
    double taskCompletionRatio = (completed / taskList.length) * 100;

    productivityScore = ((taskCompletionRatio * 0.7) + (studyRatio * 0.3))
        .clamp(0.0, 100.0);
  }

  double waterBonus = (healthData != null)
      ? (healthData.waterIntakeMl / 3000) * 40
      : 0;
  double moodBonus =
      (healthData?.mood == 'Radiante' || healthData?.mood == 'Focado') ? 10 : 0;
  double healthScore = (50.0 + waterBonus + moodBonus).clamp(0.0, 100.0);
  double financialScore = financeBalance >= 0 ? 95.0 : 40.0;

  return DashboardModel(
    productivityScore: productivityScore,
    healthScore: healthScore,
    financialScore: financialScore,
    studyStreak: studyData?.streak ?? 0,
    studyReviewQueue: studyData?.reviewQueue ?? 0,
    studyProgress: studyProgress,
    // Agora usamos o tamanho da lista que observamos acima
    activeMedications: medicationsList.length,
    mood: healthData?.mood ?? "—",
    financeBalance: financeBalance,
    transactionsCount: transactionsCount.toInt(),
  );
});
