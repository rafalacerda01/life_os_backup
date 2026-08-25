import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/core/services/notification_preferences.dart';
import 'package:life_os/core/services/notification_service.dart';
import 'package:life_os/core/utils/app_logger.dart';
import 'package:life_os/features/health/services/cycle_reminder_notification_lifecycle.dart';
import 'package:life_os/features/settings/presentation/providers/notification_provider.dart';

import 'cycle_reminder_preferences.dart';

typedef CycleReminderPreferencesPersist =
    Future<String> Function(CycleReminderPreferences preferences);

class CycleReminderNotificationController {
  const CycleReminderNotificationController(
    this._persist,
    this._currentUserId,
    this._allNotificationsEnabled,
    this._notificationService,
    this._lifecycle,
  );

  final CycleReminderPreferencesPersist _persist;
  final CycleReminderUserIdReader _currentUserId;
  final Future<bool> Function() _allNotificationsEnabled;
  final NotificationService _notificationService;
  final CycleReminderNotificationLifecycle _lifecycle;

  Future<void> save(CycleReminderPreferences preferences) async {
    final ownerUid = await _persist(preferences);

    try {
      if (!preferences.enabled) {
        await _lifecycle.cancelAllCycleReminders(ownerUid);
        return;
      }

      if (!await _allNotificationsEnabled()) {
        await _lifecycle.cancelAllCycleReminders(ownerUid);
        return;
      }

      if (!await _isOwnerSessionOrCancel(ownerUid)) return;
      final permissionGranted = await _notificationService.requestPermissions();
      if (!permissionGranted) {
        await _lifecycle.cancelAllCycleReminders(ownerUid);
        return;
      }

      if (!await _isOwnerSessionOrCancel(ownerUid)) return;
      await _notificationService.requestExactAlarmPermission();
      if (!await _isOwnerSessionOrCancel(ownerUid)) return;
      await _lifecycle.rebuildCycleReminders(ownerUid, preferences);
      await _isOwnerSessionOrCancel(ownerUid);
    } on Object {
      AppLogger.w(
        '[CycleReminderController] Falha ao reconciliar lembrete local.',
      );
      try {
        await _lifecycle.cancelAllCycleReminders(ownerUid);
      } on Object {
        AppLogger.w(
          '[CycleReminderController] Falha ao cancelar lembrete local.',
        );
      }
    }
  }

  Future<void> setEnabled(CycleReminderPreferences current, bool enabled) {
    if (current.enabled == enabled) return Future<void>.value();
    return save(current.copyWith(enabled: enabled));
  }

  Future<bool> _isOwnerSessionOrCancel(String ownerUid) async {
    if (_currentUserId() == ownerUid) return true;
    await _lifecycle.cancelAllCycleReminders(ownerUid);
    return false;
  }
}

final cycleReminderNotificationControllerProvider =
    Provider<CycleReminderNotificationController>((ref) {
      final userIdReader = ref.watch(cycleReminderUserIdReaderProvider);
      return CycleReminderNotificationController(
        (preferences) => ref
            .read(cycleReminderPreferencesProvider.notifier)
            .save(preferences),
        userIdReader,
        () async {
          final preferences = await ref
              .read(notificationPreferencesStoreProvider)
              .load();
          return preferences.allNotifications;
        },
        ref.watch(notificationServiceProvider),
        ref.watch(cycleReminderNotificationLifecycleProvider),
      );
    });
