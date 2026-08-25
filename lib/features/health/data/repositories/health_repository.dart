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
import 'package:life_os/core/services/notification_preferences.dart';
import 'package:life_os/core/services/notification_service.dart';
import 'package:life_os/core/services/sync_manager.dart';
import 'package:life_os/core/utils/app_logger.dart';
import 'package:life_os/features/health/data/models/health_model.dart';
import 'package:life_os/features/health/services/medication_reminder_lifecycle.dart';

class HealthRepository {
  final NotificationService _notifService;
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;
  final AppDatabase _db;
  final SyncManager _syncManager;
  final DateTime Function() _now;

  final Uuid _uuid = const Uuid();

  HealthRepository(
    this._notifService,
    this._firestore,
    this._auth,
    this._db,
    this._syncManager, {
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

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
    return DateFormat('yyyy-MM-dd').format(_now());
  }

  String? _getUserId() {
    return _auth.currentUser?.uid;
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
    final now = _now();

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

  Map<String, dynamic>? _validCycleData(String? json) {
    final cycleData = _decodeCycleData(json);

    if (cycleData == null ||
        cycleData['isEnabled'] is! bool ||
        DateTime.tryParse(cycleData['lastPeriodStart']?.toString() ?? '') ==
            null) {
      return null;
    }

    final cycleLength = int.tryParse(
      cycleData['cycleLengthDays']?.toString() ?? '',
    );
    final periodLength = int.tryParse(
      cycleData['periodLengthDays']?.toString() ?? '',
    );

    if (cycleLength == null ||
        cycleLength < 1 ||
        cycleLength > 120 ||
        periodLength == null ||
        periodLength < 1 ||
        periodLength > cycleLength) {
      return null;
    }

    return _sanitizeCycleData(cycleData);
  }

  Map<String, dynamic>? _latestCycleData(List<HealthEntry> entries) {
    Map<String, dynamic>? latestCycle;
    DateTime? latestDate;

    for (final entry in entries) {
      final cycle = _validCycleData(entry.menstrualCycleJson);

      if (cycle != null &&
          (latestDate == null || entry.date.isAfter(latestDate))) {
        latestCycle = cycle;
        latestDate = entry.date;
      }
    }

    return latestCycle;
  }

  // ===========================================================================
  // 1. LEITURA — DRIFT / LOCAL FIRST
  // ===========================================================================

  Stream<HealthModel> getHealthStream() {
    final todayDocId = _getTodayDocId();

    return _db.select(_db.healthEntries).watch().map((entries) {
      HealthEntry? todayEntry;

      for (final entry in entries) {
        if (entry.docId == todayDocId) {
          todayEntry = entry;
          break;
        }
      }

      final todayCycle = _validCycleData(todayEntry?.menstrualCycleJson);
      final menstrualCycle = todayCycle ?? _latestCycleData(entries);

      if (todayEntry == null) {
        return HealthModel(
          mood: _defaultMood,
          waterIntakeMl: 0,
          hasTakenPillToday: false,
          menstrualCycle: menstrualCycle,
          date: _now(),
        );
      }

      return HealthModel(
        mood: todayEntry.mood,
        waterIntakeMl: todayEntry.waterIntakeMl.clamp(0, _maxWaterIntakeMl),
        hasTakenPillToday: todayEntry.hasTakenPillToday,
        menstrualCycle: menstrualCycle,
        date: todayEntry.date,
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
      final now = _now();

      final sanitizedCycleData = _sanitizeCycleData(cycleData);

      await _performDualWrite(
        HealthEntriesCompanion(
          docId: Value(todayDocId),
          menstrualCycleJson: Value(_encodeCycleData(sanitizedCycleData)),
          date: Value(now),
        ),
        <String, dynamic>{
          'menstrualCycle': sanitizedCycleData,
          'date': now.toIso8601String(),
        },
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
      final DateTime? endDate = durationDays != null
          ? startDate.add(Duration(days: durationDays))
          : null;

      final firestoreId = _uuid.v4();

      // =====================================================================
      // 1. DRIFT + SYNC QUEUE
      // =====================================================================

      await _db.transactionWithSync(
        ownerUid: userId,
        localOperation: () async {
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
        },
        collection: 'medications',
        docId: firestoreId,
        operationType: 'create',
        payloadJson: jsonEncode({
          'name': cleanName,
          'startDate': startDate.toIso8601String(),
          'durationDays': durationDays,
          'endDate': endDate?.toIso8601String(),
        }),
      );

      AppLogger.i('Medicamento salvo localmente com sucesso.');

      // =====================================================================
      // 2. NOTIFICAÇÃO LOCAL
      // =====================================================================
      //
      // Continua fora da transação crítica.
      // Uma falha na notificação não desfaz o medicamento.
      //

      try {
        final permissionGranted = await _notifService.requestPermissions(
          preferenceKey: NotificationPreferenceKeys.medicationReminders,
        );

        if (!permissionGranted) {
          AppLogger.w(
            'Permissão de notificações não concedida. '
            'Medicamento permanece salvo sem lembrete.',
          );
          return;
        }

        await _notifService.requestExactAlarmPermission();

        final scheduled = await _notifService.scheduleMedicationNotification(
          id: notificationIdForMedication(firestoreId),
          title: 'Hora do medicamento 💊',
          body: 'Está na hora de tomar: $cleanName',
          scheduledDate: startDate,
          repeatDaily: true,
          preferenceKey: NotificationPreferenceKeys.medicationReminders,
        );

        if (scheduled) {
          AppLogger.i('Lembrete de medicamento agendado com sucesso.');
        } else {
          AppLogger.w('Medicamento salvo sem lembrete local agendado.');
        }
      } catch (_) {
        AppLogger.w('Medicamento salvo sem lembrete local agendado.');
      }
    } catch (e, stack) {
      AppLogger.e('Erro ao adicionar medicamento.', e, stack);
      rethrow;
    }
  }

  Future<void> deleteMedication(String docId, int localId) async {
    final userId = _getUserId();

    if (userId == null) {
      AppLogger.w('Tentativa de excluir medicamento sem usuário autenticado.');
      return;
    }

    final cleanDocId = docId.trim();

    Future<void> deleteLocalMedication() async {
      await (_db.delete(
        _db.medications,
      )..where((table) => table.id.equals(localId))).go();

      await (_db.delete(
        _db.notificationsTable,
      )..where((table) => table.id.equals('health_med_$cleanDocId'))).go();
    }

    try {
      // Registros realmente sincronizáveis entram
      // atomicamente na SyncQueue.
      if (cleanDocId.isNotEmpty && cleanDocId != 'pending') {
        await _db.transactionWithSync(
          ownerUid: userId,
          localOperation: deleteLocalMedication,
          collection: 'medications',
          docId: cleanDocId,
          operationType: 'delete',
          payloadJson: jsonEncode({'medicationId': cleanDocId}),
        );
      } else {
        // Preserva o comportamento para registros
        // puramente locais / pendentes.
        await _db.transaction(deleteLocalMedication);
      }

      try {
        if (cleanDocId.isNotEmpty) {
          await _notifService.cancelNotification(
            notificationIdForMedication(cleanDocId),
          );

          AppLogger.i('Notificação de medicamento cancelada.');
        }
      } catch (e, stack) {
        AppLogger.e(
          'Medicamento removido, mas não foi possível '
          'cancelar a notificação.',
          e,
          stack,
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
      final todayDocId = _getTodayDocId();
      final now = companion.date.present ? companion.date.value : _now();

      await _db.transactionWithSync(
        ownerUid: userId,
        localOperation: () async {
          await _upsertHealthEntry(
            docId: todayDocId,
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
            date: now,
          );
        },
        collection: 'health_info',
        docId: todayDocId,
        operationType: 'update',
        payloadJson: jsonEncode(firestoreData),
      );

      unawaited(
        _syncManager.processPendingItems().catchError((error, stackTrace) {
          AppLogger.e(
            'Erro ao processar fila de sincronização da saúde.',
            error,
            stackTrace,
          );
          return false;
        }),
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

    final insertDate = date ?? DateTime.tryParse(docId) ?? _now();

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
              date: insertDate,
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
      date: date == null ? const Value.absent() : Value(date),
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

    final now = _now();

    // 🛡️ CORREÇÃO APLICADA AQUI (Envolvendo com Value(...))
    await _performDualWrite(
      HealthEntriesCompanion(
        docId: Value(_getTodayDocId()),
        mood: Value(cleanMood),
        date: Value(now),
      ),
      <String, dynamic>{'mood': cleanMood, 'date': now.toIso8601String()},
    );
  }

  Future addWater(int currentWater) async {
    final safeCurrentWater = currentWater.clamp(0, _maxWaterIntakeMl);

    final newWaterAmount = (safeCurrentWater + _waterIncrementMl).clamp(
      0,
      _maxWaterIntakeMl,
    );

    final now = _now();

    // 🛡️ CORREÇÃO APLICADA AQUI (Envolvendo com Value(...))
    await _performDualWrite(
      HealthEntriesCompanion(
        docId: Value(_getTodayDocId()),
        waterIntakeMl: Value(newWaterAmount),
        date: Value(now),
      ),
      <String, dynamic>{
        'waterIntakeMl': newWaterAmount,
        'date': now.toIso8601String(),
      },
    );
  }

  Future updatePillStatus(bool taken) async {
    final now = _now();

    // 🛡️ CORREÇÃO APLICADA AQUI (Envolvendo com Value(...))
    await _performDualWrite(
      HealthEntriesCompanion(
        docId: Value(_getTodayDocId()),
        hasTakenPillToday: Value(taken),
        date: Value(now),
      ),
      <String, dynamic>{
        'hasTakenPillToday': taken,
        'date': now.toIso8601String(),
      },
    );
  }

  Future toggleMenstrualCycleFeature(bool enable) async {
    final userId = _getUserId();

    if (userId == null) {
      AppLogger.w('Tentativa de alterar ciclo sem usuário autenticado.');
      return;
    }

    final entries = await _db.select(_db.healthEntries).get();
    final cycleData = _latestCycleData(entries) ?? <String, dynamic>{};

    cycleData['isEnabled'] = enable;

    cycleData.putIfAbsent('lastPeriodStart', () => _now().toIso8601String());

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
          AppLogger.e('Erro ao sincronizar medicamento.', e, stack);
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
            'de saúde.',
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
      final scheduled = await _notifService.scheduleMedicationNotification(
        id: notificationIdForMedication(doc.id),
        title: 'Hora do medicamento 💊',
        body: 'Está na hora de tomar: $name',
        scheduledDate: startDate,
        repeatDaily: true,
        preferenceKey: NotificationPreferenceKeys.medicationReminders,
      );

      if (!scheduled) {
        AppLogger.w('Medicamento sincronizado sem lembrete local agendado.');
      }
    } catch (_) {
      AppLogger.w('Medicamento sincronizado sem lembrete local agendado.');
    }
  }

  Future _syncHealthDocument({
    required QueryDocumentSnapshot<Map<String, dynamic>> doc,
  }) async {
    final data = doc.data();

    final hasCycleData = data.containsKey('menstrualCycle');
    final cycleData = data['menstrualCycle'];

    final Map<String, dynamic>? safeCycleData = hasCycleData && cycleData is Map
        ? Map<String, dynamic>.from(cycleData)
        : null;

    final date = data.containsKey('date')
        ? _timestampToDate(data['date']) ?? DateTime.tryParse(doc.id)
        : null;

    final rawWater = data['waterIntakeMl'];

    final waterIntake = data.containsKey('waterIntakeMl')
        ? rawWater is num
              ? rawWater.toInt()
              : int.tryParse(rawWater?.toString() ?? '')
        : null;

    final cleanMood = data.containsKey('mood')
        ? _sanitizeMood(data['mood']?.toString() ?? '')
        : null;

    final rawPillStatus = data['hasTakenPillToday'];
    final pillStatus =
        data.containsKey('hasTakenPillToday') && rawPillStatus is bool
        ? rawPillStatus
        : null;

    await _upsertHealthEntry(
      docId: doc.id,
      mood: cleanMood,
      waterIntakeMl: waterIntake?.clamp(0, _maxWaterIntakeMl),
      hasTakenPillToday: pillStatus,
      menstrualCycleJson: safeCycleData == null
          ? null
          : _encodeCycleData(_sanitizeCycleData(safeCycleData)),
      date: date,
    );
  }
}
