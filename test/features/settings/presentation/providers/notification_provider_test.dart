import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/services/notification_preferences.dart';
import 'package:life_os/core/services/notification_service.dart';
import 'package:life_os/features/settings/presentation/providers/notification_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RecordingNotificationService extends NotificationService {
  int permissionRequests = 0;
  int cancelAllCalls = 0;

  @override
  Future<bool> requestPermissions({String? preferenceKey}) async {
    permissionRequests += 1;
    return true;
  }

  @override
  Future<void> cancelAllNotifications() async {
    cancelAllCalls += 1;
  }
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
    var refreshes = 0;
    final container = ProviderContainer(
      overrides: [
        notificationServiceProvider.overrideWithValue(service),
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
    expect(refreshes, 3);
    expect(service.cancelAllCalls, 1);
    expect(service.permissionRequests, 1);
  });

  test('toggle persiste e solicita reconcile sem reiniciar provider', () async {
    var refreshes = 0;
    final container = ProviderContainer(
      overrides: [
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
    expect(refreshes, 1);
  });
}
