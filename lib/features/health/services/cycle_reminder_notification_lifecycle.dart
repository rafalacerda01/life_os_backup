import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:life_os/core/services/notification_service.dart';
import 'package:life_os/core/utils/app_logger.dart';
import 'package:life_os/features/health/presentation/cycle/cycle_reminder_preferences.dart';

import 'cycle_reminder_action_security.dart';

const int _dailyCycleReminderSlot = 0;
const int _lastWeekdayCycleReminderSlot = DateTime.sunday;
const int cycleReminderSnoozeSlot = 8;

int cycleReminderNotificationId(String userId, int slot) {
  if (slot < _dailyCycleReminderSlot || slot > cycleReminderSnoozeSlot) {
    throw ArgumentError('CYCLE_REMINDER_SLOT_INVALID');
  }

  var hash = 0x811c9dc5;
  for (final byte in utf8.encode('cycle-reminder:$userId:$slot')) {
    hash ^= byte;
    hash = (hash * 0x01000193) & 0xffffffff;
  }

  final id = hash & 0x7fffffff;
  return id == 0 ? 1 : id;
}

List<int> cycleReminderRecurringNotificationIds(String userId) {
  return List<int>.generate(
    _lastWeekdayCycleReminderSlot + 1,
    (slot) => cycleReminderNotificationId(userId, slot),
    growable: false,
  );
}

List<int> cycleReminderNotificationIds(String userId) {
  return List<int>.generate(
    cycleReminderSnoozeSlot + 1,
    (slot) => cycleReminderNotificationId(userId, slot),
    growable: false,
  );
}

class CycleReminderNotificationPayload {
  const CycleReminderNotificationPayload({
    required this.title,
    required this.body,
  });

  final String title;
  final String body;
}

CycleReminderNotificationPayload cycleReminderNotificationPayload(
  CycleReminderPreferences preferences,
) {
  switch (preferences.privacyMode) {
    case CycleReminderPrivacyMode.discreet:
      return const CycleReminderNotificationPayload(
        title: 'Lembrete pessoal',
        body: 'Você tem um lembrete programado.',
      );
    case CycleReminderPrivacyMode.informative:
      final title = switch (preferences.type) {
        CycleReminderType.pill => 'Lembrete de pílula',
        CycleReminderType.otherContraceptive => 'Lembrete de contraceptivo',
        CycleReminderType.personal => 'Lembrete pessoal',
      };
      return CycleReminderNotificationPayload(
        title: title,
        body: 'Horário do seu lembrete.',
      );
    case CycleReminderPrivacyMode.custom:
      return CycleReminderNotificationPayload(
        title: preferences.customTitle,
        body: preferences.customBody,
      );
  }
}

DateTime nextDailyCycleReminderOccurrence({
  required DateTime now,
  required int hour,
  required int minute,
}) {
  final today = DateTime(now.year, now.month, now.day, hour, minute);
  if (!today.isBefore(now)) return today;
  return DateTime(now.year, now.month, now.day + 1, hour, minute);
}

DateTime nextWeeklyCycleReminderOccurrence({
  required DateTime now,
  required int weekday,
  required int hour,
  required int minute,
}) {
  if (weekday < DateTime.monday || weekday > DateTime.sunday) {
    throw ArgumentError('CYCLE_REMINDER_WEEKDAY_INVALID');
  }

  var daysUntil = (weekday - now.weekday) % DateTime.daysPerWeek;
  var occurrence = DateTime(
    now.year,
    now.month,
    now.day + daysUntil,
    hour,
    minute,
  );
  if (occurrence.isBefore(now)) {
    daysUntil += DateTime.daysPerWeek;
    occurrence = DateTime(
      now.year,
      now.month,
      now.day + daysUntil,
      hour,
      minute,
    );
  }
  return occurrence;
}

class CycleReminderRebuildResult {
  const CycleReminderRebuildResult({
    required this.eligible,
    required this.scheduled,
    required this.failed,
    required this.cancellationFailed,
  });

  final int eligible;
  final int scheduled;
  final int failed;
  final int cancellationFailed;
}

typedef CycleReminderRebuildGuard = bool Function();

abstract interface class CycleReminderNotificationLifecycle {
  Future<int> cancelAllCycleReminders(String userId);

  Future<CycleReminderRebuildResult> rebuildCycleReminders(
    String userId,
    CycleReminderPreferences preferences, {
    CycleReminderRebuildGuard? shouldContinue,
  });
}

class CycleReminderNotificationLifecycleService
    implements CycleReminderNotificationLifecycle {
  CycleReminderNotificationLifecycleService(
    this._notificationService,
    this._actionTokenStore, {
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final NotificationService _notificationService;
  final CycleReminderActionTokenReader _actionTokenStore;
  final DateTime Function() _clock;

  @override
  Future<int> cancelAllCycleReminders(String userId) async {
    return _cancelIds(cycleReminderNotificationIds(userId));
  }

  Future<int> _cancelRecurringCycleReminders(String userId) {
    return _cancelIds(cycleReminderRecurringNotificationIds(userId));
  }

  Future<int> _cancelIds(Iterable<int> ids) async {
    var failed = 0;
    for (final id in ids) {
      try {
        final cancelled = await _notificationService
            .cancelCycleReminderNotification(id);
        if (!cancelled) failed += 1;
      } on Object {
        failed += 1;
      }
    }

    if (failed > 0) {
      AppLogger.w(
        '[CycleReminderLifecycle] Alguns cancelamentos locais falharam.',
      );
    }
    return failed;
  }

  @override
  Future<CycleReminderRebuildResult> rebuildCycleReminders(
    String userId,
    CycleReminderPreferences preferences, {
    CycleReminderRebuildGuard? shouldContinue,
  }) async {
    final cancellationFailed = await _cancelRecurringCycleReminders(userId);
    if (!preferences.enabled) {
      return CycleReminderRebuildResult(
        eligible: 0,
        scheduled: 0,
        failed: 0,
        cancellationFailed: cancellationFailed,
      );
    }

    final notificationContent = cycleReminderNotificationPayload(preferences);
    final eligible = preferences.frequency == CycleReminderFrequency.daily
        ? 1
        : preferences.weekdays.length;
    if (shouldContinue?.call() == false) {
      return CycleReminderRebuildResult(
        eligible: eligible,
        scheduled: 0,
        failed: 0,
        cancellationFailed: cancellationFailed,
      );
    }
    late final String actionPayload;
    try {
      final token = await _actionTokenStore.getOrCreate(userId);
      actionPayload = const CycleReminderActionPayloadCodec().encode(
        CycleReminderActionPayload(token),
      );
    } on Object {
      AppLogger.w(
        '[CycleReminderLifecycle] Token local indisponível para agendamento.',
      );
      return CycleReminderRebuildResult(
        eligible: eligible,
        scheduled: 0,
        failed: eligible,
        cancellationFailed: cancellationFailed,
      );
    }
    if (shouldContinue?.call() == false) {
      return CycleReminderRebuildResult(
        eligible: eligible,
        scheduled: 0,
        failed: 0,
        cancellationFailed: cancellationFailed,
      );
    }
    final now = _clock();
    var scheduled = 0;
    var failed = 0;

    Future<void> schedule({
      required int slot,
      required DateTime occurrence,
      required DateTimeComponents components,
    }) async {
      if (shouldContinue?.call() == false) return;
      try {
        final didSchedule = await _notificationService
            .scheduleCycleReminderNotification(
              id: cycleReminderNotificationId(userId, slot),
              title: notificationContent.title,
              body: notificationContent.body,
              scheduledDate: occurrence,
              matchDateTimeComponents: components,
              payload: actionPayload,
              includeDoneAction: preferences.type == CycleReminderType.pill,
            );
        if (didSchedule) {
          scheduled += 1;
        } else {
          failed += 1;
        }
      } on Object {
        failed += 1;
      }
    }

    if (preferences.frequency == CycleReminderFrequency.daily) {
      await schedule(
        slot: _dailyCycleReminderSlot,
        occurrence: nextDailyCycleReminderOccurrence(
          now: now,
          hour: preferences.hour,
          minute: preferences.minute,
        ),
        components: DateTimeComponents.time,
      );
    } else {
      final weekdays = preferences.weekdays.toList()..sort();
      for (final weekday in weekdays) {
        if (shouldContinue?.call() == false) break;
        await schedule(
          slot: weekday,
          occurrence: nextWeeklyCycleReminderOccurrence(
            now: now,
            weekday: weekday,
            hour: preferences.hour,
            minute: preferences.minute,
          ),
          components: DateTimeComponents.dayOfWeekAndTime,
        );
      }
    }

    if (failed > 0) {
      AppLogger.w(
        '[CycleReminderLifecycle] Alguns agendamentos locais falharam.',
      );
    }
    return CycleReminderRebuildResult(
      eligible: eligible,
      scheduled: scheduled,
      failed: failed,
      cancellationFailed: cancellationFailed,
    );
  }
}
