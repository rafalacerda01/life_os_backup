import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/core/services/notification_preferences.dart';
import 'package:life_os/core/utils/app_logger.dart';
import 'package:life_os/features/health/presentation/cycle/cycle_reminder_preferences.dart';
import 'package:life_os/features/settings/presentation/providers/notification_provider.dart';

import 'cycle_reminder_notification_lifecycle.dart';

typedef CycleReminderPreferencesLoader =
    Future<CycleReminderPreferences?> Function(String userId);
typedef GlobalNotificationPreferenceLoader = Future<bool> Function();

abstract interface class CycleReminderSessionRestore {
  Future<void> restoreForSession(String userId);
}

class CycleReminderSessionReconciler implements CycleReminderSessionRestore {
  factory CycleReminderSessionReconciler({
    required CycleReminderPreferencesLoader loadCyclePreferences,
    required GlobalNotificationPreferenceLoader loadGlobalNotifications,
    required CycleReminderUserIdReader currentUserId,
    required CycleReminderNotificationLifecycle lifecycle,
  }) {
    return CycleReminderSessionReconciler._(
      loadCyclePreferences,
      loadGlobalNotifications,
      currentUserId,
      lifecycle,
    );
  }

  CycleReminderSessionReconciler._(
    this._loadCyclePreferences,
    this._loadGlobalNotifications,
    this._currentUserId,
    this._lifecycle,
  );

  final CycleReminderPreferencesLoader _loadCyclePreferences;
  final GlobalNotificationPreferenceLoader _loadGlobalNotifications;
  final CycleReminderUserIdReader _currentUserId;
  final CycleReminderNotificationLifecycle _lifecycle;

  Future<void> _tail = Future<void>.value();
  Future<void>? _latestOperation;
  String? _latestUserId;

  @override
  Future<void> restoreForSession(String userId) {
    final normalizedUserId = userId.trim();
    if (normalizedUserId.isEmpty) return Future<void>.value();

    final latest = _latestOperation;
    if (latest != null && _latestUserId == normalizedUserId) return latest;

    final previous = _tail;
    late final Future<void> operation;
    operation = previous
        .then((_) => _restoreBestEffort(normalizedUserId))
        .whenComplete(() {
          if (identical(_latestOperation, operation)) {
            _latestOperation = null;
            _latestUserId = null;
          }
        });
    _tail = operation;
    _latestOperation = operation;
    _latestUserId = normalizedUserId;
    return operation;
  }

  Future<void> _restoreBestEffort(String userId) async {
    try {
      if (!await _isCurrentSessionOrCancel(userId)) return;

      final preferences = await _loadCyclePreferences(userId);
      if (!await _isCurrentSessionOrCancel(userId)) return;
      if (preferences == null) {
        await _lifecycle.cancelAllCycleReminders(userId);
        return;
      }

      final globalEnabled = await _loadGlobalNotifications();
      if (!await _isCurrentSessionOrCancel(userId)) return;

      if (!preferences.enabled || !globalEnabled) {
        await _lifecycle.cancelAllCycleReminders(userId);
        return;
      }

      await _lifecycle.rebuildCycleReminders(userId, preferences);
      await _isCurrentSessionOrCancel(userId);
    } on Object {
      AppLogger.w('[CycleReminderSession] Falha ao restaurar lembrete local.');
      try {
        await _lifecycle.cancelAllCycleReminders(userId);
      } on Object {
        AppLogger.w('[CycleReminderSession] Falha ao cancelar lembrete local.');
      }
    }
  }

  Future<bool> _isCurrentSessionOrCancel(String userId) async {
    if (_currentUserId() == userId) return true;
    await _lifecycle.cancelAllCycleReminders(userId);
    return false;
  }
}

final cycleReminderSessionReconcilerProvider =
    Provider<CycleReminderSessionRestore>((ref) {
      final cycleStore = ref.watch(cycleReminderPreferencesStoreProvider);
      final notificationStore = ref.watch(notificationPreferencesStoreProvider);
      return CycleReminderSessionReconciler(
        loadCyclePreferences: cycleStore.load,
        loadGlobalNotifications: () async {
          final preferences = await notificationStore.load();
          return preferences.allNotifications;
        },
        currentUserId: ref.watch(cycleReminderUserIdReaderProvider),
        lifecycle: ref.watch(cycleReminderNotificationLifecycleProvider),
      );
    });
