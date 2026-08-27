import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/core/services/notification_preferences.dart';
import 'package:life_os/core/utils/app_logger.dart';
import 'package:life_os/features/health/presentation/cycle/cycle_reminder_preferences.dart';
import 'package:life_os/features/settings/presentation/providers/notification_provider.dart';

import 'cycle_reminder_notification_lifecycle.dart';
import 'cycle_reminder_mutation_gate.dart';
import 'cycle_reminder_operation_epoch.dart';

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
    CycleReminderOperationEpoch? operationEpoch,
    CycleReminderMutationGate? mutationGate,
  }) {
    return CycleReminderSessionReconciler._(
      loadCyclePreferences,
      loadGlobalNotifications,
      currentUserId,
      lifecycle,
      operationEpoch ?? CycleReminderOperationEpoch(),
      mutationGate ?? CycleReminderMutationGate(),
    );
  }

  CycleReminderSessionReconciler._(
    this._loadCyclePreferences,
    this._loadGlobalNotifications,
    this._currentUserId,
    this._lifecycle,
    this._operationEpoch,
    this._mutationGate,
  );

  final CycleReminderPreferencesLoader _loadCyclePreferences;
  final GlobalNotificationPreferenceLoader _loadGlobalNotifications;
  final CycleReminderUserIdReader _currentUserId;
  final CycleReminderNotificationLifecycle _lifecycle;
  final CycleReminderOperationEpoch _operationEpoch;
  final CycleReminderMutationGate _mutationGate;

  final Map<String, Future<void>> _latestOperations = <String, Future<void>>{};

  @override
  Future<void> restoreForSession(String userId) {
    final normalizedUserId = userId.trim();
    if (normalizedUserId.isEmpty) return Future<void>.value();
    if (_currentUserId() != normalizedUserId) return Future<void>.value();

    final latest = _latestOperations[normalizedUserId];
    if (latest != null) return latest;

    final generation = _operationEpoch.snapshot(normalizedUserId);
    late final Future<void> operation;
    operation = _mutationGate
        .run(
          normalizedUserId,
          () => _restoreBestEffort(normalizedUserId, generation),
        )
        .whenComplete(() {
          if (identical(_latestOperations[normalizedUserId], operation)) {
            _latestOperations.remove(normalizedUserId);
          }
        });
    _latestOperations[normalizedUserId] = operation;
    return operation;
  }

  Future<void> _restoreBestEffort(String userId, int generation) async {
    try {
      if (!await _isCurrentSessionOrCancel(userId, generation)) return;

      final preferences = await _loadCyclePreferences(userId);
      if (!await _isCurrentSessionOrCancel(userId, generation)) return;
      if (preferences == null) {
        await _lifecycle.cancelAllCycleReminders(userId);
        return;
      }

      final globalEnabled = await _loadGlobalNotifications();
      if (!await _isCurrentSessionOrCancel(userId, generation)) return;

      if (!preferences.enabled || !globalEnabled) {
        await _lifecycle.cancelAllCycleReminders(userId);
        return;
      }

      await _lifecycle.rebuildCycleReminders(
        userId,
        preferences,
        shouldContinue: () => _isCurrent(userId, generation),
      );
      await _isCurrentSessionOrCancel(userId, generation);
    } on Object {
      AppLogger.w('[CycleReminderSession] Falha ao restaurar lembrete local.');
      if (_currentUserId() == userId &&
          !_operationEpoch.isCurrent(userId, generation)) {
        return;
      }
      try {
        await _lifecycle.cancelAllCycleReminders(userId);
      } on Object {
        AppLogger.w('[CycleReminderSession] Falha ao cancelar lembrete local.');
      }
    }
  }

  Future<bool> _isCurrentSessionOrCancel(String userId, int generation) async {
    if (_isCurrent(userId, generation)) return true;
    if (_currentUserId() != userId) {
      await _lifecycle.cancelAllCycleReminders(userId);
    }
    return false;
  }

  bool _isCurrent(String userId, int generation) {
    return _currentUserId() == userId &&
        _operationEpoch.isCurrent(userId, generation);
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
        operationEpoch: ref.watch(cycleReminderOperationEpochProvider),
        mutationGate: ref.watch(cycleReminderMutationGateProvider),
      );
    });
