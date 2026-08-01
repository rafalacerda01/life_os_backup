import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import 'package:life_os/core/utils/app_logger.dart'; // 🚀 Nosso Logger
import 'package:life_os/core/services/notification_service.dart';
import 'package:life_os/core/security/input_sanitizer.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/features/health/data/models/health_model.dart';

class HealthRepository {
  final NotificationService _notifService;
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;
  final AppDatabase _db;
  final _uuid = const Uuid(); // Para gerar IDs offline

  HealthRepository(this._notifService, this._firestore, this._auth, this._db);

  String _getTodayDocId() => DateFormat('yyyy-MM-dd').format(DateTime.now());

  // ===========================================================================
  // 1. LEITURA (STREAMS LOCAIS)
  // ===========================================================================

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
            } catch (e, stack) {
              AppLogger.e("Erro ao decodificar ciclo menstrual", e, stack);
              decodedCycle = null;
            }
          }

          return HealthModel(
            mood: entry.mood,
            waterIntakeMl: entry.waterIntakeMl,
            hasTakenPillToday: entry.hasTakenPillToday,
            menstrualCycle: decodedCycle,
            date: entry.date,
          );
        });
  }

  // ===========================================================================
  // 2. ESCRITA (OFFLINE-FIRST)
  // ===========================================================================

  Future<void> updateCycleSettings(Map<String, dynamic> cycleData) async {
    if (_auth.currentUser == null) return;

    try {
      // 1. Local
      await _db
          .into(_db.healthEntries)
          .insertOnConflictUpdate(
            HealthEntriesCompanion(
              docId: Value(_getTodayDocId()),
              menstrualCycleJson: Value(jsonEncode(cycleData)),
              date: Value(DateTime.now()),
            ),
          );

      // 2. Remoto (Background)
      unawaited(_syncCycleSettingsInFirestore(cycleData));
    } catch (e, stack) {
      AppLogger.e('Erro ao atualizar ciclo menstrual local', e, stack);
      rethrow;
    }
  }

  Future<void> addMedication(
    String name,
    DateTime startDate,
    int? durationDays,
  ) async {
    if (_auth.currentUser == null) return;

    await _notifService.requestPermissions();

    final cleanName = InputSanitizer.sanitize(name);
    DateTime? endDate = (durationDays != null && durationDays > 0)
        ? startDate.add(Duration(days: durationDays))
        : null;

    final firestoreId = _uuid.v4(); // 🚀 ID gerado localmente!

    try {
      // 1. Salva Localmente com ID definitivo
      await _db
          .into(_db.medications)
          .insert(
            MedicationsCompanion.insert(
              firestoreId: Value(firestoreId),
              name: cleanName,
              startDate: startDate,
              durationDays: Value(durationDays),
              endDate: Value(endDate),
            ),
          );

      // 2. Agenda notificação
      await _notifService.scheduleMedicationNotification(
        id: firestoreId.hashCode.abs(),
        title: "Hora do medicamento 💊",
        body: "Está na hora de tomar: $cleanName",
        scheduledDate: startDate,
        repeatDaily: true,
        preferenceKey: 'medication_reminders',
      );

      // 3. Envia pro Firebase em Background
      unawaited(
        _addMedicationInFirestore(
          firestoreId,
          cleanName,
          startDate,
          durationDays,
          endDate,
        ),
      );
    } catch (e, stack) {
      AppLogger.e('Erro ao adicionar medicamento local', e, stack);
      rethrow;
    }
  }

  Future<void> deleteMedication(String docId, int localId) async {
    if (_auth.currentUser == null) return;

    try {
      // 1. Apaga Local
      await (_db.delete(
        _db.medications,
      )..where((t) => t.id.equals(localId))).go();

      // 2. Cancela notificação
      await _notifService.cancelNotification(docId.hashCode.abs());
      AppLogger.i("Notificação cancelada para o medicamento $docId");

      // 3. Apaga Remoto (Background)
      if (docId.isNotEmpty && docId != 'pending') {
        unawaited(_deleteMedicationInFirestore(docId));
      }
    } catch (e, stack) {
      AppLogger.e('Erro ao deletar medicamento local', e, stack);
      rethrow;
    }
  }

  // --- Helpers Locais de Saúde Diária ---

  Future<void> _performDualWrite(
    HealthEntriesCompanion companion,
    Map<String, dynamic> firestoreData,
  ) async {
    if (_auth.currentUser == null) return;
    try {
      await _db.into(_db.healthEntries).insertOnConflictUpdate(companion);
      unawaited(_syncHealthDataToFirestore(firestoreData));
    } catch (e, stack) {
      AppLogger.e('Erro ao atualizar métrica de saúde local', e, stack);
      rethrow;
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

  // ===========================================================================
  // 3. SINCRONIZAÇÃO EM BACKGROUND (FIREBASE PULL & PUSH)
  // ===========================================================================

  Future<void> syncHealthFromFirebase() async {
    final user = _auth.currentUser;
    if (user == null) return;

    try {
      AppLogger.i("SYNC Saúde: Iniciando...");

      final medsSnapshot = await _firestore
          .collection('users')
          .doc(user.uid)
          .collection('medications')
          .get();
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

          await _notifService.scheduleMedicationNotification(
            id: doc.id.hashCode.abs(),
            title: "Hora do medicamento 💊",
            body: "Está na hora de tomar: $name",
            scheduledDate: startDate,
            repeatDaily: true,
            preferenceKey: 'medication_reminders',
          );
        }
      }

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
      AppLogger.i("SYNC Saúde: Concluído.");
    } catch (e, stack) {
      AppLogger.e("SYNC Saúde: ERRO CRÍTICO", e, stack);
    }
  }

  // --- Métodos Privados Fire-and-Forget ---

  Future<void> _syncCycleSettingsInFirestore(
    Map<String, dynamic> cycleData,
  ) async {
    try {
      await _firestore.collection('users').doc(_auth.currentUser!.uid).set({
        'menstrualCycle': cycleData,
      }, SetOptions(merge: true));
    } catch (e, stack) {
      AppLogger.e('Sync Error: Ciclo Menstrual', e, stack);
    }
  }

  Future<void> _addMedicationInFirestore(
    String id,
    String name,
    DateTime startDate,
    int? durationDays,
    DateTime? endDate,
  ) async {
    try {
      await _firestore
          .collection('users')
          .doc(_auth.currentUser!.uid)
          .collection('medications')
          .doc(id)
          .set({
            'name': name,
            'startDate': Timestamp.fromDate(startDate),
            'durationDays': durationDays,
            'endDate': endDate != null ? Timestamp.fromDate(endDate) : null,
            'createdAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
    } catch (e, stack) {
      AppLogger.e('Sync Error: Add Medicamento', e, stack);
    }
  }

  Future<void> _deleteMedicationInFirestore(String docId) async {
    try {
      await _firestore
          .collection('users')
          .doc(_auth.currentUser!.uid)
          .collection('medications')
          .doc(docId)
          .delete();
    } catch (e, stack) {
      AppLogger.e('Sync Error: Deletar Medicamento', e, stack);
    }
  }

  Future<void> _syncHealthDataToFirestore(
    Map<String, dynamic> firestoreData,
  ) async {
    try {
      await _firestore
          .collection('users')
          .doc(_auth.currentUser!.uid)
          .collection('health_info')
          .doc(_getTodayDocId())
          .set(firestoreData, SetOptions(merge: true));
    } catch (e, stack) {
      AppLogger.e('Sync Error: Atualizar métrica diária', e, stack);
    }
  }
}
