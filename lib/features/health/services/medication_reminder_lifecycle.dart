import 'dart:convert';

import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/services/notification_preferences.dart';
import 'package:life_os/core/services/notification_service.dart';
import 'package:life_os/core/utils/app_logger.dart';

int notificationIdForMedication(String medicationId) {
  const int offsetBasis = 2166136261;
  const int prime = 16777619;

  var hash = offsetBasis;

  for (final byte in utf8.encode(medicationId)) {
    hash ^= byte;
    hash = (hash * prime) & 0x7fffffff;
  }

  return hash == 0 ? 1 : hash;
}

class MedicationReminderRebuildResult {
  const MedicationReminderRebuildResult({
    required this.eligible,
    required this.scheduled,
    required this.failed,
  });

  final int eligible;
  final int scheduled;
  final int failed;
}

abstract interface class MedicationReminderLifecycle {
  Future<void> cancelAllMedicationReminders();

  Future<MedicationReminderRebuildResult> rebuildMedicationReminders();
}

class MedicationReminderLifecycleService
    implements MedicationReminderLifecycle {
  MedicationReminderLifecycleService(
    this._db,
    this._notificationService, {
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final AppDatabase _db;
  final NotificationService _notificationService;
  final DateTime Function() _now;

  @override
  Future<void> cancelAllMedicationReminders() async {
    late final List<Medication> medications;

    try {
      medications = await _db.select(_db.medications).get();
    } catch (_) {
      AppLogger.w('Falha ao consultar lembretes locais de medicamentos.');
      return;
    }

    var failed = 0;

    for (final medication in medications) {
      try {
        await _notificationService.cancelNotification(
          notificationIdForMedication(medication.firestoreId),
        );
      } catch (_) {
        failed += 1;
      }
    }

    if (failed > 0) {
      AppLogger.w('Falha ao cancelar lembretes locais de medicamentos.');
    }
  }

  @override
  Future<MedicationReminderRebuildResult> rebuildMedicationReminders() async {
    try {
      final medications = await _db.select(_db.medications).get();
      final now = _now();
      var eligible = 0;
      var scheduled = 0;
      var failed = 0;

      for (final medication in medications) {
        if (!_isEligible(medication, now)) continue;

        eligible += 1;

        try {
          final success = await _notificationService
              .scheduleMedicationNotification(
                id: notificationIdForMedication(medication.firestoreId),
                title: 'Hora do medicamento 💊',
                body: 'Está na hora de tomar: ${medication.name}',
                scheduledDate: medication.startDate,
                repeatDaily: true,
                preferenceKey: NotificationPreferenceKeys.medicationReminders,
              );

          if (success) {
            scheduled += 1;
          } else {
            failed += 1;
          }
        } catch (_) {
          failed += 1;
        }
      }

      if (failed > 0) {
        AppLogger.w(
          'Reconstrução de lembretes de medicamentos concluída com falhas.',
        );
      }

      return MedicationReminderRebuildResult(
        eligible: eligible,
        scheduled: scheduled,
        failed: failed,
      );
    } catch (_) {
      AppLogger.w('Falha ao reconstruir lembretes locais de medicamentos.');
      return const MedicationReminderRebuildResult(
        eligible: 0,
        scheduled: 0,
        failed: 1,
      );
    }
  }

  bool _isEligible(Medication medication, DateTime now) {
    final endDate = medication.endDate ?? _derivedEndDate(medication);
    if (endDate == null) return true;

    final nextOccurrence = nextDailyMedicationOccurrence(
      medication.startDate,
      now,
    );

    return !_startOfDay(nextOccurrence).isAfter(_startOfDay(endDate));
  }

  DateTime? _derivedEndDate(Medication medication) {
    final durationDays = medication.durationDays;
    if (durationDays == null || durationDays <= 0) return null;
    return medication.startDate.add(Duration(days: durationDays));
  }

  DateTime _startOfDay(DateTime value) =>
      DateTime(value.year, value.month, value.day);
}
