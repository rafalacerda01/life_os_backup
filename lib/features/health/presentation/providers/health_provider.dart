import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';
import 'package:drift/drift.dart';

import '../../data/models/health_model.dart';
import 'package:life_os/core/services/notification_service.dart';
import 'package:life_os/core/security/input_sanitizer.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/database_provider.dart';

// Providers
final healthStreamProvider = StreamProvider<HealthModel>((ref) {
  return ref.watch(healthRepositoryProvider).getHealthStream();
});

final medicationsStreamProvider = StreamProvider.autoDispose<List<Medication>>((
  ref,
) {
  final db = ref.watch(databaseProvider);
  return db.select(db.medications).watch();
});

final healthRepositoryProvider = Provider((ref) {
  final db = ref.watch(databaseProvider);
  return HealthRepository(
    NotificationService(),
    FirebaseFirestore.instance,
    FirebaseAuth.instance,
    db,
  );
});

class HealthRepository {
  final NotificationService _notifService;
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;
  final AppDatabase _db;

  HealthRepository(this._notifService, this._firestore, this._auth, this._db);

  String _getTodayDocId() => DateFormat('yyyy-MM-dd').format(DateTime.now());

  Future<void> syncHealthFromFirebase() async {
    final user = _auth.currentUser;
    if (user == null) {
      debugPrint("SYNC: Usuário não logado.");
      return;
    }

    try {
      debugPrint("SYNC: Iniciando sincronização...");

      // 1. Sincronizar Medicamentos
      final medsSnapshot = await _firestore
          .collection('users')
          .doc(user.uid)
          .collection('medications')
          .get();
      debugPrint(
        "SYNC: Encontrados ${medsSnapshot.docs.length} medicamentos no Firestore.",
      );

      for (var doc in medsSnapshot.docs) {
        final data = doc.data();
        final existing = await (_db.select(
          _db.medications,
        )..where((t) => t.firestoreId.equals(doc.id))).get();

        if (existing.isEmpty) {
          final startDate = (data['startDate'] as Timestamp).toDate();
          final name = data['name'] as String? ?? 'Sem nome';

          await _db
              .into(_db.medications)
              .insert(
                MedicationsCompanion.insert(
                  firestoreId: Value(doc.id),
                  name: name,
                  startDate: startDate,
                  durationDays: Value(data['durationDays'] as int?),
                  endDate: Value(
                    data['endDate'] != null
                        ? (data['endDate'] as Timestamp).toDate()
                        : null,
                  ),
                ),
              );

          // 🚀 CORREÇÃO: Garante que os alarmes sejam recriados se o usuário trocar de celular
          await _notifService.scheduleMedicationNotification(
            id: doc.id.hashCode.abs(),
            title: "Hora do medicamento 💊",
            body: "Está na hora de tomar: $name",
            scheduledDate: startDate,
            repeatDaily: true,
            preferenceKey: 'medication_reminders',
          );

          debugPrint("SYNC: Medicamento '$name' salvo e notificação agendada.");
        }
      }

      // 2. Sincronizar Saúde Diária
      final healthSnapshot = await _firestore
          .collection('users')
          .doc(user.uid)
          .collection('health_info')
          .get();
      for (var doc in healthSnapshot.docs) {
        final data = doc.data();
        final cycleData = data['menstrualCycle'];

        await _db
            .into(_db.healthEntries)
            .insertOnConflictUpdate(
              HealthEntriesCompanion(
                docId: Value(doc.id),
                mood: Value(data['mood'] as String? ?? ''),
                waterIntakeMl: Value(data['waterIntakeMl'] as int? ?? 0),
                hasTakenPillToday: Value(
                  data['hasTakenPillToday'] as bool? ?? false,
                ),
                menstrualCycleJson: Value(
                  cycleData != null ? jsonEncode(cycleData) : null,
                ),
                date: Value(
                  data['date'] != null
                      ? (data['date'] as Timestamp).toDate()
                      : DateTime.now(),
                ),
              ),
            );
      }
      debugPrint("SYNC: Sincronização concluída com sucesso.");
    } catch (e) {
      debugPrint("SYNC: ERRO CRÍTICO ao sincronizar: $e");
    }
  }

  Stream<HealthModel> getHealthStream() {
    return (_db.select(_db.healthEntries)
          ..orderBy([
            (t) => OrderingTerm(expression: t.date, mode: OrderingMode.desc),
          ])
          ..limit(1))
        .watchSingleOrNull()
        .map((entry) {
          if (entry == null) return HealthModel.initial();

          Map<String, dynamic>? decodedCycle;
          if (entry.menstrualCycleJson != null) {
            try {
              decodedCycle =
                  jsonDecode(entry.menstrualCycleJson!) as Map<String, dynamic>;
            } catch (e) {
              debugPrint("Erro ao decodificar ciclo menstrual: $e");
              decodedCycle = null;
            }
          }

          // Agora retornamos o modelo sem o campo 'activeMedications'
          return HealthModel(
            mood: entry.mood,
            waterIntakeMl: entry.waterIntakeMl,
            hasTakenPillToday: entry.hasTakenPillToday,
            menstrualCycle: decodedCycle,
            date: entry.date,
          );
        });
  }

  Future<void> updateCycleSettings(Map<String, dynamic> cycleData) async {
    final user = _auth.currentUser;
    if (user == null) return;

    await _db
        .into(_db.healthEntries)
        .insertOnConflictUpdate(
          HealthEntriesCompanion(
            docId: Value(_getTodayDocId()),
            menstrualCycleJson: Value(jsonEncode(cycleData)),
            date: Value(DateTime.now()),
          ),
        );

    try {
      await _firestore.collection('users').doc(user.uid).set({
        'menstrualCycle': cycleData,
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint("Sync falhou: $e");
    }
  }

  Future<void> addMedication(
    String name,
    DateTime startDate,
    int? durationDays,
  ) async {
    final user = _auth.currentUser;
    if (user == null) return;

    // 🚀 ADICIONADO: Pedido contextual de permissão.
    // O sistema operacional só mostrará o pop-up se o usuário ainda não tiver dado a permissão.
    await _notifService.requestPermissions();

    final cleanName = InputSanitizer.sanitize(name);
    DateTime? endDate = (durationDays != null && durationDays > 0)
        ? startDate.add(Duration(days: durationDays))
        : null;

    final localId = await _db
        .into(_db.medications)
        .insert(
          MedicationsCompanion.insert(
            firestoreId: const Value('pending'),
            name: cleanName,
            startDate: startDate,
            durationDays: Value(durationDays),
            endDate: Value(endDate),
          ),
        );

    try {
      final docRef = await _firestore
          .collection('users')
          .doc(user.uid)
          .collection('medications')
          .add({
            'name': cleanName,
            'startDate': Timestamp.fromDate(startDate),
            'durationDays': durationDays,
            'endDate': endDate != null ? Timestamp.fromDate(endDate) : null,
            'createdAt': FieldValue.serverTimestamp(),
          });

      await (_db.update(_db.medications)..where((t) => t.id.equals(localId)))
          .write(MedicationsCompanion(firestoreId: Value(docRef.id)));

      await _notifService.scheduleMedicationNotification(
        id: docRef.id.hashCode.abs(),
        title: "Hora do medicamento 💊",
        body: "Está na hora de tomar: $cleanName",
        scheduledDate: startDate,
        repeatDaily: true,
        preferenceKey: 'medication_reminders',
      );
    } catch (e) {
      debugPrint("Firebase inacessível: $e");
    }
  }

  Future<void> deleteMedication(String docId, int localId) async {
    final user = _auth.currentUser;
    if (user == null) return;

    await (_db.delete(
      _db.medications,
    )..where((t) => t.id.equals(localId))).go();

    if (docId.isNotEmpty && docId != 'pending') {
      try {
        await _firestore
            .collection('users')
            .doc(user.uid)
            .collection('medications')
            .doc(docId)
            .delete();

        await _notifService.cancelNotification(docId.hashCode.abs());
        debugPrint("Notificação cancelada para o medicamento $docId");
      } catch (e) {
        debugPrint("Erro ao remover: $e");
      }
    }
  }

  Future<void> _performDualWrite(
    HealthEntriesCompanion companion,
    Map<String, dynamic> firestoreData,
  ) async {
    final user = _auth.currentUser;
    if (user == null) return;

    await _db.into(_db.healthEntries).insertOnConflictUpdate(companion);

    try {
      await _firestore
          .collection('users')
          .doc(user.uid)
          .collection('health_info')
          .doc(_getTodayDocId())
          .set(firestoreData, SetOptions(merge: true));
    } catch (e) {
      debugPrint("Sync pendente: $e");
    }
  }

  Future<void> updateMood(String newMood) => _performDualWrite(
    HealthEntriesCompanion(
      docId: Value(_getTodayDocId()),
      mood: Value(newMood),
      date: Value(DateTime.now()),
    ),
    {'mood': newMood, 'date': Timestamp.now()},
  );

  Future<void> addWater(int currentWater) => _performDualWrite(
    HealthEntriesCompanion(
      docId: Value(_getTodayDocId()),
      waterIntakeMl: Value(currentWater + 250),
      date: Value(DateTime.now()),
    ),
    {'waterIntakeMl': currentWater + 250, 'date': Timestamp.now()},
  );

  Future<void> updatePillStatus(bool taken) => _performDualWrite(
    HealthEntriesCompanion(
      docId: Value(_getTodayDocId()),
      hasTakenPillToday: Value(taken),
      date: Value(DateTime.now()),
    ),
    {'hasTakenPillToday': taken, 'date': Timestamp.now()},
  );

  Future<void> toggleMenstrualCycleFeature(bool enable) async {
    await updateCycleSettings({
      'isEnabled': enable,
      'lastPeriodStart': DateTime.now().toIso8601String(),
      'cycleLengthDays': 28,
      'periodLengthDays': 5,
    });
  }
}
