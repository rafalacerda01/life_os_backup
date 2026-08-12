import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:drift/drift.dart' as drift hide Column;
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/database_provider.dart';
import 'package:life_os/core/services/notification_service.dart';
import 'package:life_os/features/health/data/models/health_model.dart';
import 'package:life_os/features/health/data/repositories/health_repository.dart';

// ===========================================================================
// REPOSITORY
// ===========================================================================

final healthRepositoryProvider = Provider<HealthRepository>((ref) {
  final db = ref.watch(databaseProvider);

  return HealthRepository(
    NotificationService(),
    FirebaseFirestore.instance,
    FirebaseAuth.instance,
    db,
  );
});

// ===========================================================================
// SAÚDE DIÁRIA
// ===========================================================================

final healthStreamProvider = StreamProvider<HealthModel>((ref) {
  final repository = ref.watch(healthRepositoryProvider);

  // 🛡️ CORREÇÃO: Removido o .cast<HealthModel>() que estava matando o Broadcast
  // e impedindo a UI de receber as atualizações em tempo real.
  return repository.getHealthStream();
});

// ===========================================================================
// MEDICAMENTOS
// ===========================================================================

final medicationsStreamProvider = StreamProvider<List<Medication>>((ref) {
  final db = ref.watch(databaseProvider);

  return (db.select(db.medications)..orderBy([
        (table) => drift.OrderingTerm(
          expression: table.startDate,
          mode: drift.OrderingMode.desc,
        ),
      ]))
      .watch();
});
