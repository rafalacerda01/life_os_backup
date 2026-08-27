import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/core/services/notification_preferences.dart';
import 'package:life_os/core/services/notification_service.dart';
import 'package:life_os/features/health/presentation/cycle/cycle_reminder_notification_controller.dart';
import 'package:life_os/features/health/presentation/cycle/cycle_reminder_preferences.dart';
import 'package:life_os/features/health/services/cycle_reminder_mutation_gate.dart';
import 'package:life_os/features/health/services/cycle_reminder_notification_lifecycle.dart';
import 'package:life_os/features/health/services/cycle_reminder_operation_epoch.dart';
import 'package:life_os/features/health/services/cycle_reminder_session_authority.dart';
import 'package:life_os/features/health/services/cycle_reminder_session_reconciler.dart';
import 'package:life_os/features/health/services/cycle_reminder_session_cleanup.dart';
import 'package:life_os/features/health/services/medication_reminder_lifecycle.dart';
import 'package:life_os/features/settings/presentation/providers/notification_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _userA = 'user-a';
const String _userB = 'user-b';

class _MemoryCycleStorage implements CycleReminderPreferencesStorage {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

class _NotificationState {
  final Map<int, String> active = <int, String>{};
}

class _GatedCycleLifecycle implements CycleReminderNotificationLifecycle {
  _GatedCycleLifecycle(this.state);

  final _NotificationState state;
  Completer<void>? _rebuildStarted;
  Completer<void>? _allowRebuild;
  final List<String> cancelledUserIds = <String>[];
  int rebuildCalls = 0;

  void pauseNextRebuild() {
    _rebuildStarted = Completer<void>();
    _allowRebuild = Completer<void>();
  }

  Future<void> get rebuildStarted => _rebuildStarted!.future;

  void releaseRebuild() => _allowRebuild!.complete();

  @override
  Future<int> cancelAllCycleReminders(String userId) async {
    cancelledUserIds.add(userId);
    state.active.removeWhere(
      (id, _) => cycleReminderNotificationIds(userId).contains(id),
    );
    return 0;
  }

  @override
  Future<CycleReminderRebuildResult> rebuildCycleReminders(
    String userId,
    CycleReminderPreferences preferences, {
    CycleReminderRebuildGuard? shouldContinue,
  }) async {
    rebuildCalls += 1;
    final recurringIds = cycleReminderRecurringNotificationIds(userId);
    state.active.removeWhere((id, _) => recurringIds.contains(id));
    if (shouldContinue?.call() == false) {
      return const CycleReminderRebuildResult(
        eligible: 1,
        scheduled: 0,
        failed: 0,
        cancellationFailed: 0,
      );
    }

    final started = _rebuildStarted;
    final allow = _allowRebuild;
    if (started != null && allow != null) {
      started.complete();
      await allow.future;
      _rebuildStarted = null;
      _allowRebuild = null;
    }

    final id = cycleReminderNotificationId(userId, 0);
    state.active[id] = preferences.customTitle.isEmpty
        ? '${preferences.hour}:${preferences.minute}'
        : preferences.customTitle;
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

  @override
  Future<void> cancelAllNotifications() async {
    state.active.clear();
  }

  @override
  Future<bool> requestPermissions({String? preferenceKey}) async => true;

  @override
  Future<bool> requestExactAlarmPermission() async => true;
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

CycleReminderPreferences _preferences(String label) {
  return CycleReminderPreferences(
    enabled: true,
    type: CycleReminderType.personal,
    hour: 9,
    minute: 30,
    frequency: CycleReminderFrequency.daily,
    privacyMode: CycleReminderPrivacyMode.custom,
    customTitle: label,
    customBody: 'Corpo $label',
  );
}

ProviderContainer _notificationContainer({
  required _NotificationState state,
  required _GatedCycleLifecycle lifecycle,
  required CycleReminderPreferencesStore cycleStore,
  required CycleReminderOperationEpoch epoch,
  required CycleReminderMutationGate mutationGate,
  String? Function()? currentUserId,
}) {
  return ProviderContainer(
    overrides: [
      notificationServiceProvider.overrideWithValue(
        _RecordingNotificationService(state),
      ),
      medicationReminderLifecycleProvider.overrideWithValue(
        _NoopMedicationLifecycle(),
      ),
      cycleReminderNotificationLifecycleProvider.overrideWithValue(lifecycle),
      cycleReminderPreferencesStoreProvider.overrideWithValue(cycleStore),
      cycleReminderUserIdReaderProvider.overrideWithValue(
        currentUserId ?? () => _userA,
      ),
      cycleReminderOperationEpochProvider.overrideWithValue(epoch),
      cycleReminderMutationGateProvider.overrideWithValue(mutationGate),
      notificationPreferencesChangedProvider.overrideWithValue(() {}),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{
      NotificationPreferenceKeys.allNotifications: true,
      NotificationPreferenceKeys.medicationReminders: false,
    });
  });

  test('restore em voo não recria recurring depois do global OFF', () async {
    final state = _NotificationState();
    final lifecycle = _GatedCycleLifecycle(state)..pauseNextRebuild();
    final epoch = CycleReminderOperationEpoch();
    final mutationGate = CycleReminderMutationGate();
    final cycleStore = CycleReminderPreferencesStore(_MemoryCycleStorage());
    await cycleStore.save(_userA, _preferences('antiga'));
    final reconciler = CycleReminderSessionReconciler(
      loadCyclePreferences: cycleStore.load,
      loadGlobalNotifications: () async {
        return (await const NotificationPreferencesStore().load())
            .allNotifications;
      },
      currentUserId: () => _userA,
      lifecycle: lifecycle,
      operationEpoch: epoch,
      mutationGate: mutationGate,
    );
    final container = _notificationContainer(
      state: state,
      lifecycle: lifecycle,
      cycleStore: cycleStore,
      epoch: epoch,
      mutationGate: mutationGate,
    );
    addTearDown(container.dispose);
    await container.read(notificationsProvider.future);

    final restore = reconciler.restoreForSession(_userA);
    await lifecycle.rebuildStarted;
    final off = container.read(notificationsProvider.notifier).toggleAll(false);
    final offCompleted = Completer<void>();
    off.then((_) => offCompleted.complete());
    await Future<void>.value();
    expect(offCompleted.isCompleted, isFalse);
    expect(
      (await const NotificationPreferencesStore().load()).allNotifications,
      isFalse,
    );

    lifecycle.releaseRebuild();
    await Future.wait(<Future<void>>[restore, off]);

    expect(state.active, isEmpty);
    expect(
      (await const NotificationPreferencesStore().load()).allNotifications,
      isFalse,
    );
  });

  test('save em voo não recria Cycle depois do global OFF', () async {
    final state = _NotificationState();
    final lifecycle = _GatedCycleLifecycle(state)..pauseNextRebuild();
    final epoch = CycleReminderOperationEpoch();
    final mutationGate = CycleReminderMutationGate();
    final cycleStore = CycleReminderPreferencesStore(_MemoryCycleStorage());
    final controller = CycleReminderNotificationController(
      (preferences) async {
        await cycleStore.save(_userA, preferences);
        return _userA;
      },
      () => _userA,
      () async => true,
      _RecordingNotificationService(state),
      lifecycle,
      epoch,
      mutationGate,
    );
    final container = _notificationContainer(
      state: state,
      lifecycle: lifecycle,
      cycleStore: cycleStore,
      epoch: epoch,
      mutationGate: mutationGate,
    );
    addTearDown(container.dispose);
    await container.read(notificationsProvider.future);

    final save = controller.save(_preferences('save antiga'));
    await lifecycle.rebuildStarted;
    final off = container.read(notificationsProvider.notifier).toggleAll(false);

    lifecycle.releaseRebuild();
    await Future.wait(<Future<void>>[save, off]);

    expect(state.active, isEmpty);
  });

  test('save antigo em voo não vence save mais novo', () async {
    final state = _NotificationState();
    final lifecycle = _GatedCycleLifecycle(state)..pauseNextRebuild();
    final epoch = CycleReminderOperationEpoch();
    final mutationGate = CycleReminderMutationGate();
    final cycleStore = CycleReminderPreferencesStore(_MemoryCycleStorage());
    final controller = CycleReminderNotificationController(
      (preferences) async {
        await cycleStore.save(_userA, preferences);
        return _userA;
      },
      () => _userA,
      () async => true,
      _RecordingNotificationService(state),
      lifecycle,
      epoch,
      mutationGate,
    );

    final oldSave = controller.save(_preferences('antiga'));
    await lifecycle.rebuildStarted;
    final newSave = controller.save(_preferences('nova'));

    lifecycle.releaseRebuild();
    await Future.wait(<Future<void>>[oldSave, newSave]);

    final recurringId = cycleReminderNotificationId(_userA, 0);
    expect(state.active, <int, String>{recurringId: 'nova'});
    expect((await cycleStore.load(_userA))?.customTitle, 'nova');
  });

  test('restore antigo não vence save com configuração nova', () async {
    final state = _NotificationState();
    final lifecycle = _GatedCycleLifecycle(state)..pauseNextRebuild();
    final epoch = CycleReminderOperationEpoch();
    final mutationGate = CycleReminderMutationGate();
    final cycleStore = CycleReminderPreferencesStore(_MemoryCycleStorage());
    await cycleStore.save(_userA, _preferences('antiga'));
    final reconciler = CycleReminderSessionReconciler(
      loadCyclePreferences: cycleStore.load,
      loadGlobalNotifications: () async => true,
      currentUserId: () => _userA,
      lifecycle: lifecycle,
      operationEpoch: epoch,
      mutationGate: mutationGate,
    );
    final controller = CycleReminderNotificationController(
      (preferences) async {
        await cycleStore.save(_userA, preferences);
        return _userA;
      },
      () => _userA,
      () async => true,
      _RecordingNotificationService(state),
      lifecycle,
      epoch,
      mutationGate,
    );

    final restore = reconciler.restoreForSession(_userA);
    await lifecycle.rebuildStarted;
    final save = controller.save(_preferences('nova'));
    lifecycle.releaseRebuild();
    await Future.wait(<Future<void>>[restore, save]);

    final recurringId = cycleReminderNotificationId(_userA, 0);
    expect(state.active, <int, String>{recurringId: 'nova'});
    expect((await cycleStore.load(_userA))?.customTitle, 'nova');
  });

  test('OFF ON em voo OFF termina com zero Cycle ativo', () async {
    final state = _NotificationState();
    final lifecycle = _GatedCycleLifecycle(state);
    final epoch = CycleReminderOperationEpoch();
    final mutationGate = CycleReminderMutationGate();
    final cycleStore = CycleReminderPreferencesStore(_MemoryCycleStorage());
    await cycleStore.save(_userA, _preferences('atual'));
    final container = _notificationContainer(
      state: state,
      lifecycle: lifecycle,
      cycleStore: cycleStore,
      epoch: epoch,
      mutationGate: mutationGate,
    );
    addTearDown(container.dispose);
    await container.read(notificationsProvider.future);

    await container.read(notificationsProvider.notifier).toggleAll(false);
    lifecycle.pauseNextRebuild();
    final on = container.read(notificationsProvider.notifier).toggleAll(true);
    await lifecycle.rebuildStarted;
    final finalOff = container
        .read(notificationsProvider.notifier)
        .toggleAll(false);

    lifecycle.releaseRebuild();
    await Future.wait(<Future<void>>[on, finalOff]);

    expect(state.active, isEmpty);
    expect(
      (await const NotificationPreferencesStore().load()).allNotifications,
      isFalse,
    );
  });

  test('operação longa de A não bloqueia UID B', () async {
    final gate = CycleReminderMutationGate();
    final startedA = Completer<void>();
    final releaseA = Completer<void>();
    final completedB = Completer<void>();

    final operationA = gate.run(_userA, () async {
      startedA.complete();
      await releaseA.future;
    });
    await startedA.future;
    final operationB = gate.run(_userB, () async {
      completedB.complete();
    });
    await completedB.future;
    expect(releaseA.isCompleted, isFalse);

    releaseA.complete();
    await Future.wait(<Future<void>>[operationA, operationB]);
  });

  test('exceção libera próxima operação do mesmo UID', () async {
    final gate = CycleReminderMutationGate();

    await expectLater(
      gate.run<void>(_userA, () async {
        throw StateError('private failure');
      }),
      throwsStateError,
    );
    await expectLater(gate.run<void>(_userA, () async {}), completes);
  });

  test(
    'logout espera rebuild em voo e termina com slots 0 a 8 cancelados',
    () async {
      final state = _NotificationState();
      final lifecycle = _GatedCycleLifecycle(state)..pauseNextRebuild();
      final epoch = CycleReminderOperationEpoch();
      final mutationGate = CycleReminderMutationGate();
      final cleanup = CycleReminderSessionCleanup(mutationGate, lifecycle);
      final reconciler = CycleReminderSessionReconciler(
        loadCyclePreferences: (_) async => _preferences('antiga'),
        loadGlobalNotifications: () async => true,
        currentUserId: () => _userA,
        lifecycle: lifecycle,
        operationEpoch: epoch,
        mutationGate: mutationGate,
      );
      state.active[cycleReminderNotificationId(
            _userA,
            cycleReminderSnoozeSlot,
          )] =
          'snooze antigo';

      final rebuild = reconciler.restoreForSession(_userA);
      await lifecycle.rebuildStarted;

      epoch.invalidate(_userA);
      final finalCancel = cleanup.cancelAfterCurrentMutations(_userA);
      var cleanupCompleted = false;
      final trackedCleanup = finalCancel.whenComplete(() {
        cleanupCompleted = true;
      });
      await Future<void>.value();

      expect(cleanupCompleted, isFalse);
      expect(lifecycle.cancelledUserIds, isEmpty);

      lifecycle.releaseRebuild();
      await Future.wait<void>(<Future<void>>[rebuild, trackedCleanup]);

      expect(lifecycle.cancelledUserIds, <String>[_userA]);
      expect(
        cycleReminderNotificationIds(_userA).where(state.active.containsKey),
        isEmpty,
      );
    },
  );

  test(
    'save iniciado após clear não entra atrás do cleanup nem recria Cycle',
    () async {
      final state = _NotificationState();
      final lifecycle = _GatedCycleLifecycle(state);
      final epoch = CycleReminderOperationEpoch();
      final mutationGate = CycleReminderMutationGate();
      final cleanup = CycleReminderSessionCleanup(mutationGate, lifecycle);
      final authority = CycleReminderSessionAuthority()..prepare(_userA);
      const firebaseUserId = _userA;
      var persistCalls = 0;
      final controller = CycleReminderNotificationController(
        (_) async {
          persistCalls += 1;
          return _userA;
        },
        () => authority.admittedUserId(firebaseUserId),
        () async => true,
        _RecordingNotificationService(state),
        lifecycle,
        epoch,
        mutationGate,
      );
      for (final id in cycleReminderNotificationIds(_userA)) {
        state.active[id] = 'ativo';
      }
      final oldProducerStarted = Completer<void>();
      final releaseOldProducer = Completer<void>();
      final oldProducer = mutationGate.run(_userA, () async {
        oldProducerStarted.complete();
        await releaseOldProducer.future;
      });
      await oldProducerStarted.future;

      authority.clear();
      epoch.invalidate(_userA);
      final generationAfterClear = epoch.snapshot(_userA);
      final finalCleanup = cleanup.cancelAfterCurrentMutations(_userA);

      await expectLater(
        controller.save(_preferences('novo save')),
        throwsA(isA<StateError>()),
      );
      expect(persistCalls, 0);
      expect(epoch.snapshot(_userA), generationAfterClear);

      releaseOldProducer.complete();
      await Future.wait<void>(<Future<void>>[oldProducer, finalCleanup]);

      expect(
        cycleReminderNotificationIds(_userA).where(state.active.containsKey),
        isEmpty,
      );
      expect(lifecycle.cancelledUserIds, <String>[_userA]);
    },
  );

  test(
    'rebuild aguardando gate observa epoch stale antes do cancel final',
    () async {
      final state = _NotificationState();
      final lifecycle = _GatedCycleLifecycle(state);
      final epoch = CycleReminderOperationEpoch();
      final mutationGate = CycleReminderMutationGate();
      final cleanup = CycleReminderSessionCleanup(mutationGate, lifecycle);
      final reconciler = CycleReminderSessionReconciler(
        loadCyclePreferences: (_) async => _preferences('antiga'),
        loadGlobalNotifications: () async => true,
        currentUserId: () => _userA,
        lifecycle: lifecycle,
        operationEpoch: epoch,
        mutationGate: mutationGate,
      );
      final blockerStarted = Completer<void>();
      final releaseBlocker = Completer<void>();
      final blocker = mutationGate.run(_userA, () async {
        blockerStarted.complete();
        await releaseBlocker.future;
      });
      await blockerStarted.future;

      final rebuild = reconciler.restoreForSession(_userA);
      epoch.invalidate(_userA);
      final finalCancel = cleanup.cancelAfterCurrentMutations(_userA);

      releaseBlocker.complete();
      await Future.wait<void>(<Future<void>>[blocker, rebuild, finalCancel]);

      expect(lifecycle.rebuildCalls, 0);
      expect(lifecycle.cancelledUserIds, <String>[_userA]);
      expect(state.active, isEmpty);
    },
  );

  test('cleanup completo de A não cancela rebuild posterior de B', () async {
    final state = _NotificationState();
    final lifecycle = _GatedCycleLifecycle(state)..pauseNextRebuild();
    final epoch = CycleReminderOperationEpoch();
    final mutationGate = CycleReminderMutationGate();
    final cleanup = CycleReminderSessionCleanup(mutationGate, lifecycle);
    var currentUserId = _userA;
    final reconciler = CycleReminderSessionReconciler(
      loadCyclePreferences: (userId) async => _preferences(userId),
      loadGlobalNotifications: () async => true,
      currentUserId: () => currentUserId,
      lifecycle: lifecycle,
      operationEpoch: epoch,
      mutationGate: mutationGate,
    );

    final oldRebuild = reconciler.restoreForSession(_userA);
    await lifecycle.rebuildStarted;
    epoch.invalidate(_userA);
    final oldCleanup = cleanup.cancelAfterCurrentMutations(_userA);
    lifecycle.releaseRebuild();
    await Future.wait<void>(<Future<void>>[oldRebuild, oldCleanup]);

    currentUserId = _userB;
    await reconciler.restoreForSession(_userB);

    expect(
      cycleReminderNotificationIds(_userA).where(state.active.containsKey),
      isEmpty,
    );
    expect(state.active[cycleReminderNotificationId(_userB, 0)], _userB);
  });
}
