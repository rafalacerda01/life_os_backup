import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/features/dashboard/data/models/dashboard_model.dart';
import 'package:life_os/features/dashboard/data/repositories/dashboard_repository.dart';
import 'package:life_os/features/finance/presentation/providers/finance_provider.dart';
import 'package:life_os/features/study/presentation/providers/study_provider.dart';
import 'package:life_os/features/health/presentation/providers/health_provider.dart';
import 'package:life_os/features/tasks/presentation/providers/tasks_provider.dart';

// --- INJEÇÃO DO REPOSITÓRIO ---
final dashboardRepositoryProvider = Provider<DashboardRepository>((ref) {
  return DashboardRepository();
});

// --- PROVIDER DE ESTADO ---
final dashboardStateProvider = Provider<DashboardModel>((ref) {
  // 1. Observa os providers de stream
  final financeAsync = ref.watch(financeStreamProvider);
  final studyAsync = ref.watch(studyStreamProvider);
  final healthAsync = ref.watch(healthStreamProvider);
  final tasksAsync = ref.watch(tasksStreamProvider);
  final medicationsAsync = ref.watch(medicationsStreamProvider);

  // 2. Extração segura de dados
  final transactions = financeAsync.asData?.value ?? [];
  final studyData = studyAsync.asData?.value;
  final healthData = healthAsync.asData?.value;
  final taskList = tasksAsync.asData?.value ?? [];
  final medicationsList = medicationsAsync.asData?.value ?? [];

  // 3. Delega o processamento pesado para o Repositório
  return ref
      .watch(dashboardRepositoryProvider)
      .generateDashboard(
        transactions: transactions,
        studyData: studyData,
        healthData: healthData,
        taskList: taskList,
        medicationsList: medicationsList,
      );
});
