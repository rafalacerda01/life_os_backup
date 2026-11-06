import 'dart:async';
import 'package:life_os/core/services/emulator_account_runtime.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/core/services/firebase_auth_provider.dart';
import 'package:life_os/core/database/local_account_session.dart';
import 'package:life_os/core/database/database_provider.dart';
import 'package:life_os/features/settings/presentation/providers/analytics_provider.dart';
import 'package:life_os/features/habits/data/models/habit_model.dart';

import 'package:life_os/features/habits/data/repositories/habits_repository.dart';

// 1. PROVIDER DO REPOSITÓRIO
final habitsRepositoryProvider = Provider((ref) {
  return HabitsRepository(
    ref.watch(databaseProvider),
    ref.watch(firebaseFirestoreProvider),
    ref.watch(firebaseAuthProvider),
    sessionLease: ref.watch(localAccountSessionProvider).identity == null ? null : ref.read(localAccountSessionProvider.notifier).capture(),
  );
});

typedef ManualHabitTodayToggle =
    Future<void> Function(
      String habitId,
      List<String> currentDates,
      bool wasCompletedToday,
    );

final manualHabitTodayToggleProvider = Provider<ManualHabitTodayToggle>((ref) {
  final repository = ref.watch(habitsRepositoryProvider);
  if (ref.watch(emulatorAccountRuntimeProvider) != null) return (id, dates, wasDone) => repository.toggleHabitToday(id, dates);
  final analytics = ref.watch(analyticsServiceProvider);
  final isSessionActive = ref.watch(analyticsSessionActiveProvider);
  return (habitId, currentDates, wasCompletedToday) async {
    final sessionActive = isSessionActive();
    await repository.toggleHabitToday(habitId, currentDates);
    if (sessionActive && !wasCompletedToday) {
      unawaited(analytics.logHabitCompleted());
    }
  };
});

// 2. STREAM PROVIDER: Escuta o banco LOCAL (Drift) através do Repositório
final habitsStreamProvider = StreamProvider.autoDispose<List<HabitModel>>((ref) {
  return ref.watch(habitsRepositoryProvider).getHabitsStream();
});
