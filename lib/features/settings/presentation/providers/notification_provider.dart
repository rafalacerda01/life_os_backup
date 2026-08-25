import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/core/services/notification_preferences.dart';
import 'package:life_os/core/services/notification_service.dart';
import 'package:life_os/features/notifications/domain/providers/notification_engine.dart';

final notificationServiceProvider = Provider<NotificationService>((ref) {
  return NotificationService.instance;
});

final notificationPreferencesChangedProvider = Provider<void Function()>((ref) {
  return () => ref.invalidate(notificationEngineProvider);
});

class NotificationsNotifier extends AsyncNotifier<NotificationPreferences> {
  NotificationPreferencesStore get _store =>
      ref.read(notificationPreferencesStoreProvider);

  @override
  Future<NotificationPreferences> build() => _store.load();

  Future<void> toggleAll(bool value) async {
    state.requireValue;
    final store = _store;
    final notificationService = ref.read(notificationServiceProvider);
    final refresh = ref.read(notificationPreferencesChangedProvider);

    await store.save(NotificationPreferenceKeys.allNotifications, value);
    final updated = await store.load();
    if (!ref.mounted) return;

    state = AsyncData(updated);
    refresh();

    if (value) {
      await notificationService.requestPermissions();
    } else {
      await notificationService.cancelAllNotifications();
    }
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
    await _toggleCategory(
      key: NotificationPreferenceKeys.medicationReminders,
      value: value,
    );
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
