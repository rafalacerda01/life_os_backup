import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/features/home/data/repositories/home_repository.dart';
import 'package:life_os/features/habits/presentation/providers/habits_provider.dart';
import 'package:life_os/features/study/presentation/providers/study_provider.dart';
import 'package:life_os/features/health/presentation/providers/health_provider.dart';
import 'package:life_os/features/dashboard/data/models/dashboard_model.dart';
import 'package:life_os/features/dashboard/presentation/providers/dashboard_provider.dart';

final homeRepositoryProvider = Provider<HomeRepository>((ref) {
  return HomeRepository();
});

class HomeStateData {
  final DashboardModel dashboard;
  final int completedHabitsToday;
  final int totalHabits;
  final dynamic nextExam;
  final int medicationCount;
  final bool isLoading; // 🟢 NOVO: Controle de estado de carregamento

  HomeStateData({
    required this.dashboard,
    required this.completedHabitsToday,
    required this.totalHabits,
    required this.nextExam,
    required this.medicationCount,
    this.isLoading = false, // Começa como falso por padrão
  });
}

final homeStateProvider = Provider<HomeStateData>((ref) {
  final repository = ref.watch(homeRepositoryProvider);
  final dashboard = ref.watch(dashboardStateProvider);
  final habitsAsync = ref.watch(habitsStreamProvider);
  final medicationsAsync = ref.watch(medicationsStreamProvider);
  final subjectsAsync = ref.watch(subjectsStreamProvider);

  // 🟢 NOVO: Verifica se ALGUM dos streams está em carregamento
  final isDataLoading =
      habitsAsync.isLoading ||
      medicationsAsync.isLoading ||
      subjectsAsync.isLoading;

  final now = DateTime.now();
  final habits = habitsAsync.value ?? [];
  final subjects = subjectsAsync.value ?? [];

  final medicationsCount = medicationsAsync.when(
    data: (meds) => meds.length,
    loading: () => 0,
    error: (_, _) => 0,
  );

  return HomeStateData(
    dashboard: dashboard,
    completedHabitsToday: repository.getCompletedHabitsCount(habits, now),
    totalHabits: habits.length,
    nextExam: repository.getNextExam(subjects, now),
    medicationCount: medicationsCount,
    isLoading: isDataLoading, // 🟢 NOVO: Repassa para a UI
  );
});
