import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

abstract final class NotificationPreferenceKeys {
  static const allNotifications = 'all_notifications';
  static const studyReminders = 'study_reminders';
  static const habitReminders = 'habit_reminders';
  static const medicationReminders = 'medication_reminders';
}

class NotificationPreferences {
  const NotificationPreferences({
    required this.allNotifications,
    required this.studyReminders,
    required this.habitReminders,
    required this.medicationReminders,
  });

  const NotificationPreferences.enabled()
    : allNotifications = true,
      studyReminders = true,
      habitReminders = true,
      medicationReminders = true;

  final bool allNotifications;
  final bool studyReminders;
  final bool habitReminders;
  final bool medicationReminders;
}

class NotificationPreferencesStore {
  const NotificationPreferencesStore();

  Future<NotificationPreferences> load() async {
    final preferences = await SharedPreferences.getInstance();

    return NotificationPreferences(
      allNotifications:
          preferences.getBool(NotificationPreferenceKeys.allNotifications) ??
          true,
      studyReminders:
          preferences.getBool(NotificationPreferenceKeys.studyReminders) ??
          true,
      habitReminders:
          preferences.getBool(NotificationPreferenceKeys.habitReminders) ??
          true,
      medicationReminders:
          preferences.getBool(NotificationPreferenceKeys.medicationReminders) ??
          true,
    );
  }

  Future<void> save(String key, bool value) async {
    final preferences = await SharedPreferences.getInstance();
    final saved = await preferences.setBool(key, value);

    if (!saved) {
      throw StateError('Falha ao salvar preferência de notificação.');
    }
  }
}

final notificationPreferencesStoreProvider =
    Provider<NotificationPreferencesStore>((ref) {
      return const NotificationPreferencesStore();
    });
