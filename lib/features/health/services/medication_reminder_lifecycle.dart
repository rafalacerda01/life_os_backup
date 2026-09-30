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

bool isMedicationReminderEligible({
  required DateTime startDate,
  required DateTime now,
  DateTime? endDate,
  int? durationDays,
}) {
  final end =
      endDate ??
      (durationDays != null && durationDays > 0
          ? startDate.add(Duration(days: durationDays))
          : null);
  if (end == null) return true;
  final next = nextDailyMedicationOccurrence(startDate, now);
  return !DateTime(
    next.year,
    next.month,
    next.day,
  ).isAfter(DateTime(end.year, end.month, end.day));
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
  Future<void> cancelAllMedicationReminders({bool Function()? shouldContinue});

  Future<MedicationReminderRebuildResult> rebuildMedicationReminders({
    bool Function()? shouldContinue,
  });
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
  Future<void> _tail = Future<void>.value();

  Future<T> _serialize<T>(Future<T> Function() action) {
    final operation = _tail.then((_) => action());
    _tail = operation.then<void>((_) {}, onError: (_, _) {});
    return operation;
  }

  @override
  Future<void> cancelAllMedicationReminders({
    bool Function()? shouldContinue,
  }) => _serialize(() => _cancelAll(shouldContinue ?? () => true));

  Future<void> _cancelAll(bool Function() shouldContinue) async {
    if (!shouldContinue()) return;
    late final List<Medication> medications;

    try {
      medications = await _db.select(_db.medications).get();
    } catch (_) {
      AppLogger.w('Falha ao consultar lembretes locais de medicamentos.');
      return;
    }

    var failed = 0;

    for (final medication in medications) {
      if (!shouldContinue()) return;
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
  Future<MedicationReminderRebuildResult> rebuildMedicationReminders({
    bool Function()? shouldContinue,
  }) => _serialize(() => _rebuild(shouldContinue ?? () => true));

  Future<MedicationReminderRebuildResult> _rebuild(
    bool Function() shouldContinue,
  ) async {
    try {
      if (!shouldContinue()) {
        return const MedicationReminderRebuildResult(
          eligible: 0,
          scheduled: 0,
          failed: 0,
        );
      }
      final medications = await _db.select(_db.medications).get();
      var eligible = 0;
      var scheduled = 0;
      var failed = 0;

      for (final medication in medications) {
        if (!shouldContinue()) break;
        if (!isMedicationReminderEligible(
          startDate: medication.startDate,
          endDate: medication.endDate,
          durationDays: medication.durationDays,
          now: _now(),
        )) {
          try {
            await _notificationService.cancelNotification(
              notificationIdForMedication(medication.firestoreId),
            );
          } catch (_) {
            failed += 1;
          }
          continue;
        }

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

          // A native schedule may finish after session authority was revoked.
          if (!shouldContinue()) {
            await _notificationService.cancelNotification(
              notificationIdForMedication(medication.firestoreId),
            );
            break;
          }

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
}
