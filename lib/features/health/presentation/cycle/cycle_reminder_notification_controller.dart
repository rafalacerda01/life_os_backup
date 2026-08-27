import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/core/services/notification_preferences.dart';
import 'package:life_os/core/services/notification_service.dart';
import 'package:life_os/core/utils/app_logger.dart';
import 'package:life_os/features/health/services/cycle_reminder_notification_lifecycle.dart';
import 'package:life_os/features/health/services/cycle_reminder_mutation_gate.dart';
import 'package:life_os/features/health/services/cycle_reminder_operation_epoch.dart';
import 'package:life_os/features/settings/presentation/providers/notification_provider.dart';

import 'cycle_reminder_preferences.dart';

typedef CycleReminderPreferencesPersist =
    Future<String> Function(CycleReminderPreferences preferences);

class CycleReminderNotificationController {
  CycleReminderNotificationController(
    this._persist,
    this._currentUserId,
    this._allNotificationsEnabled,
    this._notificationService,
    this._lifecycle,
    this._operationEpoch, [
    CycleReminderMutationGate? mutationGate,
  ]) : _mutationGate = mutationGate ?? CycleReminderMutationGate();

  final CycleReminderPreferencesPersist _persist;
  final CycleReminderUserIdReader _currentUserId;
  final Future<bool> Function() _allNotificationsEnabled;
  final NotificationService _notificationService;
  final CycleReminderNotificationLifecycle _lifecycle;
  final CycleReminderOperationEpoch _operationEpoch;
  final CycleReminderMutationGate _mutationGate;

  Future<void> save(CycleReminderPreferences preferences) async {
    final expectedOwnerUid = _currentUserId();
    if (expectedOwnerUid == null) {
      throw StateError('CYCLE_REMINDER_SESSION_REQUIRED');
    }

    _operationEpoch.invalidate(expectedOwnerUid);
    final generation = _operationEpoch.snapshot(expectedOwnerUid);
    await _mutationGate.run(expectedOwnerUid, () async {
      if (!_isCurrent(expectedOwnerUid, generation)) return;
      final ownerUid = await _persist(preferences);
      if (ownerUid != expectedOwnerUid) {
        _operationEpoch.invalidate(ownerUid);
        return;
      }
      await _reconcile(ownerUid, generation, preferences);
    });
  }

  Future<void> _reconcile(
    String ownerUid,
    int generation,
    CycleReminderPreferences preferences,
  ) async {
    try {
      await _lifecycle.cancelAllCycleReminders(ownerUid);
      if (!_isCurrent(ownerUid, generation)) return;

      if (!preferences.enabled) {
        return;
      }

      if (!await _allNotificationsEnabled()) {
        return;
      }

      if (!await _isCurrentOrCancel(ownerUid, generation)) return;
      final permissionGranted = await _notificationService.requestPermissions();
      if (!permissionGranted) {
        return;
      }

      if (!await _isCurrentOrCancel(ownerUid, generation)) return;
      await _notificationService.requestExactAlarmPermission();
      if (!await _isCurrentOrCancel(ownerUid, generation)) return;
      await _lifecycle.rebuildCycleReminders(
        ownerUid,
        preferences,
        shouldContinue: () => _isCurrent(ownerUid, generation),
      );
      await _isOwnerSessionOrCancel(ownerUid);
    } on Object {
      AppLogger.w(
        '[CycleReminderController] Falha ao reconciliar lembrete local.',
      );
      if (_currentUserId() == ownerUid &&
          !_operationEpoch.isCurrent(ownerUid, generation)) {
        return;
      }
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

  Future<bool> _isCurrentOrCancel(String ownerUid, int generation) async {
    if (_currentUserId() != ownerUid) {
      await _lifecycle.cancelAllCycleReminders(ownerUid);
      return false;
    }
    return _operationEpoch.isCurrent(ownerUid, generation);
  }

  bool _isCurrent(String ownerUid, int generation) {
    return _currentUserId() == ownerUid &&
        _operationEpoch.isCurrent(ownerUid, generation);
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
        ref.watch(cycleReminderOperationEpochProvider),
        ref.watch(cycleReminderMutationGateProvider),
      );
    });
