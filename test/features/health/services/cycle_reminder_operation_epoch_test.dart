import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/services/notification_preferences.dart';
import 'package:life_os/core/services/notification_service.dart';
import 'package:life_os/features/health/presentation/cycle/cycle_reminder_notification_controller.dart';
import 'package:life_os/features/health/presentation/cycle/cycle_reminder_preferences.dart';
import 'package:life_os/features/health/services/cycle_reminder_action_coordinator.dart';
import 'package:life_os/features/health/services/cycle_reminder_action_security.dart';
import 'package:life_os/features/health/services/cycle_reminder_notification_lifecycle.dart';
import 'package:life_os/features/health/services/cycle_reminder_mutation_gate.dart';
import 'package:life_os/features/health/services/cycle_reminder_operation_epoch.dart';
import 'package:life_os/features/health/services/cycle_reminder_session_authority.dart';
import 'package:life_os/features/health/services/cycle_reminder_session_cleanup.dart';
import 'package:life_os/features/health/services/cycle_reminder_session_reconciler.dart';
import 'package:life_os/features/health/services/medication_reminder_lifecycle.dart';
import 'package:life_os/features/settings/presentation/providers/notification_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _userId = 'user-a';
const _token = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

class _FixedTokenStore implements CycleReminderActionTokenReader {
  @override
  Future<String> getOrCreate(String userId) async => _token;

  @override
  Future<String?> load(String userId) async => _token;
}

class _NotificationState {
  final Set<int> activeIds = <int>{};
  final List<String> events = <String>[];
}

class _ObservedMutationGate extends CycleReminderMutationGate {
  final Completer<void> secondAdmission = Completer<void>();
  int _admissions = 0;

  @override
  Future<T> run<T>(String userId, Future<T> Function() operation) {
    _admissions += 1;
    if (_admissions == 2) secondAdmission.complete();
    return super.run(userId, operation);
  }
}

class _GatedActionGateway implements CycleReminderActionNotificationGateway {
  _GatedActionGateway(this.state);

  final _NotificationState state;
  final List<int> cancelledIds = <int>[];
  final List<int> scheduledIds = <int>[];
  Completer<void>? cancelStarted;
  Completer<void>? allowCancel;
  Completer<void>? scheduleStarted;
  Completer<void>? allowSchedule;
  int? failingCancelCall;
  bool throwOnSchedule = false;
  int _cancelCalls = 0;

  @override
  Future<bool> cancel(int id) async {
    _cancelCalls += 1;
    cancelledIds.add(id);
    state.events.add('action-cancel:$id');
    if (_cancelCalls == failingCancelCall) {
      state.events.add('action-cancel-failed:$id');
      return false;
    }
    state.activeIds.remove(id);
    final started = cancelStarted;
    if (started != null && !started.isCompleted) started.complete();
    final gate = allowCancel;
    if (gate != null) await gate.future;
    return true;
  }

  @override
  Future<bool> scheduleSnooze({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledDate,
    required String payload,
  }) async {
    state.events.add('action-schedule-start:$id');
    final started = scheduleStarted;
    if (started != null && !started.isCompleted) started.complete();
    final gate = allowSchedule;
    if (gate != null) await gate.future;
    if (throwOnSchedule) throw StateError('private schedule failure');
    scheduledIds.add(id);
    state.activeIds.add(id);
    state.events.add('action-schedule-done:$id');
    return true;
  }
}

class _SharedCycleLifecycle implements CycleReminderNotificationLifecycle {
  _SharedCycleLifecycle(this.state);

  final _NotificationState state;
  int cancelAllCalls = 0;
  int rebuildCalls = 0;

  @override
  Future<int> cancelAllCycleReminders(String userId) async {
    cancelAllCalls += 1;
    state.events.add('cycle-cancel-all');
    state.activeIds.removeAll(cycleReminderNotificationIds(userId));
    return 0;
  }

  @override
  Future<CycleReminderRebuildResult> rebuildCycleReminders(
    String userId,
    CycleReminderPreferences preferences, {
    CycleReminderRebuildGuard? shouldContinue,
  }) async {
    rebuildCalls += 1;
    state.events.add('cycle-rebuild');
    state.activeIds.addAll(cycleReminderRecurringNotificationIds(userId));
    return const CycleReminderRebuildResult(
      eligible: 1,
      scheduled: 1,
      failed: 0,
      cancellationFailed: 0,
    );
  }
}

class _RecordingNotificationService extends NotificationService {
  _RecordingNotificationService(this.state);

  final _NotificationState state;
  int cancelAllCalls = 0;
  int permissionRequests = 0;
  int exactRequests = 0;

  @override
  Future<void> cancelAllNotifications() async {
    cancelAllCalls += 1;
    state.events.add('global-cancel-all');
    state.activeIds.clear();
  }

  @override
  Future<bool> requestPermissions({String? preferenceKey}) async {
    permissionRequests += 1;
    return true;
  }

  @override
  Future<bool> requestExactAlarmPermission() async {
    exactRequests += 1;
    return true;
  }
}

class _NoopMedicationLifecycle implements MedicationReminderLifecycle {
  @override
  Future<void> cancelAllMedicationReminders() async {}

  @override
  Future<MedicationReminderRebuildResult> rebuildMedicationReminders() async {
    return const MedicationReminderRebuildResult(
      eligible: 0,
      scheduled: 0,
      failed: 0,
    );
  }
}

class _EpochRecordingNotificationStore extends NotificationPreferencesStore {
  _EpochRecordingNotificationStore(this.epoch, this.generation, this.events);

  final CycleReminderOperationEpoch epoch;
  final int generation;
  final List<String> events;

  @override
  Future<void> save(String key, bool value) async {
    events.add(
      epoch.isCurrent(_userId, generation)
          ? 'global-save-current'
          : 'global-save-stale',
    );
    await super.save(key, value);
  }
}

CycleReminderPreferences _preferences({
  bool enabled = true,
  String customTitle = '',
  String customBody = '',
}) {
  return CycleReminderPreferences(
    enabled: enabled,
    type: CycleReminderType.personal,
    hour: 9,
    minute: 30,
    frequency: CycleReminderFrequency.daily,
    privacyMode: customTitle.isEmpty
        ? CycleReminderPrivacyMode.discreet
        : CycleReminderPrivacyMode.custom,
    customTitle: customTitle,
    customBody: customBody,
  );
}

NotificationResponse _response() {
  final payload = const CycleReminderActionPayloadCodec().encode(
    const CycleReminderActionPayload(_token),
  );
  return NotificationResponse(
    notificationResponseType:
        NotificationResponseType.selectedNotificationAction,
    id: cycleReminderNotificationId(_userId, 0),
    actionId: cycleReminderSnoozeActionId,
    payload: payload,
  );
}

CycleReminderActionCoordinator _coordinator({
  required CycleReminderOperationEpoch epoch,
  required _GatedActionGateway gateway,
  required CycleReminderNotificationLifecycle lifecycle,
  required Future<bool> Function() loadGlobalNotifications,
  CycleReminderPreferences? preferences,
  CycleReminderMutationGate? mutationGate,
}) {
  return CycleReminderActionCoordinator(
    currentUserId: () => _userId,
    tokenStore: _FixedTokenStore(),
    loadPreferences: (_) async => preferences ?? _preferences(),
    loadGlobalNotifications: loadGlobalNotifications,
    operationEpoch: epoch,
    sessionAuthority: CycleReminderSessionAuthority(),
    mutationGate: mutationGate ?? CycleReminderMutationGate(),
    lifecycle: lifecycle,
    notificationGateway: gateway,
    clock: () => DateTime(2026, 8, 26, 10),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CycleReminderOperationEpoch', () {
    test('snapshot inicial é estável', () {
      final epoch = CycleReminderOperationEpoch();

      expect(epoch.snapshot(_userId), 0);
      expect(epoch.snapshot(_userId), 0);
    });

    test('invalidate torna snapshot anterior stale', () {
      final epoch = CycleReminderOperationEpoch();
      final generation = epoch.snapshot(_userId);

      epoch.invalidate(_userId);

      expect(epoch.isCurrent(_userId, generation), isFalse);
    });

    test('novo snapshot depois de invalidate é current', () {
      final epoch = CycleReminderOperationEpoch();
      epoch.invalidate(_userId);

      final generation = epoch.snapshot(_userId);

      expect(generation, 1);
      expect(epoch.isCurrent(_userId, generation), isTrue);
    });

    test('invalidate de A não afeta B', () {
      final epoch = CycleReminderOperationEpoch();
      final generationB = epoch.snapshot('user-b');

      epoch.invalidate(_userId);

      expect(epoch.isCurrent('user-b', generationB), isTrue);
    });

    test('UID vazio é rejeitado', () {
      final epoch = CycleReminderOperationEpoch();

      expect(() => epoch.snapshot('  '), throwsArgumentError);
      expect(() => epoch.invalidate('  '), throwsArgumentError);
      expect(() => epoch.isCurrent('  ', 0), throwsArgumentError);
    });
  });

  test('stale antes do schedule nunca agenda slot 8', () async {
    final epoch = CycleReminderOperationEpoch();
    final state = _NotificationState();
    final gateway = _GatedActionGateway(state)
      ..cancelStarted = Completer<void>()
      ..allowCancel = Completer<void>();
    final lifecycle = _SharedCycleLifecycle(state);
    final coordinator = _coordinator(
      epoch: epoch,
      gateway: gateway,
      lifecycle: lifecycle,
      loadGlobalNotifications: () async => true,
    );
    await coordinator.onSessionPrepared(_userId);

    final operation = coordinator.handle(_response());
    await gateway.cancelStarted!.future;
    epoch.invalidate(_userId);
    gateway.allowCancel!.complete();
    await operation;

    expect(gateway.scheduledIds, isEmpty);
    expect(lifecycle.cancelAllCalls, 0);
  });

  test(
    'action real em voo libera gate antes do cancel final do logout',
    () async {
      final epoch = CycleReminderOperationEpoch();
      final mutationGate = CycleReminderMutationGate();
      final state = _NotificationState();
      final gateway = _GatedActionGateway(state)
        ..scheduleStarted = Completer<void>()
        ..allowSchedule = Completer<void>();
      final lifecycle = _SharedCycleLifecycle(state);
      final cleanup = CycleReminderSessionCleanup(mutationGate, lifecycle);
      final coordinator = _coordinator(
        epoch: epoch,
        gateway: gateway,
        lifecycle: lifecycle,
        loadGlobalNotifications: () async => true,
        mutationGate: mutationGate,
      );
      await coordinator.onSessionPrepared(_userId);

      final action = coordinator.handle(_response());
      await gateway.scheduleStarted!.future;
      coordinator.onSessionCleared();
      final finalCleanup = cleanup.cancelAfterCurrentMutations(_userId);
      await Future<void>.value();

      expect(lifecycle.cancelAllCalls, 0);

      gateway.allowSchedule!.complete();
      await Future.wait<void>(<Future<void>>[action, finalCleanup]);

      expect(
        state.events.indexOf(
          'action-schedule-done:${gateway.scheduledIds.single}',
        ),
        lessThan(state.events.indexOf('cycle-cancel-all')),
      );
      expect(
        cycleReminderNotificationIds(_userId).where(state.activeIds.contains),
        isEmpty,
      );
      expect(lifecycle.cancelAllCalls, 1);
    },
  );

  test(
    'cancel compensatório pode falhar e cleanup final ainda remove slot 8',
    () async {
      final epoch = CycleReminderOperationEpoch();
      final mutationGate = CycleReminderMutationGate();
      final state = _NotificationState();
      final gateway = _GatedActionGateway(state)
        ..scheduleStarted = Completer<void>()
        ..allowSchedule = Completer<void>()
        ..failingCancelCall = 2;
      final lifecycle = _SharedCycleLifecycle(state);
      final cleanup = CycleReminderSessionCleanup(mutationGate, lifecycle);
      final coordinator = _coordinator(
        epoch: epoch,
        gateway: gateway,
        lifecycle: lifecycle,
        loadGlobalNotifications: () async => true,
        mutationGate: mutationGate,
      );
      await coordinator.onSessionPrepared(_userId);

      final action = coordinator.handle(_response());
      await gateway.scheduleStarted!.future;
      coordinator.onSessionCleared();
      final finalCleanup = cleanup.cancelAfterCurrentMutations(_userId);
      gateway.allowSchedule!.complete();
      await Future.wait<void>(<Future<void>>[action, finalCleanup]);

      final snoozeId = cycleReminderNotificationId(
        _userId,
        cycleReminderSnoozeSlot,
      );
      expect(state.events, contains('action-cancel-failed:$snoozeId'));
      expect(
        state.events.indexOf('action-cancel-failed:$snoozeId'),
        lessThan(state.events.indexOf('cycle-cancel-all')),
      );
      expect(state.activeIds, isNot(contains(snoozeId)));
      expect(lifecycle.cancelAllCalls, 1);
    },
  );

  test('action aguardando gate revalida clear antes de schedule', () async {
    final epoch = CycleReminderOperationEpoch();
    final mutationGate = _ObservedMutationGate();
    final state = _NotificationState();
    final gateway = _GatedActionGateway(state);
    final lifecycle = _SharedCycleLifecycle(state);
    final cleanup = CycleReminderSessionCleanup(mutationGate, lifecycle);
    final coordinator = _coordinator(
      epoch: epoch,
      gateway: gateway,
      lifecycle: lifecycle,
      loadGlobalNotifications: () async => true,
      mutationGate: mutationGate,
    );
    await coordinator.onSessionPrepared(_userId);
    final blockerStarted = Completer<void>();
    final releaseBlocker = Completer<void>();
    final blocker = mutationGate.run(_userId, () async {
      blockerStarted.complete();
      await releaseBlocker.future;
    });
    await blockerStarted.future;

    final action = coordinator.handle(_response());
    await mutationGate.secondAdmission.future;
    coordinator.onSessionCleared();
    final finalCleanup = cleanup.cancelAfterCurrentMutations(_userId);
    releaseBlocker.complete();
    await Future.wait<void>(<Future<void>>[blocker, action, finalCleanup]);

    expect(gateway.scheduledIds, isEmpty);
    expect(gateway.cancelledIds, isEmpty);
    expect(lifecycle.cancelAllCalls, 1);
    expect(state.activeIds, isEmpty);
  });

  test('action concorrente com global OFF não recria slot 8', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      NotificationPreferenceKeys.allNotifications: true,
      NotificationPreferenceKeys.medicationReminders: false,
    });
    final epoch = CycleReminderOperationEpoch();
    final generation = epoch.snapshot(_userId);
    final state = _NotificationState();
    final gateway = _GatedActionGateway(state)
      ..scheduleStarted = Completer<void>()
      ..allowSchedule = Completer<void>();
    final lifecycle = _SharedCycleLifecycle(state);
    final mutationGate = CycleReminderMutationGate();
    final service = _RecordingNotificationService(state);
    final store = _EpochRecordingNotificationStore(
      epoch,
      generation,
      state.events,
    );
    final coordinator = _coordinator(
      epoch: epoch,
      gateway: gateway,
      lifecycle: lifecycle,
      loadGlobalNotifications: () async {
        return (await store.load()).allNotifications;
      },
      mutationGate: mutationGate,
    );
    await coordinator.onSessionPrepared(_userId);
    final container = ProviderContainer(
      overrides: [
        notificationPreferencesStoreProvider.overrideWithValue(store),
        notificationServiceProvider.overrideWithValue(service),
        medicationReminderLifecycleProvider.overrideWithValue(
          _NoopMedicationLifecycle(),
        ),
        cycleReminderNotificationLifecycleProvider.overrideWithValue(lifecycle),
        cycleReminderUserIdReaderProvider.overrideWithValue(() => _userId),
        cycleReminderOperationEpochProvider.overrideWithValue(epoch),
        cycleReminderMutationGateProvider.overrideWithValue(mutationGate),
        notificationPreferencesChangedProvider.overrideWithValue(() {}),
      ],
    );
    addTearDown(container.dispose);
    await container.read(notificationsProvider.future);

    final action = coordinator.handle(_response());
    await gateway.scheduleStarted!.future;
    final off = container.read(notificationsProvider.notifier).toggleAll(false);
    await Future<void>.value();
    expect(service.cancelAllCalls, 0);
    gateway.allowSchedule!.complete();
    await Future.wait<void>(<Future<void>>[action, off]);

    final snoozeId = cycleReminderNotificationId(
      _userId,
      cycleReminderSnoozeSlot,
    );
    expect(state.events, contains('global-save-stale'));
    expect(service.cancelAllCalls, 1);
    expect(service.permissionRequests, 0);
    expect(service.exactRequests, 0);
    expect(gateway.cancelledIds.where((id) => id == snoozeId), hasLength(2));
    expect(state.activeIds, isNot(contains(snoozeId)));
    expect(lifecycle.cancelAllCalls, 0);
    expect((await store.load()).allNotifications, isFalse);
  });

  test(
    'action concorrente com save preserva recurring novo e remove slot 8',
    () async {
      final epoch = CycleReminderOperationEpoch();
      final generation = epoch.snapshot(_userId);
      final state = _NotificationState();
      final gateway = _GatedActionGateway(state)
        ..scheduleStarted = Completer<void>()
        ..allowSchedule = Completer<void>();
      final lifecycle = _SharedCycleLifecycle(state);
      final mutationGate = CycleReminderMutationGate();
      final service = _RecordingNotificationService(state);
      CycleReminderPreferences? persisted;
      final coordinator = _coordinator(
        epoch: epoch,
        gateway: gateway,
        lifecycle: lifecycle,
        loadGlobalNotifications: () async => true,
        preferences: _preferences(
          customTitle: 'Conteúdo antigo',
          customBody: 'Corpo antigo',
        ),
        mutationGate: mutationGate,
      );
      final controller = CycleReminderNotificationController(
        (preferences) async {
          state.events.add(
            epoch.isCurrent(_userId, generation)
                ? 'save-current'
                : 'save-stale',
          );
          persisted = preferences;
          return _userId;
        },
        () => _userId,
        () async => true,
        service,
        lifecycle,
        epoch,
        mutationGate,
      );
      await coordinator.onSessionPrepared(_userId);

      final action = coordinator.handle(_response());
      await gateway.scheduleStarted!.future;
      final updated = _preferences(
        customTitle: 'Conteúdo novo',
        customBody: 'Corpo novo',
      );
      final save = controller.save(updated);
      gateway.allowSchedule!.complete();
      await Future.wait<void>(<Future<void>>[action, save]);

      final snoozeId = cycleReminderNotificationId(
        _userId,
        cycleReminderSnoozeSlot,
      );
      final recurringIds = cycleReminderRecurringNotificationIds(_userId);
      expect(state.events, contains('save-stale'));
      expect(persisted, same(updated));
      expect(lifecycle.cancelAllCalls, 1);
      expect(lifecycle.rebuildCalls, 1);
      expect(state.activeIds, containsAll(recurringIds));
      expect(state.activeIds, isNot(contains(snoozeId)));
      expect(gateway.cancelledIds.where((id) => id == snoozeId), hasLength(2));
    },
  );

  test('restore posterior preserva snooze válido e reconstrói 0 a 7', () async {
    final epoch = CycleReminderOperationEpoch();
    final mutationGate = CycleReminderMutationGate();
    final state = _NotificationState();
    final gateway = _GatedActionGateway(state);
    final lifecycle = _SharedCycleLifecycle(state);
    final coordinator = _coordinator(
      epoch: epoch,
      gateway: gateway,
      lifecycle: lifecycle,
      loadGlobalNotifications: () async => true,
      mutationGate: mutationGate,
    );
    final reconciler = CycleReminderSessionReconciler(
      loadCyclePreferences: (_) async => _preferences(),
      loadGlobalNotifications: () async => true,
      currentUserId: () => _userId,
      lifecycle: lifecycle,
      operationEpoch: epoch,
      mutationGate: mutationGate,
    );
    await coordinator.onSessionPrepared(_userId);

    await coordinator.handle(_response());
    await reconciler.restoreForSession(_userId);

    final snoozeId = cycleReminderNotificationId(
      _userId,
      cycleReminderSnoozeSlot,
    );
    expect(state.activeIds, contains(snoozeId));
    expect(
      state.activeIds,
      containsAll(cycleReminderRecurringNotificationIds(_userId)),
    );
  });

  test('exceção no schedule libera gate para cleanup', () async {
    final epoch = CycleReminderOperationEpoch();
    final mutationGate = CycleReminderMutationGate();
    final state = _NotificationState();
    final gateway = _GatedActionGateway(state)..throwOnSchedule = true;
    final lifecycle = _SharedCycleLifecycle(state);
    final cleanup = CycleReminderSessionCleanup(mutationGate, lifecycle);
    final coordinator = _coordinator(
      epoch: epoch,
      gateway: gateway,
      lifecycle: lifecycle,
      loadGlobalNotifications: () async => true,
      mutationGate: mutationGate,
    );
    await coordinator.onSessionPrepared(_userId);

    await coordinator.handle(_response());
    coordinator.onSessionCleared();
    await expectLater(cleanup.cancelAfterCurrentMutations(_userId), completes);

    expect(lifecycle.cancelAllCalls, 1);
    expect(state.activeIds, isEmpty);
  });

  test('action A em gate não bloqueia save Cycle de B', () async {
    final epoch = CycleReminderOperationEpoch();
    final mutationGate = CycleReminderMutationGate();
    final state = _NotificationState();
    final gateway = _GatedActionGateway(state)
      ..scheduleStarted = Completer<void>()
      ..allowSchedule = Completer<void>();
    final lifecycle = _SharedCycleLifecycle(state);
    final coordinator = _coordinator(
      epoch: epoch,
      gateway: gateway,
      lifecycle: lifecycle,
      loadGlobalNotifications: () async => true,
      mutationGate: mutationGate,
    );
    final controllerB = CycleReminderNotificationController(
      (_) async => 'user-b',
      () => 'user-b',
      () async => true,
      _RecordingNotificationService(state),
      lifecycle,
      epoch,
      mutationGate,
    );
    await coordinator.onSessionPrepared(_userId);

    final actionA = coordinator.handle(_response());
    await gateway.scheduleStarted!.future;
    await controllerB.save(
      _preferences(customTitle: 'B', customBody: 'Lembrete B'),
    );

    expect(
      state.activeIds,
      containsAll(cycleReminderRecurringNotificationIds('user-b')),
    );
    gateway.allowSchedule!.complete();
    await actionA;
  });
}
