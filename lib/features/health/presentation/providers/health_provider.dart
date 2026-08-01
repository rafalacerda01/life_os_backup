import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'package:life_os/core/services/notification_service.dart';
import 'package:life_os/core/database/database_provider.dart';
import 'package:life_os/core/database/app_database.dart'; // Necessário para o tipo Medication
import 'package:life_os/features/health/data/models/health_model.dart';

// 🚀 Atualize este import com o caminho correto
import 'package:life_os/features/health/data/repositories/health_repository.dart';

// --- INJEÇÃO DO REPOSITÓRIO ---
final healthRepositoryProvider = Provider((ref) {
  final db = ref.watch(databaseProvider);
  return HealthRepository(
    NotificationService(),
    FirebaseFirestore.instance,
    FirebaseAuth.instance,
    db,
  );
});

// --- PROVIDERS DE LEITURA (STREAMS) ---
final healthStreamProvider = StreamProvider<HealthModel>((ref) {
  return ref.watch(healthRepositoryProvider).getHealthStream();
});

final medicationsStreamProvider = StreamProvider.autoDispose<List<Medication>>((
  ref,
) {
  final db = ref.watch(databaseProvider);
  return db.select(db.medications).watch();
});
