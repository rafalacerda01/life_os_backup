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

enum HomeLoadState { loading, ready, unavailable }

HomeLoadState classifyHomeLoadState(
  DashboardLoadState dashboardState,
  Iterable<AsyncValue<dynamic>> sources,
) {
  if (dashboardState == DashboardLoadState.unavailable ||
      sources.any((source) => source.hasError && !source.hasValue)) {
    return HomeLoadState.unavailable;
  }
  if (dashboardState == DashboardLoadState.loading ||
      sources.any((source) => source.isLoading && !source.hasValue)) {
    return HomeLoadState.loading;
  }
  return HomeLoadState.ready;
}

class HomeStateData {
  final DashboardModel dashboard;
  final int completedHabitsToday;
  final int totalHabits;
  final dynamic nextExam;
  final int medicationCount;
  final HomeLoadState loadState;

  HomeStateData({
    required this.dashboard,
    required this.completedHabitsToday,
    required this.totalHabits,
    required this.nextExam,
    required this.medicationCount,
    this.loadState = HomeLoadState.ready,
  });

  bool get isLoading => loadState == HomeLoadState.loading;
  bool get isUnavailable => loadState == HomeLoadState.unavailable;
}

final homeStateProvider = Provider<HomeStateData>((ref) {
  final repository = ref.watch(homeRepositoryProvider);
  final dashboard = ref.watch(dashboardStateProvider);
  final dashboardLoadState = ref.watch(dashboardLoadStateProvider);
  final habitsAsync = ref.watch(habitsStreamProvider);
  final medicationsAsync = ref.watch(medicationsStreamProvider);
  final subjectsAsync = ref.watch(subjectsStreamProvider);

  final loadState = classifyHomeLoadState(dashboardLoadState, [
    habitsAsync,
    medicationsAsync,
    subjectsAsync,
  ]);

  final now = DateTime.now();
  final habits = habitsAsync.value ?? [];
  final subjects = subjectsAsync.value ?? [];

  final medicationsCount = medicationsAsync.value?.length ?? 0;

  return HomeStateData(
    dashboard: dashboard,
    completedHabitsToday: repository.getCompletedHabitsCount(habits, now),
    totalHabits: habits.length,
    nextExam: repository.getNextExam(subjects, now),
    medicationCount: medicationsCount,
    loadState: loadState,
  );
});
