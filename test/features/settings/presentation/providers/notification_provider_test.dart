import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/services/notification_preferences.dart';
import 'package:life_os/core/services/notification_service.dart';
import 'package:life_os/features/health/presentation/cycle/cycle_reminder_preferences.dart';
import 'package:life_os/features/health/services/cycle_reminder_notification_lifecycle.dart';
import 'package:life_os/features/health/services/cycle_reminder_operation_epoch.dart';
import 'package:life_os/features/health/services/cycle_reminder_session_authority.dart';
import 'package:life_os/features/health/services/medication_reminder_lifecycle.dart';
import 'package:life_os/features/settings/presentation/providers/notification_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RecordingNotificationService extends NotificationService {
  int permissionRequests = 0;
  int exactPermissionRequests = 0;
  int cancelAllCalls = 0;
  bool permissionGranted = true;
  String? lastPreferenceKey;

  @override
  Future<bool> requestPermissions({String? preferenceKey}) async {
    permissionRequests += 1;
    lastPreferenceKey = preferenceKey;
    return permissionGranted;
  }

  @override
  Future<bool> requestExactAlarmPermission() async {
    exactPermissionRequests += 1;
    return false;
  }

  @override
  Future<void> cancelAllNotifications() async {
    cancelAllCalls += 1;
  }
}

class _RecordingMedicationLifecycle implements MedicationReminderLifecycle {
  int cancelCalls = 0;
  int rebuildCalls = 0;

  @override
  Future<void> cancelAllMedicationReminders() async {
    cancelCalls += 1;
  }

  @override
  Future<MedicationReminderRebuildResult> rebuildMedicationReminders() async {
    rebuildCalls += 1;
    return const MedicationReminderRebuildResult(
      eligible: 1,
      scheduled: 1,
      failed: 0,
    );
  }
}

class _MemoryCycleReminderStorage implements CycleReminderPreferencesStorage {
  final Map<String, String> values = <String, String>{};

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

class _RecordingCycleLifecycle implements CycleReminderNotificationLifecycle {
  int cancelCalls = 0;
  int rebuildCalls = 0;
  String? lastUserId;
  CycleReminderPreferences? lastPreferences;

  @override
  Future<int> cancelAllCycleReminders(String userId) async {
    cancelCalls += 1;
    lastUserId = userId;
    return 0;
  }

  @override
  Future<CycleReminderRebuildResult> rebuildCycleReminders(
    String userId,
    CycleReminderPreferences preferences, {
    CycleReminderRebuildGuard? shouldContinue,
  }) async {
    rebuildCalls += 1;
    lastUserId = userId;
    lastPreferences = preferences;
    return const CycleReminderRebuildResult(
      eligible: 1,
      scheduled: 1,
      failed: 0,
      cancellationFailed: 0,
    );
  }
}

CycleReminderPreferences _cyclePreferences({bool enabled = true}) {
  return CycleReminderPreferences(
    enabled: enabled,
    type: CycleReminderType.personal,
    hour: 9,
    minute: 30,
    frequency: CycleReminderFrequency.daily,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('store carrega as quatro preferências persistidas', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      NotificationPreferenceKeys.allNotifications: false,
      NotificationPreferenceKeys.studyReminders: false,
      NotificationPreferenceKeys.habitReminders: true,
      NotificationPreferenceKeys.medicationReminders: false,
    });

    final result = await const NotificationPreferencesStore().load();

    expect(result.allNotifications, isFalse);
    expect(result.studyReminders, isFalse);
    expect(result.habitReminders, isTrue);
    expect(result.medicationReminders, isFalse);
  });

  test(
    'provider permanece loading até conhecer preferências persistidas',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        NotificationPreferenceKeys.allNotifications: false,
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(notificationsProvider), isA<AsyncLoading>());

      final result = await container.read(notificationsProvider.future);
      expect(result.allNotifications, isFalse);
    },
  );

  test('preferência individual sobrevive a all off e all on', () async {
    final service = _RecordingNotificationService();
    final lifecycle = _RecordingMedicationLifecycle();
    var refreshes = 0;
    final container = ProviderContainer(
      overrides: [
        notificationServiceProvider.overrideWithValue(service),
        medicationReminderLifecycleProvider.overrideWithValue(lifecycle),
        notificationPreferencesChangedProvider.overrideWithValue(
          () => refreshes += 1,
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(notificationsProvider.future);
    final notifier = container.read(notificationsProvider.notifier);

    await notifier.toggleStudy(false);
    await notifier.toggleAll(false);
    await notifier.toggleAll(true);

    final state = container.read(notificationsProvider).requireValue;
    final stored = await const NotificationPreferencesStore().load();
    expect(state.studyReminders, isFalse);
    expect(stored.studyReminders, isFalse);
    expect(state.allNotifications, isTrue);
    expect(state.medicationReminders, isTrue);
    expect(state.habitReminders, isTrue);
    expect(refreshes, 3);
    expect(service.cancelAllCalls, 1);
    expect(service.permissionRequests, 1);
    expect(service.exactPermissionRequests, 1);
    expect(lifecycle.rebuildCalls, 1);
  });

  test('toggle persiste e solicita reconcile sem reiniciar provider', () async {
    final service = _RecordingNotificationService();
    final lifecycle = _RecordingMedicationLifecycle();
    var refreshes = 0;
    final container = ProviderContainer(
      overrides: [
        notificationServiceProvider.overrideWithValue(service),
        medicationReminderLifecycleProvider.overrideWithValue(lifecycle),
        notificationPreferencesChangedProvider.overrideWithValue(
          () => refreshes += 1,
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(notificationsProvider.future);

    await container
        .read(notificationsProvider.notifier)
        .toggleMedication(false);

    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.getBool(NotificationPreferenceKeys.medicationReminders),
      isFalse,
    );
    expect(
      container.read(notificationsProvider).requireValue.medicationReminders,
      isFalse,
    );
    expect(
      container.read(notificationsProvider).requireValue.studyReminders,
      isTrue,
    );
    expect(
      container.read(notificationsProvider).requireValue.habitReminders,
      isTrue,
    );
    expect(refreshes, 1);
    expect(lifecycle.cancelCalls, 1);
    expect(service.cancelAllCalls, 0);
  });

  test('toggle medication on pede permissões, rebuild e reconcile', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      NotificationPreferenceKeys.allNotifications: true,
      NotificationPreferenceKeys.medicationReminders: false,
    });
    final service = _RecordingNotificationService();
    final lifecycle = _RecordingMedicationLifecycle();
    var refreshes = 0;
    final container = ProviderContainer(
      overrides: [
        notificationServiceProvider.overrideWithValue(service),
        medicationReminderLifecycleProvider.overrideWithValue(lifecycle),
        notificationPreferencesChangedProvider.overrideWithValue(
          () => refreshes += 1,
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(notificationsProvider.future);

    await container.read(notificationsProvider.notifier).toggleMedication(true);

    expect(service.permissionRequests, 1);
    expect(
      service.lastPreferenceKey,
      NotificationPreferenceKeys.medicationReminders,
    );
    expect(service.exactPermissionRequests, 1);
    expect(lifecycle.rebuildCalls, 1);
    expect(refreshes, 1);
  });

  test('permissão normal negada não pede exact nem executa rebuild', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      NotificationPreferenceKeys.allNotifications: true,
      NotificationPreferenceKeys.medicationReminders: false,
    });
    final service = _RecordingNotificationService()..permissionGranted = false;
    final lifecycle = _RecordingMedicationLifecycle();
    final container = ProviderContainer(
      overrides: [
        notificationServiceProvider.overrideWithValue(service),
        medicationReminderLifecycleProvider.overrideWithValue(lifecycle),
      ],
    );
    addTearDown(container.dispose);
    await container.read(notificationsProvider.future);

    await container.read(notificationsProvider.notifier).toggleMedication(true);

    expect(
      container.read(notificationsProvider).requireValue.medicationReminders,
      isTrue,
    );
    expect(service.exactPermissionRequests, 0);
    expect(lifecycle.rebuildCalls, 0);
  });

  test('exact negado não impede rebuild após ação explícita', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      NotificationPreferenceKeys.allNotifications: true,
      NotificationPreferenceKeys.medicationReminders: false,
    });
    final service = _RecordingNotificationService();
    final lifecycle = _RecordingMedicationLifecycle();
    final container = ProviderContainer(
      overrides: [
        notificationServiceProvider.overrideWithValue(service),
        medicationReminderLifecycleProvider.overrideWithValue(lifecycle),
      ],
    );
    addTearDown(container.dispose);
    await container.read(notificationsProvider.future);

    await container.read(notificationsProvider.notifier).toggleMedication(true);

    expect(service.exactPermissionRequests, 1);
    expect(lifecycle.rebuildCalls, 1);
  });

  test('toggle all on não reconstrói quando medication está false', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      NotificationPreferenceKeys.allNotifications: false,
      NotificationPreferenceKeys.medicationReminders: false,
    });
    final service = _RecordingNotificationService();
    final lifecycle = _RecordingMedicationLifecycle();
    final container = ProviderContainer(
      overrides: [
        notificationServiceProvider.overrideWithValue(service),
        medicationReminderLifecycleProvider.overrideWithValue(lifecycle),
      ],
    );
    addTearDown(container.dispose);
    await container.read(notificationsProvider.future);

    await container.read(notificationsProvider.notifier).toggleAll(true);

    expect(service.permissionRequests, 1);
    expect(service.exactPermissionRequests, 0);
    expect(lifecycle.rebuildCalls, 0);
    expect(
      container.read(notificationsProvider).requireValue.medicationReminders,
      isFalse,
    );
  });

  test(
    'toggle all on reconstrói cycle habilitado para usuário atual',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        NotificationPreferenceKeys.allNotifications: false,
        NotificationPreferenceKeys.medicationReminders: false,
      });
      final service = _RecordingNotificationService();
      final medicationLifecycle = _RecordingMedicationLifecycle();
      final cycleLifecycle = _RecordingCycleLifecycle();
      final cycleStore = CycleReminderPreferencesStore(
        _MemoryCycleReminderStorage(),
      );
      await cycleStore.save('user-a', _cyclePreferences());
      final container = ProviderContainer(
        overrides: [
          notificationServiceProvider.overrideWithValue(service),
          medicationReminderLifecycleProvider.overrideWithValue(
            medicationLifecycle,
          ),
          cycleReminderNotificationLifecycleProvider.overrideWithValue(
            cycleLifecycle,
          ),
          cycleReminderPreferencesStoreProvider.overrideWithValue(cycleStore),
          cycleReminderUserIdReaderProvider.overrideWithValue(() => 'user-a'),
        ],
      );
      addTearDown(container.dispose);
      await container.read(notificationsProvider.future);

      await container.read(notificationsProvider.notifier).toggleAll(true);

      expect(service.permissionRequests, 1);
      expect(service.exactPermissionRequests, 1);
      expect(medicationLifecycle.rebuildCalls, 0);
      expect(cycleLifecycle.rebuildCalls, 1);
      expect(cycleLifecycle.lastUserId, 'user-a');
      expect(cycleLifecycle.lastPreferences?.enabled, isTrue);
    },
  );

  test('toggle all on não reconstrói cycle desabilitado', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      NotificationPreferenceKeys.allNotifications: false,
      NotificationPreferenceKeys.medicationReminders: false,
    });
    final service = _RecordingNotificationService();
    final cycleLifecycle = _RecordingCycleLifecycle();
    final cycleStore = CycleReminderPreferencesStore(
      _MemoryCycleReminderStorage(),
    );
    await cycleStore.save('user-a', _cyclePreferences(enabled: false));
    final container = ProviderContainer(
      overrides: [
        notificationServiceProvider.overrideWithValue(service),
        medicationReminderLifecycleProvider.overrideWithValue(
          _RecordingMedicationLifecycle(),
        ),
        cycleReminderNotificationLifecycleProvider.overrideWithValue(
          cycleLifecycle,
        ),
        cycleReminderPreferencesStoreProvider.overrideWithValue(cycleStore),
        cycleReminderUserIdReaderProvider.overrideWithValue(() => 'user-a'),
      ],
    );
    addTearDown(container.dispose);
    await container.read(notificationsProvider.future);

    await container.read(notificationsProvider.notifier).toggleAll(true);

    expect(service.permissionRequests, 1);
    expect(service.exactPermissionRequests, 0);
    expect(cycleLifecycle.rebuildCalls, 0);
  });

  test('toggle all on não reconstrói cycle inexistente', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      NotificationPreferenceKeys.allNotifications: false,
      NotificationPreferenceKeys.medicationReminders: false,
    });
    final service = _RecordingNotificationService();
    final cycleLifecycle = _RecordingCycleLifecycle();
    final container = ProviderContainer(
      overrides: [
        notificationServiceProvider.overrideWithValue(service),
        medicationReminderLifecycleProvider.overrideWithValue(
          _RecordingMedicationLifecycle(),
        ),
        cycleReminderNotificationLifecycleProvider.overrideWithValue(
          cycleLifecycle,
        ),
        cycleReminderPreferencesStoreProvider.overrideWithValue(
          CycleReminderPreferencesStore(_MemoryCycleReminderStorage()),
        ),
        cycleReminderUserIdReaderProvider.overrideWithValue(() => 'user-a'),
      ],
    );
    addTearDown(container.dispose);
    await container.read(notificationsProvider.future);

    await container.read(notificationsProvider.notifier).toggleAll(true);

    expect(service.exactPermissionRequests, 0);
    expect(cycleLifecycle.rebuildCalls, 0);
  });

  test('toggle all on sem usuário não agenda cycle', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      NotificationPreferenceKeys.allNotifications: false,
      NotificationPreferenceKeys.medicationReminders: false,
    });
    final service = _RecordingNotificationService();
    final cycleLifecycle = _RecordingCycleLifecycle();
    final container = ProviderContainer(
      overrides: [
        notificationServiceProvider.overrideWithValue(service),
        medicationReminderLifecycleProvider.overrideWithValue(
          _RecordingMedicationLifecycle(),
        ),
        cycleReminderNotificationLifecycleProvider.overrideWithValue(
          cycleLifecycle,
        ),
        cycleReminderPreferencesStoreProvider.overrideWithValue(
          CycleReminderPreferencesStore(_MemoryCycleReminderStorage()),
        ),
        cycleReminderUserIdReaderProvider.overrideWithValue(() => null),
      ],
    );
    addTearDown(container.dispose);
    await container.read(notificationsProvider.future);

    await container.read(notificationsProvider.notifier).toggleAll(true);

    expect(service.permissionRequests, 1);
    expect(service.exactPermissionRequests, 0);
    expect(cycleLifecycle.rebuildCalls, 0);
  });

  test(
    'toggle global após clear persiste geral sem admitir mutação Cycle',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        NotificationPreferenceKeys.allNotifications: false,
        NotificationPreferenceKeys.medicationReminders: false,
      });
      final service = _RecordingNotificationService();
      final cycleLifecycle = _RecordingCycleLifecycle();
      final cycleStore = CycleReminderPreferencesStore(
        _MemoryCycleReminderStorage(),
      );
      await cycleStore.save('user-a', _cyclePreferences());
      final sessionAuthority = CycleReminderSessionAuthority()
        ..prepare('user-a');
      String? firebaseUserId = 'user-a';
      sessionAuthority.clear();
      final operationEpoch = CycleReminderOperationEpoch();
      final generation = operationEpoch.snapshot('user-a');
      final container = ProviderContainer(
        overrides: [
          notificationServiceProvider.overrideWithValue(service),
          medicationReminderLifecycleProvider.overrideWithValue(
            _RecordingMedicationLifecycle(),
          ),
          cycleReminderNotificationLifecycleProvider.overrideWithValue(
            cycleLifecycle,
          ),
          cycleReminderPreferencesStoreProvider.overrideWithValue(cycleStore),
          cycleReminderOperationEpochProvider.overrideWithValue(operationEpoch),
          cycleReminderUserIdReaderProvider.overrideWithValue(
            () => sessionAuthority.admittedUserId(firebaseUserId),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(notificationsProvider.future);

      await container.read(notificationsProvider.notifier).toggleAll(true);

      expect(
        (await const NotificationPreferencesStore().load()).allNotifications,
        isTrue,
      );
      expect(cycleLifecycle.rebuildCalls, 0);
      expect(cycleLifecycle.cancelCalls, 0);
      expect(operationEpoch.snapshot('user-a'), generation);
      expect(firebaseUserId, 'user-a');
    },
  );
}
