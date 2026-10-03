import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/core/services/notification_preferences.dart';
import 'package:life_os/core/utils/app_logger.dart';
import 'package:life_os/features/health/presentation/cycle/cycle_reminder_preferences.dart';
import 'package:life_os/features/health/services/cycle_reminder_action_security.dart';
import 'package:life_os/features/health/services/cycle_reminder_notification_lifecycle.dart';
import 'package:life_os/features/health/services/cycle_reminder_mutation_gate.dart';
import 'package:life_os/features/health/services/cycle_reminder_operation_epoch.dart';
import 'package:life_os/features/health/services/medication_reminder_providers.dart';
import 'package:life_os/features/notifications/domain/providers/notification_engine.dart';

export 'package:life_os/features/health/services/medication_reminder_providers.dart';

final notificationPreferencesChangedProvider = Provider<void Function()>((ref) {
  return () {
    ref.read(notificationBootstrapCoordinatorProvider).reset();
    ref.invalidate(notificationEngineProvider);
  };
});

final cycleReminderNotificationLifecycleProvider =
    Provider<CycleReminderNotificationLifecycle>((ref) {
      return CycleReminderNotificationLifecycleService(
        ref.watch(notificationServiceProvider),
        ref.watch(cycleReminderActionTokenStoreProvider),
      );
    });

class NotificationsNotifier extends AsyncNotifier<NotificationPreferences> {
  NotificationPreferencesStore get _store =>
      ref.read(notificationPreferencesStoreProvider);

  Future<void> _allNotificationsPersistenceTail = Future<void>.value();

  @override
  Future<NotificationPreferences> build() => _store.load();

  Future<void> toggleAll(bool value) async {
    state.requireValue;
    final store = _store;
    final notificationService = ref.read(notificationServiceProvider);
    final medicationReconciler = ref.read(
      medicationReminderSessionReconcilerProvider,
    );
    final medicationSession = medicationReconciler.captureSession();
    final cycleLifecycle = ref.read(cycleReminderNotificationLifecycleProvider);
    final cycleStore = ref.read(cycleReminderPreferencesStoreProvider);
    final currentUserId = ref.read(cycleReminderUserIdReaderProvider);
    final operationEpoch = ref.read(cycleReminderOperationEpochProvider);
    final mutationGate = ref.read(cycleReminderMutationGateProvider);
    final refresh = ref.read(notificationPreferencesChangedProvider);
    final cycleOwnerUid = currentUserId();
    int? generation;

    if (cycleOwnerUid != null) {
      operationEpoch.invalidate(cycleOwnerUid);
      generation = operationEpoch.snapshot(cycleOwnerUid);
    }

    final persistence = _persistAllNotifications(store, value);

    Future<void> mutate() async {
      final updated = await persistence;
      if (!ref.mounted) return;
      if (!_isCurrentCycleMutation(cycleOwnerUid, generation, operationEpoch)) {
        return;
      }

      state = AsyncData(updated);

      if (value) {
        CycleReminderPreferences? cyclePreferences;
        if (cycleOwnerUid != null) {
          try {
            cyclePreferences = await cycleStore.load(cycleOwnerUid);
          } on Object {
            AppLogger.w(
              '[NotificationsNotifier] Falha ao carregar lembrete local.',
            );
          }
        }

        if (!_isCurrentCycleMutation(
          cycleOwnerUid,
          generation,
          operationEpoch,
        )) {
          return;
        }
        final permissionGranted = await notificationService
            .requestPermissions();
        final cycleEnabled = cyclePreferences?.enabled == true;
        if (permissionGranted &&
            ((updated.medicationReminders &&
                    medicationReconciler.isCurrentSession(medicationSession)) ||
                cycleEnabled)) {
          if (!_isCurrentCycleMutation(
            cycleOwnerUid,
            generation,
            operationEpoch,
          )) {
            return;
          }
          await notificationService.requestExactAlarmPermission();
          if (!_isCurrentCycleMutation(
            cycleOwnerUid,
            generation,
            operationEpoch,
          )) {
            return;
          }
          if (updated.medicationReminders) {
            await medicationReconciler.reconcileForSession(medicationSession);
          }
          if (cycleEnabled &&
              _isCurrentCycleMutation(
                cycleOwnerUid,
                generation,
                operationEpoch,
              )) {
            await cycleLifecycle.rebuildCycleReminders(
              cycleOwnerUid!,
              cyclePreferences!,
              shouldContinue: () => _isCurrentCycleMutation(
                cycleOwnerUid,
                generation,
                operationEpoch,
              ),
            );
            if (currentUserId() != cycleOwnerUid) {
              await cycleLifecycle.cancelAllCycleReminders(cycleOwnerUid);
            }
          }
        } else if (!permissionGranted &&
            cycleEnabled &&
            _isCurrentCycleMutation(
              cycleOwnerUid,
              generation,
              operationEpoch,
            )) {
          await cycleLifecycle.cancelAllCycleReminders(cycleOwnerUid!);
        }
      } else {
        await medicationReconciler.reconcileForSession(medicationSession);
        if (!ref.mounted) return;
        if (!_isCurrentCycleMutation(
              cycleOwnerUid,
              generation,
              operationEpoch,
            ) ||
            (medicationSession != null &&
                !medicationReconciler.isCurrentSession(medicationSession))) {
          return;
        }
        await notificationService.cancelAllNotifications();
      }

      if (!ref.mounted) return;
      refresh();
    }

    if (cycleOwnerUid == null) {
      await mutate();
    } else {
      await mutationGate.run(cycleOwnerUid, mutate);
    }
  }

  Future<NotificationPreferences> _persistAllNotifications(
    NotificationPreferencesStore store,
    bool value,
  ) {
    final result = _allNotificationsPersistenceTail.then((_) async {
      await store.save(NotificationPreferenceKeys.allNotifications, value);
      return store.load();
    });
    _allNotificationsPersistenceTail = result.then<void>(
      (_) {},
      onError: (_, _) {},
    );
    return result;
  }

  bool _isCurrentCycleMutation(
    String? userId,
    int? generation,
    CycleReminderOperationEpoch epoch,
  ) {
    return userId == null ||
        (generation != null &&
            ref.read(cycleReminderUserIdReaderProvider)() == userId &&
            epoch.isCurrent(userId, generation));
  }

  Future<void> toggleStudy(bool value) async {
    await _toggleCategory(
      key: NotificationPreferenceKeys.studyReminders,
      value: value,
    );
  }

  Future<void> toggleHabit(bool value) async {
    await _toggleCategory(
      key: NotificationPreferenceKeys.habitReminders,
      value: value,
    );
  }

  Future<void> toggleMedication(bool value) async {
    state.requireValue;
    final store = _store;
    final notificationService = ref.read(notificationServiceProvider);
    final medicationReconciler = ref.read(
      medicationReminderSessionReconcilerProvider,
    );
    final medicationSession = medicationReconciler.captureSession();
    final refresh = ref.read(notificationPreferencesChangedProvider);

    await store.save(NotificationPreferenceKeys.medicationReminders, value);
    final updated = await store.load();
    if (!ref.mounted) return;

    state = AsyncData(updated);

    if (!value) {
      await medicationReconciler.reconcileForSession(medicationSession);
    } else if (updated.allNotifications &&
        medicationReconciler.isCurrentSession(medicationSession)) {
      final permissionGranted = await notificationService.requestPermissions(
        preferenceKey: NotificationPreferenceKeys.medicationReminders,
      );
      if (permissionGranted &&
          medicationReconciler.isCurrentSession(medicationSession)) {
        await notificationService.requestExactAlarmPermission();
        await medicationReconciler.reconcileForSession(medicationSession);
      }
    }

    if (!ref.mounted) return;
    refresh();
  }

  Future<void> _toggleCategory({
    required String key,
    required bool value,
  }) async {
    state.requireValue;
    final store = _store;
    final refresh = ref.read(notificationPreferencesChangedProvider);

    await store.save(key, value);
    final updated = await store.load();
    if (!ref.mounted) return;

    state = AsyncData(updated);
    refresh();
  }
}

final notificationsProvider =
    AsyncNotifierProvider<NotificationsNotifier, NotificationPreferences>(() {
      return NotificationsNotifier();
    });
