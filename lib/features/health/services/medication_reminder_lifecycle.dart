import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
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

// iOS: 64 slots minus 8 Cycle slots and 8 operational slots, globally.
const medicationNativePendingBudget = 48;
const medicationReminderPayloadPrefix = 'life_os_medication_v2:';

int notificationIdForMedicationOccurrence(String medicationId, DateTime date) =>
    notificationIdForMedication(
      '${medicationReminderPayloadPrefix}one_shot:$medicationId:'
      '${date.year}-${date.month}-${date.day}',
    );

DateTime? _effectiveEnd(Medication medication) =>
    medication.endDate ??
    (medication.durationDays != null && medication.durationDays! > 0
        ? medication.startDate.add(Duration(days: medication.durationDays!))
        : null);

bool _isAfterEnd(DateTime date, DateTime end) => DateTime(
  date.year,
  date.month,
  date.day,
).isAfter(DateTime(end.year, end.month, end.day));

bool _isMedicationRequest(PendingNotificationRequest request) =>
    request.payload?.startsWith(medicationReminderPayloadPrefix) == true ||
    (request.payload == null &&
        request.title == 'Hora do medicamento 💊' &&
        request.body?.startsWith('Está na hora de tomar:') == true);

class _MedicationRequest {
  const _MedicationRequest(this.medication, this.date, this.repeatDaily);

  final Medication medication;
  final DateTime date;
  final bool repeatDaily;

  _MedicationRequest get next => _MedicationRequest(
    medication,
    DateTime(
      date.year,
      date.month,
      date.day + 1,
      medication.startDate.hour,
      medication.startDate.minute,
      medication.startDate.second,
      medication.startDate.millisecond,
      medication.startDate.microsecond,
    ),
    false,
  );
}

int _compareRequests(_MedicationRequest a, _MedicationRequest b) {
  final byDate = a.date.compareTo(b.date);
  return byDate != 0
      ? byDate
      : a.medication.firestoreId.compareTo(b.medication.firestoreId);
}

List<_MedicationRequest> _planMedicationRequests(
  List<Medication> medications,
  DateTime now,
  int budget,
) {
  final open = <_MedicationRequest>[];
  final finite = <_MedicationRequest>[];
  for (final medication in medications) {
    final next = nextDailyMedicationOccurrence(medication.startDate, now);
    final end = _effectiveEnd(medication);
    if (end == null) {
      open.add(_MedicationRequest(medication, medication.startDate, true));
    } else if (!_isAfterEnd(next, end)) {
      finite.add(_MedicationRequest(medication, next, false));
    }
  }
  open.sort(
    (a, b) => a.medication.firestoreId.compareTo(b.medication.firestoreId),
  );
  finite.sort(_compareRequests);
  final plan = <_MedicationRequest>[];
  final nextOccurrences = <_MedicationRequest>[];
  for (final request in [...open, ...finite]) {
    if (plan.length >= budget) break;
    plan.add(request);
    if (!request.repeatDaily) nextOccurrences.add(request.next);
  }
  while (plan.length < budget && nextOccurrences.isNotEmpty) {
    nextOccurrences.removeWhere(
      (request) =>
          _isAfterEnd(request.date, _effectiveEnd(request.medication)!),
    );
    if (nextOccurrences.isEmpty) break;
    nextOccurrences.sort(_compareRequests);
    final request = nextOccurrences.removeAt(0);
    plan.add(request);
    nextOccurrences.add(request.next);
  }
  return plan;
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
    Future<NotificationPreferences> Function()? loadPreferences,
  }) : _now = now ?? DateTime.now,
       _loadPreferences =
           loadPreferences ?? const NotificationPreferencesStore().load;

  final AppDatabase _db;
  final NotificationService _notificationService;
  final DateTime Function() _now;
  final Future<NotificationPreferences> Function() _loadPreferences;
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
    try {
      final medications = await _db.select(_db.medications).get();
      if (!shouldContinue()) return;
      final pending = await _notificationService.pendingNotificationRequests();
      final failed = await _cancelIds(_cleanupIds(medications, pending));
      if (failed.isNotEmpty) {
        AppLogger.w('Falha ao cancelar lembretes locais de medicamentos.');
      }
    } catch (_) {
      AppLogger.w(
        'Falha ao consultar ou cancelar lembretes locais de medicamentos.',
      );
    }
  }

  Set<int> _cleanupIds(
    List<Medication> medications,
    List<PendingNotificationRequest> pending,
  ) {
    final otherIds = pending
        .where((request) => !_isMedicationRequest(request))
        .map((request) => request.id)
        .toSet();
    return {
      ...pending.where(_isMedicationRequest).map((request) => request.id),
      ...medications
          .map(
            (medication) => notificationIdForMedication(medication.firestoreId),
          )
          .where((id) => !otherIds.contains(id)),
    };
  }

  Future<Set<int>> _cancelIds(Iterable<int> ids) async {
    final failed = <int>{};
    for (final id in ids) {
      try {
        await _notificationService.cancelNotificationOrThrow(id);
      } catch (_) {
        failed.add(id);
      }
    }
    return failed;
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
      if (!shouldContinue()) {
        return const MedicationReminderRebuildResult(
          eligible: 0,
          scheduled: 0,
          failed: 0,
        );
      }
      // Failure to enumerate native state must not create duplicates or overflow.
      final pending = await _notificationService.pendingNotificationRequests();
      final failedCleanup = await _cancelIds(_cleanupIds(medications, pending));
      var failed = failedCleanup.length;
      var scheduled = 0;
      final now = _now();
      final eligibleMedications = medications
          .where(
            (medication) => isMedicationReminderEligible(
              startDate: medication.startDate,
              now: now,
              endDate: medication.endDate,
              durationDays: medication.durationDays,
            ),
          )
          .toList();
      final preferences = await _loadPreferences();
      final blockedOwners = pending
          .where((request) => failedCleanup.contains(request.id))
          .map((request) => request.payload)
          .whereType<String>()
          .toSet();
      final available = eligibleMedications
          .where(
            (medication) =>
                !failedCleanup.contains(
                  notificationIdForMedication(medication.firestoreId),
                ) &&
                !blockedOwners.contains(
                  '$medicationReminderPayloadPrefix${medication.firestoreId}',
                ),
          )
          .toList();
      final plan =
          preferences.allNotifications &&
              preferences.medicationReminders &&
              shouldContinue()
          ? _planMedicationRequests(
              available,
              now,
              medicationNativePendingBudget - failedCleanup.length,
            )
          : <_MedicationRequest>[];
      final usedIds = {
        ...failedCleanup,
        ...pending
            .where((request) => !_isMedicationRequest(request))
            .map((request) => request.id),
      };
      final attemptedIds = <int>[];
      for (final request in plan) {
        if (!shouldContinue()) break;
        var id = request.repeatDaily
            ? notificationIdForMedication(request.medication.firestoreId)
            : notificationIdForMedicationOccurrence(
                request.medication.firestoreId,
                request.date,
              );
        while (usedIds.contains(id)) {
          id = id == 0x7fffffff ? 1 : id + 1;
        }
        usedIds.add(id);
        attemptedIds.add(id);
        try {
          final success = await _notificationService.scheduleMedicationNotification(
            id: id,
            title: 'Hora do medicamento 💊',
            body: 'Está na hora de tomar: ${request.medication.name}',
            scheduledDate: request.date,
            repeatDaily: request.repeatDaily,
            preferenceKey: NotificationPreferenceKeys.medicationReminders,
            payload:
                '$medicationReminderPayloadPrefix${request.medication.firestoreId}',
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

      // Revoke the whole old generation, not only the last in-flight request.
      if (!shouldContinue()) {
        failed += (await _cancelIds(attemptedIds)).length;
        scheduled = 0;
      }

      if (failed > 0) {
        AppLogger.w(
          'Reconstrução de lembretes de medicamentos concluída com falhas.',
        );
      }

      return MedicationReminderRebuildResult(
        eligible: eligibleMedications.length,
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
