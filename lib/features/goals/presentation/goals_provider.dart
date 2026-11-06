import 'package:life_os/core/services/firebase_auth_provider.dart';
import 'package:life_os/core/database/local_account_session.dart';
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
    ref.watch(firebaseFirestoreProvider),
    ref.watch(firebaseAuthProvider),
    sessionLease: ref.watch(localAccountSessionProvider).identity == null ? null : ref.read(localAccountSessionProvider.notifier).capture(),
  );
});

// --- PROVIDERS DE LEITURA (STREAMS) ---
final goalsStreamProvider = StreamProvider.autoDispose<List<GoalEntity>>((ref) {
  return ref.watch(goalRepositoryProvider).getGoalsStream();
});
