import 'package:life_os/core/services/sync_manager_provider.dart';
import 'package:life_os/core/services/firebase_auth_provider.dart';
import 'package:life_os/core/database/local_account_session.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/core/database/database_provider.dart';
import 'package:life_os/core/database/app_database.dart'; // Necessário para a classe CheckInEntry

import 'package:life_os/features/checkin/data/repositories/checkin_repository.dart';

// 1. PROVIDER DO REPOSITÓRIO (Agora com injeção completa de Firebase e Drift)
final checkInRepositoryProvider = Provider<CheckInRepository>((ref) {
  final database = ref.watch(databaseProvider);
  if (database.isLocalOnly) return CheckInRepository.local(database);
  final manager = ref.watch(syncManagerProvider);
  return CheckInRepository(
    database,
    ref.watch(firebaseFirestoreProvider),
    ref.watch(firebaseAuthProvider),
    sessionLease: ref.watch(localAccountSessionProvider).identity == null
        ? null
        : ref.read(localAccountSessionProvider.notifier).capture(),
    replaySyncQueue: manager.processPendingItems,
  );
});

// 2. STREAM PROVIDER PARA A UI
final checkInStreamProvider = StreamProvider<List<CheckInEntry>>((ref) {
  return ref.watch(checkInRepositoryProvider).watchCheckIns();
});
