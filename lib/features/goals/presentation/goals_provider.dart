import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/core/database/database_provider.dart';

import 'package:life_os/features/goals/domain/entities/goal_entity.dart';
// 🚀 Atualize este import caso o caminho do seu repositório seja diferente:
import 'package:life_os/features/goals/data/models/local/repositories/goal_repository.dart';

// --- INJEÇÃO DO REPOSITÓRIO ---
final goalRepositoryProvider = Provider((ref) {
  return GoalRepository(
    ref.watch(databaseProvider),
    FirebaseFirestore.instance,
    FirebaseAuth.instance,
  );
});

// --- PROVIDERS DE LEITURA (STREAMS) ---
final goalsStreamProvider = StreamProvider.autoDispose<List<GoalEntity>>((ref) {
  return ref.watch(goalRepositoryProvider).getGoalsStream();
});
