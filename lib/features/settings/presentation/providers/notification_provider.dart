import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:life_os/core/services/notification_service.dart';

class NotificationsState {
  final bool allNotifications;
  final bool ankiReminders;
  final bool focusAlerts;
  final bool medicationReminders;

  NotificationsState({
    this.allNotifications = true,
    this.ankiReminders = true,
    this.focusAlerts = true,
    this.medicationReminders = true,
  });

  NotificationsState copyWith({
    bool? allNotifications,
    bool? ankiReminders,
    bool? focusAlerts,
    bool? medicationReminders,
  }) {
    return NotificationsState(
      allNotifications: allNotifications ?? this.allNotifications,
      ankiReminders: ankiReminders ?? this.ankiReminders,
      focusAlerts: focusAlerts ?? this.focusAlerts,
      medicationReminders: medicationReminders ?? this.medicationReminders,
    );
  }
}

class NotificationsNotifier extends Notifier<NotificationsState> {
  static const _keyAll = 'all_notifications';
  static const _keyAnki = 'anki_reminders';
  static const _keyFocus = 'focus_alerts';
  static const _keyMedication = 'medication_reminders';

  final NotificationService _notificationService = NotificationService();

  @override
  NotificationsState build() {
    _initAndLoad();
    return NotificationsState();
  }

  Future<void> _initAndLoad() async {
    await _notificationService.init();
    final prefs = await SharedPreferences.getInstance();

    state = NotificationsState(
      allNotifications: prefs.getBool(_keyAll) ?? true,
      ankiReminders: prefs.getBool(_keyAnki) ?? true,
      focusAlerts: prefs.getBool(_keyFocus) ?? true,
      medicationReminders: prefs.getBool(_keyMedication) ?? true,
    );
  }

  Future<void> _savePreference(String key, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
  }

  Future<void> toggleAll(bool value) async {
    await _savePreference(_keyAll, value);
    state = state.copyWith(allNotifications: value);

    if (value) {
      // Solicita as permissões do Android 13+ / iOS apenas quando o usuário ativa
      await _notificationService.requestPermissions();
    } else {
      // Cancela todos os alarmes agendados se o usuário desligar a chave geral
      await _notificationService.cancelAllNotifications();
    }
  }

  void toggleAnki(bool value) {
    _savePreference(_keyAnki, value);
    state = state.copyWith(ankiReminders: value);
  }

  void toggleFocus(bool value) {
    _savePreference(_keyFocus, value);
    state = state.copyWith(focusAlerts: value);
  }

  void toggleMedication(bool value) {
    _savePreference(_keyMedication, value);
    state = state.copyWith(medicationReminders: value);

    // Aqui você pode adicionar lógica futura para cancelar alarmes específicos
    // ex: se (value == false) _notificationService.cancelNotification(idDoRemedio);
  }
}

final notificationsProvider =
    NotifierProvider<NotificationsNotifier, NotificationsState>(() {
      return NotificationsNotifier();
    });
