import 'package:life_os/core/database/local_database_identity.dart';
import 'package:life_os/core/database/local_account_session.dart';
import 'package:life_os/core/storage/generational_local_store.dart';
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
  const NotificationPreferencesStore() : _scope = null;
  NotificationPreferencesStore.scoped(LocalDatabaseIdentity identity)
    : _scope = GenerationalLocalStore(
        identity: identity,
        domain: 'notification_preferences',
        read: (key) async {
          final p = await SharedPreferences.getInstance();
          await p.reload();
          return p.getString(key);
        },
        write: (key, value) async {
          if (!await (await SharedPreferences.getInstance()).setString(
            key,
            value,
          ))
            throw StateError('PREFERENCES_WRITE_UNKNOWN');
        },
        delete: (key) async {
          if (!await (await SharedPreferences.getInstance()).remove(key))
            throw StateError('PREFERENCES_DELETE_UNKNOWN');
        },
        listKeys: () async {
          final p = await SharedPreferences.getInstance();
          await p.reload();
          return p.getKeys();
        },
      );
  final GenerationalLocalStore? _scope;
  Future<void> retire() async {
    final scope = _scope;
    if (scope == null) throw StateError('LOCAL_GENERATION_BINDING_REQUIRED');
    await scope.retire();
  }

  Future<NotificationPreferences> load() async {
    final scope = _scope;
    if (scope != null) {
      Future<bool> read(String key) async {
        final value = await scope.read(key);
        if (value != null && value != 'true' && value != 'false')
          throw const FormatException('PREFERENCES_VALUE_INVALID');
        return value == null || value == 'true';
      }

      return NotificationPreferences(
        allNotifications: await read(
          NotificationPreferenceKeys.allNotifications,
        ),
        studyReminders: await read(NotificationPreferenceKeys.studyReminders),
        habitReminders: await read(NotificationPreferenceKeys.habitReminders),
        medicationReminders: await read(
          NotificationPreferenceKeys.medicationReminders,
        ),
      );
    }
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
    if (_scope != null) {
      if (!{
        NotificationPreferenceKeys.allNotifications,
        NotificationPreferenceKeys.studyReminders,
        NotificationPreferenceKeys.habitReminders,
        NotificationPreferenceKeys.medicationReminders,
      }.contains(key))
        throw ArgumentError('PREFERENCE_KEY_INVALID');
      await _scope.write(key, value.toString());
      return;
    }
    final preferences = await SharedPreferences.getInstance();
    final saved = await preferences.setBool(key, value);

    if (!saved) {
      throw StateError('Falha ao salvar preferência de notificação.');
    }
  }
}

final notificationPreferencesStoreProvider =
    Provider<NotificationPreferencesStore>((ref) {
      final identity = ref.watch(localAccountSessionProvider).identity;
      return identity == null
          ? const NotificationPreferencesStore()
          : NotificationPreferencesStore.scoped(identity);
    });
