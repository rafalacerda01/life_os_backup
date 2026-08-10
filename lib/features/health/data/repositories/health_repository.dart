import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:drift/drift.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import 'package:drift/drift.dart' as drift;
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/security/input_sanitizer.dart';
import 'package:life_os/core/services/notification_service.dart';
import 'package:life_os/core/utils/app_logger.dart';
import 'package:life_os/features/health/data/models/health_model.dart';

class HealthRepository {
  final NotificationService _notifService;
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;
  final AppDatabase _db;

  final Uuid _uuid = const Uuid();

  HealthRepository(this._notifService, this._firestore, this._auth, this._db);

  // ===========================================================================
  // CONSTANTES
  // ===========================================================================

  static const int _defaultCycleLengthDays = 28;
  static const int _defaultPeriodLengthDays = 5;
  static const int _waterIncrementMl = 250;
  static const int _maxWaterIntakeMl = 1000000;

  static const String _defaultMood = '—';

  // ===========================================================================
  // HELPERS
  // ===========================================================================

  String _getTodayDocId() {
    return DateFormat('yyyy-MM-dd').format(DateTime.now());
  }

  String? _getUserId() {
    return _auth.currentUser?.uid;
  }

  /// Gera um ID determinístico e compatível com o limite de 32 bits
  /// normalmente utilizado pelos IDs de notificações Android.
  int _notificationIdForMedication(String medicationId) {
    const int offsetBasis = 2166136261;
    const int prime = 16777619;

    var hash = offsetBasis;

    for (final byte in utf8.encode(medicationId)) {
      hash ^= byte;
      hash = (hash * prime) & 0x7fffffff;
    }

    return hash == 0 ? 1 : hash;
  }

  Map<String, dynamic>? _decodeCycleData(String? json) {
    if (json == null || json.trim().isEmpty) {
      return null;
    }

    try {
      final decoded = jsonDecode(json);

      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (e, stack) {
      AppLogger.e('Erro ao decodificar dados do ciclo menstrual.', e, stack);
    }

    return null;
  }

  String _encodeCycleData(Map<String, dynamic> cycleData) {
    return jsonEncode(cycleData);
  }

  Map<String, dynamic> _sanitizeCycleData(Map<String, dynamic> cycleData) {
    final now = DateTime.now();

    final rawLastPeriodStart = cycleData['lastPeriodStart'];

    String lastPeriodStart;

    if (rawLastPeriodStart is DateTime) {
      lastPeriodStart = rawLastPeriodStart.toIso8601String();
    } else if (rawLastPeriodStart is String &&
        rawLastPeriodStart.trim().isNotEmpty) {
      final parsed = DateTime.tryParse(rawLastPeriodStart.trim());

      lastPeriodStart = parsed?.toIso8601String() ?? now.toIso8601String();
    } else {
      lastPeriodStart = now.toIso8601String();
    }

    final cycleLength = _normalizePositiveInt(
      cycleData['cycleLengthDays'],
      fallback: _defaultCycleLengthDays,
      min: 1,
      max: 120,
    );

    final periodLength = _normalizePositiveInt(
      cycleData['periodLengthDays'],
      fallback: _defaultPeriodLengthDays,
      min: 1,
      max: cycleLength,
    );

    return <String, dynamic>{
      'isEnabled': cycleData['isEnabled'] == true,
      'lastPeriodStart': lastPeriodStart,
      'cycleLengthDays': cycleLength,
      'periodLengthDays': periodLength,
    };
  }

  int _normalizePositiveInt(
    dynamic value, {
    required int fallback,
    required int min,
    required int max,
  }) {
    final parsed = value is num
        ? value.toInt()
        : int.tryParse(value?.toString() ?? '');

    if (parsed == null) {
      return fallback.clamp(min, max);
    }

    return parsed.clamp(min, max);
  }

  DateTime? _timestampToDate(dynamic value) {
    if (value is Timestamp) {
      return value.toDate();
    }

    if (value is DateTime) {
      return value;
    }

    if (value is String) {
      return DateTime.tryParse(value);
    }

    return null;
  }

  String _sanitizeMood(String value) {
    final cleanMood = InputSanitizer.sanitize(value.trim());

    if (cleanMood.isEmpty) {
      return _defaultMood;
    }

    return cleanMood;
  }

  // ===========================================================================
  // 1. LEITURA — DRIFT / LOCAL FIRST
  // ===========================================================================

  Stream<HealthModel> getHealthStream() {
    final todayDocId = _getTodayDocId();

    return (_db.select(_db.healthEntries)
          ..where((table) => table.docId.equals(todayDocId)))
        .watchSingleOrNull()
        .map((entry) {
          if (entry == null) {
            return HealthModel.initial();
          }

          final decodedCycle = _decodeCycleData(entry.menstrualCycleJson);

          return HealthModel(
            mood: entry.mood,
            waterIntakeMl: entry.waterIntakeMl.clamp(0, _maxWaterIntakeMl),
            hasTakenPillToday: entry.hasTakenPillToday,
            menstrualCycle: decodedCycle,
            date: entry.date,
          );
        });
  }

  // ===========================================================================
  // 2. ESCRITA — OFFLINE FIRST
  // ===========================================================================

  Future updateCycleSettings(Map<String, dynamic> cycleData) async {
    final userId = _getUserId();

    if (userId == null) {
      AppLogger.w('Tentativa de atualizar ciclo sem usuário autenticado.');
      return;
    }

    try {
      final todayDocId = _getTodayDocId();
      final now = DateTime.now();

      final sanitizedCycleData = _sanitizeCycleData(cycleData);

      await _upsertHealthEntry(
        docId: todayDocId,
        menstrualCycleJson: _encodeCycleData(sanitizedCycleData),
        date: now,
      );

      unawaited(
        _syncHealthDataToFirestore(
          userId: userId,
          firestoreData: <String, dynamic>{
            'menstrualCycle': sanitizedCycleData,
            'date': Timestamp.fromDate(now),
          },
        ),
      );
    } catch (e, stack) {
      AppLogger.e('Erro ao atualizar ciclo menstrual.', e, stack);
      rethrow;
    }
  }

  Future<void> addMedication(
    String name,
    DateTime startDate,
    int? durationDays,
  ) async {
    final userId = _getUserId();

    if (userId == null) {
      AppLogger.w(
        'Tentativa de adicionar medicamento sem usuário autenticado.',
      );
      return;
    }

    final cleanName = InputSanitizer.sanitize(name.trim());

    if (cleanName.isEmpty) {
      throw ArgumentError('O nome do medicamento não pode estar vazio.');
    }

    if (cleanName.length > 200) {
      throw ArgumentError('O nome do medicamento é muito longo.');
    }

    if (durationDays != null && durationDays <= 0) {
      throw ArgumentError('A duração do medicamento deve ser maior que zero.');
    }

    if (durationDays != null && durationDays > 3650) {
      throw ArgumentError(
        'A duração do medicamento não pode exceder 3650 dias.',
      );
    }

    try {
      final DateTime? endDate = durationDays != null && durationDays > 0
          ? startDate.add(Duration(days: durationDays))
          : null;

      final firestoreId = _uuid.v4();

      // =======================================================================
      // 1. SALVA PRIMEIRO NO DRIFT
      // =======================================================================

      await _db
          .into(_db.medications)
          .insert(
            MedicationsCompanion.insert(
              firestoreId: firestoreId,
              name: cleanName,
              startDate: startDate,
              durationDays: Value(durationDays),
              endDate: Value(endDate),
            ),
          );

      AppLogger.i('Medicamento $firestoreId salvo localmente com sucesso.');

      // =======================================================================
      // 2. FIREBASE
      // =======================================================================

      unawaited(
        _addMedicationInFirestore(
          userId: userId,
          id: firestoreId,
          name: cleanName,
          startDate: startDate,
          durationDays: durationDays,
          endDate: endDate,
        ),
      );

      // =======================================================================
      // 3. NOTIFICAÇÃO
      // =======================================================================
      //
      // A notificação NÃO faz mais parte do fluxo crítico do cadastro.
      // Se permissão/plugin/agendamento falhar, o medicamento permanece salvo.
      //

      try {
        final permissionGranted = await _notifService.requestPermissions();

        if (!permissionGranted) {
          AppLogger.w(
            'Permissão de notificações não concedida. '
            'Medicamento permanece salvo sem lembrete.',
          );
          return;
        }

        await _notifService.scheduleMedicationNotification(
          id: _notificationIdForMedication(firestoreId),
          title: 'Hora do medicamento 💊',
          body: 'Está na hora de tomar: $cleanName',
          scheduledDate: startDate,
          repeatDaily: true,
          preferenceKey: 'medication_reminders',
        );

        AppLogger.i('Notificação agendada para o medicamento $firestoreId.');
      } catch (e, stack) {
        AppLogger.e(
          'Medicamento salvo, mas não foi possível '
          'configurar a notificação.',
          e,
          stack,
        );
      }
    } catch (e, stack) {
      AppLogger.e('Erro ao adicionar medicamento.', e, stack);
      rethrow;
    }
  }

  Future deleteMedication(String docId, int localId) async {
    final userId = _getUserId();

    if (userId == null) {
      AppLogger.w('Tentativa de excluir medicamento sem usuário autenticado.');
      return;
    }

    try {
      await (_db.delete(
        _db.medications,
      )..where((table) => table.id.equals(localId))).go();

      await (_db.delete(
        _db.notificationsTable,
      )..where((table) => table.id.equals('health_med_$docId'))).go();

      try {
        await _notifService.cancelNotification(
          _notificationIdForMedication(docId),
        );

        AppLogger.i('Notificação cancelada para o medicamento $docId.');
      } catch (e, stack) {
        AppLogger.e(
          'Medicamento removido, mas não foi possível '
          'cancelar a notificação.',
          e,
          stack,
        );
      }

      final cleanDocId = docId.trim();

      if (cleanDocId.isNotEmpty && cleanDocId != 'pending') {
        unawaited(
          _deleteMedicationInFirestore(userId: userId, docId: cleanDocId),
        );
      }
    } catch (e, stack) {
      AppLogger.e('Erro ao excluir medicamento.', e, stack);
      rethrow;
    }
  }

  // ===========================================================================
  // 3. ATUALIZAÇÃO DE SAÚDE DIÁRIA
  // ===========================================================================

  Future _performDualWrite(
    HealthEntriesCompanion companion,
    Map<String, dynamic> firestoreData,
  ) async {
    final userId = _getUserId();

    if (userId == null) {
      AppLogger.w('Tentativa de atualizar saúde sem usuário autenticado.');
      return;
    }

    try {
      await _upsertHealthEntry(
        docId: _getTodayDocId(),
        mood: companion.mood.present ? companion.mood.value : null,
        waterIntakeMl: companion.waterIntakeMl.present
            ? companion.waterIntakeMl.value
            : null,
        hasTakenPillToday: companion.hasTakenPillToday.present
            ? companion.hasTakenPillToday.value
            : null,
        menstrualCycleJson: companion.menstrualCycleJson.present
            ? companion.menstrualCycleJson.value
            : null,
        date: companion.date.present ? companion.date.value : DateTime.now(),
      );

      unawaited(
        _syncHealthDataToFirestore(
          userId: userId,
          firestoreData: firestoreData,
        ),
      );
    } catch (e, stack) {
      AppLogger.e('Erro ao atualizar métrica de saúde local.', e, stack);
      rethrow;
    }
  }

  Future _upsertHealthEntry({
    required String docId,
    String? mood,
    int? waterIntakeMl,
    bool? hasTakenPillToday,
    String? menstrualCycleJson,
    DateTime? date,
  }) async {
    final existing = await (_db.select(
      _db.healthEntries,
    )..where((table) => table.docId.equals(docId))).getSingleOrNull();

    final now = date ?? DateTime.now();

    if (existing == null) {
      await _db
          .into(_db.healthEntries)
          .insert(
            HealthEntriesCompanion.insert(
              docId: docId,
              mood: Value(mood ?? _defaultMood),
              waterIntakeMl: Value(
                (waterIntakeMl ?? 0).clamp(0, _maxWaterIntakeMl),
              ),
              hasTakenPillToday: Value(hasTakenPillToday ?? false),
              menstrualCycleJson: Value(menstrualCycleJson),
              date: now,
            ),
          );
    }

    final updates = HealthEntriesCompanion(
      mood: mood == null ? const Value.absent() : Value(mood),
      waterIntakeMl: waterIntakeMl == null
          ? const Value.absent()
          : Value(waterIntakeMl.clamp(0, _maxWaterIntakeMl)),
      hasTakenPillToday: hasTakenPillToday == null
          ? const Value.absent()
          : Value(hasTakenPillToday),
      menstrualCycleJson: menstrualCycleJson == null
          ? const Value.absent()
          : Value(menstrualCycleJson),
      date: Value(now),
    );

    await (_db.update(
      _db.healthEntries,
    )..where((table) => table.docId.equals(docId))).write(updates);
  }

  Future updateMood(String newMood) async {
    final cleanMood = _sanitizeMood(newMood);

    if (cleanMood == _defaultMood && newMood.trim().isEmpty) {
      throw ArgumentError('O humor não pode estar vazio.');
    }

    final now = DateTime.now();

    // 🛡️ CORREÇÃO APLICADA AQUI (Envolvendo com Value(...))
    await _performDualWrite(
      HealthEntriesCompanion(
        docId: Value(_getTodayDocId()),
        mood: Value(cleanMood),
        date: Value(now),
      ),
      <String, dynamic>{'mood': cleanMood, 'date': Timestamp.fromDate(now)},
    );
  }

  Future addWater(int currentWater) async {
    final safeCurrentWater = currentWater.clamp(0, _maxWaterIntakeMl);

    final newWaterAmount = (safeCurrentWater + _waterIncrementMl).clamp(
      0,
      _maxWaterIntakeMl,
    );

    final now = DateTime.now();

    // 🛡️ CORREÇÃO APLICADA AQUI (Envolvendo com Value(...))
    await _performDualWrite(
      HealthEntriesCompanion(
        docId: Value(_getTodayDocId()),
        waterIntakeMl: Value(newWaterAmount),
        date: Value(now),
      ),
      <String, dynamic>{
        'waterIntakeMl': newWaterAmount,
        'date': Timestamp.fromDate(now),
      },
    );
  }

  Future updatePillStatus(bool taken) async {
    final now = DateTime.now();

    // 🛡️ CORREÇÃO APLICADA AQUI (Envolvendo com Value(...))
    await _performDualWrite(
      HealthEntriesCompanion(
        docId: Value(_getTodayDocId()),
        hasTakenPillToday: Value(taken),
        date: Value(now),
      ),
      <String, dynamic>{
        'hasTakenPillToday': taken,
        'date': Timestamp.fromDate(now),
      },
    );
  }

  Future toggleMenstrualCycleFeature(bool enable) async {
    final userId = _getUserId();

    if (userId == null) {
      AppLogger.w('Tentativa de alterar ciclo sem usuário autenticado.');
      return;
    }

    final todayDocId = _getTodayDocId();

    final existing = await (_db.select(
      _db.healthEntries,
    )..where((table) => table.docId.equals(todayDocId))).getSingleOrNull();

    Map<String, dynamic> cycleData = <String, dynamic>{};

    if (existing?.menstrualCycleJson != null) {
      cycleData =
          _decodeCycleData(existing!.menstrualCycleJson) ?? <String, dynamic>{};
    }

    cycleData['isEnabled'] = enable;

    cycleData.putIfAbsent(
      'lastPeriodStart',
      () => DateTime.now().toIso8601String(),
    );

    cycleData.putIfAbsent('cycleLengthDays', () => _defaultCycleLengthDays);

    cycleData.putIfAbsent('periodLengthDays', () => _defaultPeriodLengthDays);

    await updateCycleSettings(cycleData);
  }

  // ===========================================================================
  // 4. FIREBASE → DRIFT
  // ===========================================================================

  Future syncHealthFromFirebase() async {
    final userId = _getUserId();

    if (userId == null) {
      AppLogger.w('SYNC Saúde ignorado: usuário não autenticado.');
      return;
    }

    try {
      AppLogger.i('SYNC Saúde: Iniciando...');

      final medsSnapshot = await _firestore
          .collection('users')
          .doc(userId)
          .collection('medications')
          .get();

      for (final doc in medsSnapshot.docs) {
        try {
          await _syncMedicationDocument(doc: doc);
        } catch (e, stack) {
          AppLogger.e('Erro ao sincronizar medicamento ${doc.id}.', e, stack);
        }
      }

      final healthSnapshot = await _firestore
          .collection('users')
          .doc(userId)
          .collection('health_info')
          .get();

      for (final doc in healthSnapshot.docs) {
        try {
          await _syncHealthDocument(doc: doc);
        } catch (e, stack) {
          AppLogger.e(
            'Erro ao sincronizar registro '
            'de saúde ${doc.id}.',
            e,
            stack,
          );
        }
      }

      AppLogger.i('SYNC Saúde: Concluído.');
    } catch (e, stack) {
      AppLogger.e('SYNC Saúde: ERRO CRÍTICO.', e, stack);
    }
  }

  Future _syncMedicationDocument({
    required QueryDocumentSnapshot<Map<String, dynamic>> doc,
  }) async {
    final data = doc.data();

    final name = InputSanitizer.sanitize(data['name']?.toString() ?? '').trim();

    if (name.isEmpty) {
      AppLogger.w(
        'Medicamento ${doc.id} ignorado: '
        'nome inválido.',
      );
      return;
    }

    final startDate = _timestampToDate(data['startDate']);

    if (startDate == null) {
      AppLogger.w(
        'Medicamento ${doc.id} ignorado: '
        'data de início inválida.',
      );
      return;
    }

    int? durationDays;

    if (data['durationDays'] != null) {
      final parsed = data['durationDays'] is num
          ? (data['durationDays'] as num).toInt()
          : int.tryParse(data['durationDays'].toString());

      if (parsed != null && parsed > 0 && parsed <= 3650) {
        durationDays = parsed;
      }
    }

    final endDate = _timestampToDate(data['endDate']);

    final existing = await (_db.select(
      _db.medications,
    )..where((table) => table.firestoreId.equals(doc.id))).getSingleOrNull();

    if (existing != null) {
      return;
    }

    await _db
        .into(_db.medications)
        .insert(
          MedicationsCompanion.insert(
            firestoreId: doc.id,
            name: name,
            startDate: startDate,
            durationDays: Value(durationDays),
            endDate: Value(endDate),
          ),
        );

    try {
      await _notifService.scheduleMedicationNotification(
        id: _notificationIdForMedication(doc.id),
        title: 'Hora do medicamento 💊',
        body: 'Está na hora de tomar: $name',
        scheduledDate: startDate,
        repeatDaily: true,
        preferenceKey: 'medication_reminders',
      );
    } catch (e, stack) {
      AppLogger.e(
        'Medicamento sincronizado, mas não foi possível '
        'agendar sua notificação.',
        e,
        stack,
      );
    }
  }

  Future _syncHealthDocument({
    required QueryDocumentSnapshot<Map<String, dynamic>> doc,
  }) async {
    final data = doc.data();

    final cycleData = data['menstrualCycle'];

    final Map<String, dynamic>? safeCycleData = cycleData is Map
        ? Map<String, dynamic>.from(cycleData)
        : null;

    final date = _timestampToDate(data['date']) ?? DateTime.now();

    final rawWater = data['waterIntakeMl'];

    final waterIntake = rawWater is num
        ? rawWater.toInt()
        : int.tryParse(rawWater?.toString() ?? '') ?? 0;

    final cleanMood = _sanitizeMood(data['mood']?.toString() ?? _defaultMood);

    await _upsertHealthEntry(
      docId: doc.id,
      mood: cleanMood,
      waterIntakeMl: waterIntake.clamp(0, _maxWaterIntakeMl),
      hasTakenPillToday: data['hasTakenPillToday'] == true,
      menstrualCycleJson: safeCycleData == null
          ? null
          : _encodeCycleData(_sanitizeCycleData(safeCycleData)),
      date: date,
    );
  }

  // ===========================================================================
  // 5. FIREBASE — MEDICAMENTOS
  // ===========================================================================

  Future _addMedicationInFirestore({
    required String userId,
    required String id,
    required String name,
    required DateTime startDate,
    required int? durationDays,
    required DateTime? endDate,
  }) async {
    try {
      await _firestore
          .collection('users')
          .doc(userId)
          .collection('medications')
          .doc(id)
          .set(<String, dynamic>{
            'name': name,
            'startDate': Timestamp.fromDate(startDate),
            'durationDays': durationDays,
            'endDate': endDate == null ? null : Timestamp.fromDate(endDate),
            'createdAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));

      AppLogger.i('Medicamento $id sincronizado com Firebase.');
    } catch (e, stack) {
      AppLogger.e('Sync Error: Adicionar medicamento.', e, stack);
    }
  }

  Future _deleteMedicationInFirestore({
    required String userId,
    required String docId,
  }) async {
    try {
      final batch = _firestore.batch();

      // 1. Deleta o medicamento da coleção medications
      batch.delete(
        _firestore
            .collection('users')
            .doc(userId)
            .collection('medications')
            .doc(docId),
      );

      // 2. 🛡️ CORREÇÃO: Deleta a notificação atrelada da coleção notifications na nuvem
      batch.delete(
        _firestore
            .collection('users')
            .doc(userId)
            .collection('notifications')
            .doc('health_med_$docId'),
      );

      await batch.commit();

      AppLogger.i(
        'Medicamento $docId e sua notificação removidos do Firebase.',
      );
    } catch (e, stack) {
      AppLogger.e('Sync Error: Deletar medicamento.', e, stack);
    }
  }

  // ===========================================================================
  // 6. FIREBASE — SAÚDE DIÁRIA
  // ===========================================================================

  Future _syncHealthDataToFirestore({
    required String userId,
    required Map<String, dynamic> firestoreData,
  }) async {
    try {
      await _firestore
          .collection('users')
          .doc(userId)
          .collection('health_info')
          .doc(_getTodayDocId())
          .set(firestoreData, SetOptions(merge: true));

      AppLogger.i('Dados de saúde sincronizados com Firebase.');
    } catch (e, stack) {
      AppLogger.e('Sync Error: Atualizar métrica diária.', e, stack);
    }
  }
}
