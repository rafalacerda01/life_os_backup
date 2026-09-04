import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:life_os/core/database/database_provider.dart';
import 'package:life_os/features/settings/presentation/providers/analytics_provider.dart';
import 'package:life_os/features/habits/data/models/habit_model.dart';

import 'package:life_os/features/habits/data/repositories/habits_repository.dart';

// 1. PROVIDER DO REPOSITÓRIO
final habitsRepositoryProvider = Provider((ref) {
  return HabitsRepository(
    ref.watch(databaseProvider),
    FirebaseFirestore.instance,
    FirebaseAuth.instance,
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
final habitsStreamProvider = StreamProvider<List<HabitModel>>((ref) {
  return ref.watch(habitsRepositoryProvider).getHabitsStream();
});
