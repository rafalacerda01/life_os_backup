import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:life_os/core/database/database_provider.dart';
import 'package:life_os/core/network/activity_remote_data_source.dart';
import 'package:life_os/features/habits/data/models/habit_model.dart';

import 'package:life_os/features/habits/data/repositories/habits_repository.dart';

// 1. PROVIDER DO REPOSITÓRIO
final habitsRepositoryProvider = Provider((ref) {
  return HabitsRepository(
    ref.watch(databaseProvider),
    FirebaseFirestore.instance,
    FirebaseAuth.instance,
    ref.watch(activityRemoteDataSourceProvider),
  );
});

// 2. STREAM PROVIDER: Escuta o banco LOCAL (Drift) através do Repositório
final habitsStreamProvider = StreamProvider<List<HabitModel>>((ref) {
  return ref.watch(habitsRepositoryProvider).getHabitsStream();
});
