import 'package:life_os/core/database/local_database_identity.dart';
import 'package:life_os/core/services/native_notification_registry.dart';
import 'package:life_os/core/services/notification_service.dart';
import 'package:life_os/core/services/owned_notification_service.dart';

typedef TaskReminderStatus = ({int? minuteOfDay, bool needsRecovery});

class LocalTaskReminder {
  LocalTaskReminder({
    required LocalDatabaseIdentity identity,
    required bool Function() isCurrent,
    NotificationService? native,
    Future<NativeNotificationRegistry> Function()? registry,
    bool? android,
    DateTime Function()? now,
  }) : _native = OwnedNotificationService.forLocalInstallation(
         identity: identity,
         native: native ?? NotificationService.instance,
         isCurrent: isCurrent,
         registry: registry,
         android: android,
       ),
       _now = now ?? DateTime.now;

  final OwnedNotificationService _native;
  final DateTime Function() _now;
  static const logicalId = 1;
  static const _payloadPrefix = 'local_task_daily_v1/';

  Future<TaskReminderStatus> status() async {
    final pending = (await _native.pendingNotificationRequests())
        .where((request) => request.id == logicalId)
        .toList();
    if (pending.length == 1) {
      final payload = pending.single.payload;
      final value = payload != null && payload.startsWith(_payloadPrefix)
          ? int.tryParse(payload.substring(_payloadPrefix.length))
          : null;
      if (value != null &&
          _validMinute(value) &&
          payload == '$_payloadPrefix$value') {
        return (minuteOfDay: value, needsRecovery: false);
      }
    }
    return (
      minuteOfDay: null,
      needsRecovery:
          pending.isNotEmpty || await _native.hasLocalReservation(logicalId),
    );
  }

  Future<bool> create(int minuteOfDay) async {
    if (!_validMinute(minuteOfDay))
      throw ArgumentError('LOCAL_TASK_REMINDER_TIME_INVALID');
    if (!await _native.requestPermissions()) return false;
    final now = _now();
    final hour = minuteOfDay ~/ 60;
    final minute = minuteOfDay % 60;
    final today = DateTime(now.year, now.month, now.day, hour, minute);
    final next = today.isAfter(now)
        ? today
        : DateTime(now.year, now.month, now.day + 1, hour, minute);
    return _native.scheduleLocalTaskReminder(
      id: logicalId,
      scheduledDate: next,
      payload: '$_payloadPrefix$minuteOfDay',
    );
  }

  Future<void> remove() => _native.cancelNotificationOrThrow(logicalId);

  bool _validMinute(int minute) => minute >= 0 && minute < 24 * 60;
}
