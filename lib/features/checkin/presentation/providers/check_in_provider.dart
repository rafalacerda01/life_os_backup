import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/core/database/database_provider.dart';
import 'package:life_os/core/database/app_database.dart'; // Necessário para a classe CheckInEntry

import 'package:life_os/features/checkin/data/repositories/checkin_repository.dart';

// 1. PROVIDER DO REPOSITÓRIO (Agora com injeção completa de Firebase e Drift)
final checkInRepositoryProvider = Provider<CheckInRepository>((ref) {
  return CheckInRepository(
    ref.watch(databaseProvider),
    FirebaseFirestore.instance,
    FirebaseAuth.instance,
  );
});

// 2. STREAM PROVIDER PARA A UI
final checkInStreamProvider = StreamProvider<List<CheckInEntry>>((ref) {
  return ref.watch(checkInRepositoryProvider).watchCheckIns();
});
