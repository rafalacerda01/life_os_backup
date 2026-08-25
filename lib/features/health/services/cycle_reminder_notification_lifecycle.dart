import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:life_os/core/services/notification_service.dart';
import 'package:life_os/core/utils/app_logger.dart';
import 'package:life_os/features/health/presentation/cycle/cycle_reminder_preferences.dart';

const int _dailyCycleReminderSlot = 0;
const int _lastWeekdayCycleReminderSlot = DateTime.sunday;

int cycleReminderNotificationId(String userId, int slot) {
  if (slot < _dailyCycleReminderSlot || slot > _lastWeekdayCycleReminderSlot) {
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

List<int> cycleReminderNotificationIds(String userId) {
  return List<int>.generate(
    _lastWeekdayCycleReminderSlot + 1,
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

abstract interface class CycleReminderNotificationLifecycle {
  Future<int> cancelAllCycleReminders(String userId);

  Future<CycleReminderRebuildResult> rebuildCycleReminders(
    String userId,
    CycleReminderPreferences preferences,
  );
}

class CycleReminderNotificationLifecycleService
    implements CycleReminderNotificationLifecycle {
  CycleReminderNotificationLifecycleService(
    this._notificationService, {
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final NotificationService _notificationService;
  final DateTime Function() _clock;

  @override
  Future<int> cancelAllCycleReminders(String userId) async {
    var failed = 0;
    for (final id in cycleReminderNotificationIds(userId)) {
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
    CycleReminderPreferences preferences,
  ) async {
    final cancellationFailed = await cancelAllCycleReminders(userId);
    if (!preferences.enabled) {
      return CycleReminderRebuildResult(
        eligible: 0,
        scheduled: 0,
        failed: 0,
        cancellationFailed: cancellationFailed,
      );
    }

    final payload = cycleReminderNotificationPayload(preferences);
    final now = _clock();
    var scheduled = 0;
    var failed = 0;

    Future<void> schedule({
      required int slot,
      required DateTime occurrence,
      required DateTimeComponents components,
    }) async {
      try {
        final didSchedule = await _notificationService
            .scheduleCycleReminderNotification(
              id: cycleReminderNotificationId(userId, slot),
              title: payload.title,
              body: payload.body,
              scheduledDate: occurrence,
              matchDateTimeComponents: components,
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
      eligible: preferences.frequency == CycleReminderFrequency.daily
          ? 1
          : preferences.weekdays.length,
      scheduled: scheduled,
      failed: failed,
      cancellationFailed: cancellationFailed,
    );
  }
}
