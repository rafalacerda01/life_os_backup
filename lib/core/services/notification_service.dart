import 'dart:io';
import 'dart:math';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:life_os/core/services/notification_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

DateTime nextDailyMedicationOccurrence(DateTime scheduledDate, DateTime now) {
  if (!scheduledDate.isBefore(now)) return scheduledDate;

  final todayAtScheduledTime = DateTime(
    now.year,
    now.month,
    now.day,
    scheduledDate.hour,
    scheduledDate.minute,
  );

  if (!todayAtScheduledTime.isBefore(now)) return todayAtScheduledTime;

  return DateTime(
    now.year,
    now.month,
    now.day + 1,
    scheduledDate.hour,
    scheduledDate.minute,
  );
}

class NotificationService {
  NotificationService({
    FlutterLocalNotificationsPlugin? notificationsPlugin,
    AndroidFlutterLocalNotificationsPlugin? androidPlugin,
    this.isAndroidOverride,
  }) : _androidPluginOverride = androidPlugin,
       _notificationsPlugin =
           notificationsPlugin ?? FlutterLocalNotificationsPlugin();

  static final NotificationService instance = NotificationService();

  final FlutterLocalNotificationsPlugin _notificationsPlugin;
  final AndroidFlutterLocalNotificationsPlugin? _androidPluginOverride;
  final bool? isAndroidOverride;

  bool _initialized = false;

  // ---------------------------------------------------------------------------
  // INICIALIZAÇÃO
  // ---------------------------------------------------------------------------

  Future<void> init() async {
    if (_initialized) return;

    tz.initializeTimeZones();

    const AndroidInitializationSettings androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    const DarwinInitializationSettings iosSettings =
        DarwinInitializationSettings();

    const InitializationSettings initializationSettings =
        InitializationSettings(android: androidSettings, iOS: iosSettings);

    await _notificationsPlugin.initialize(
      settings: initializationSettings,
      onDidReceiveNotificationResponse: _onNotificationResponse,
    );

    _initialized = true;
  }

  void _onNotificationResponse(NotificationResponse response) {
    // Tratamento futuro de clique na notificação.
  }

  // ---------------------------------------------------------------------------
  // PERMISSÕES
  // ---------------------------------------------------------------------------

  Future<bool> requestPermissions({String? preferenceKey}) async {
    try {
      if (!await _isEnabled(preferenceKey)) return false;

      await init();

      if (_isAndroid) {
        final androidPlugin = _androidPlugin;

        if (androidPlugin == null) {
          return false;
        }

        // Android 13+ — permissão para exibir notificações.
        final bool? notificationPermission = await androidPlugin
            .requestNotificationsPermission();

        return notificationPermission ?? true;
      }

      if (Platform.isIOS) {
        final IOSFlutterLocalNotificationsPlugin? iosPlugin =
            _notificationsPlugin
                .resolvePlatformSpecificImplementation<
                  IOSFlutterLocalNotificationsPlugin
                >();

        if (iosPlugin == null) {
          return false;
        }

        final bool? permission = await iosPlugin.requestPermissions(
          alert: true,
          badge: true,
          sound: true,
        );

        return permission ?? true;
      }

      return true;
    } catch (_) {
      // A falha na permissão NÃO deve impedir o cadastro
      // de medicamentos ou qualquer outra operação do aplicativo.
      return false;
    }
  }

  Future<bool> requestExactAlarmPermission() async {
    try {
      await init();

      if (!_isAndroid) return true;

      final androidPlugin = _androidPlugin;
      if (androidPlugin == null) return false;

      final canSchedule = await androidPlugin.canScheduleExactNotifications();
      if (canSchedule == true) return true;

      await androidPlugin.requestExactAlarmsPermission();

      return await androidPlugin.canScheduleExactNotifications() == true;
    } catch (_) {
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // NOTIFICAÇÃO IMEDIATA
  // ---------------------------------------------------------------------------

  Future<void> showNotification(
    String title,
    String body, {
    String? preferenceKey,
    int? id,
  }) async {
    try {
      if (!await _isEnabled(preferenceKey)) return;

      await init();

      const AndroidNotificationDetails androidDetails =
          AndroidNotificationDetails(
            'life_os_channel',
            'Life OS Notificações',
            channelDescription: 'Notificações gerais do Life OS',
            importance: Importance.max,
            priority: Priority.high,
          );

      const NotificationDetails notificationDetails = NotificationDetails(
        android: androidDetails,
        iOS: DarwinNotificationDetails(),
      );

      await _notificationsPlugin.show(
        id: id ?? Random().nextInt(100000),
        title: title,
        body: body,
        notificationDetails: notificationDetails,
      );
    } catch (_) {
      // Notificações nunca devem quebrar o fluxo principal do aplicativo.
    }
  }

  // ---------------------------------------------------------------------------
  // NOTIFICAÇÃO DE MEDICAMENTO
  // ---------------------------------------------------------------------------

  Future<bool> scheduleMedicationNotification({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledDate,
    String? preferenceKey,
    bool repeatDaily = false,
  }) async {
    try {
      final medicationPreference =
          preferenceKey ?? NotificationPreferenceKeys.medicationReminders;
      if (!await _isEnabled(medicationPreference)) return false;

      await init();

      var scheduleMode = AndroidScheduleMode.exactAllowWhileIdle;
      if (_isAndroid) {
        scheduleMode = await _canScheduleExactNotifications()
            ? AndroidScheduleMode.exactAllowWhileIdle
            : AndroidScheduleMode.inexactAllowWhileIdle;
      }

      final now = DateTime.now();
      DateTime validDate = repeatDaily
          ? nextDailyMedicationOccurrence(scheduledDate, now)
          : scheduledDate;

      if (!repeatDaily && validDate.isBefore(now)) {
        validDate = validDate.add(const Duration(days: 1));
      }

      const AndroidNotificationDetails androidDetails =
          AndroidNotificationDetails(
            'medication_reminders_channel',
            'Lembretes de Medicamentos',
            channelDescription: 'Lembretes para tomar medicamentos',
            importance: Importance.max,
            priority: Priority.high,
          );

      const NotificationDetails notificationDetails = NotificationDetails(
        android: androidDetails,
        iOS: DarwinNotificationDetails(),
      );

      await _notificationsPlugin.zonedSchedule(
        id: id,
        title: title,
        body: body,
        scheduledDate: tz.TZDateTime.from(validDate, tz.local),
        notificationDetails: notificationDetails,

        androidScheduleMode: scheduleMode,

        matchDateTimeComponents: repeatDaily ? DateTimeComponents.time : null,
      );

      return true;
    } catch (_) {
      // O medicamento já foi salvo.
      // Uma falha no sistema de notificações não pode
      // cancelar ou quebrar o cadastro.
      return false;
    }
  }

  Future<bool> scheduleCycleReminderNotification({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledDate,
    required DateTimeComponents matchDateTimeComponents,
  }) async {
    try {
      if (!await _isEnabled(null)) return false;

      await init();

      var scheduleMode = AndroidScheduleMode.exactAllowWhileIdle;
      if (_isAndroid) {
        scheduleMode = await _canScheduleExactNotifications()
            ? AndroidScheduleMode.exactAllowWhileIdle
            : AndroidScheduleMode.inexactAllowWhileIdle;
      }

      const androidDetails = AndroidNotificationDetails(
        'cycle_personal_reminders_channel',
        'Lembretes pessoais',
        channelDescription: 'Lembretes pessoais configurados no Life OS',
        importance: Importance.max,
        priority: Priority.high,
        visibility: NotificationVisibility.private,
      );
      const notificationDetails = NotificationDetails(
        android: androidDetails,
        iOS: DarwinNotificationDetails(),
      );

      await _notificationsPlugin.zonedSchedule(
        id: id,
        title: title,
        body: body,
        scheduledDate: tz.TZDateTime.from(scheduledDate, tz.local),
        notificationDetails: notificationDetails,
        androidScheduleMode: scheduleMode,
        matchDateTimeComponents: matchDateTimeComponents,
      );

      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> cancelCycleReminderNotification(int id) async {
    try {
      await init();
      await _notificationsPlugin.cancel(id: id);
      return true;
    } catch (_) {
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // CANCELAR UMA NOTIFICAÇÃO
  // ---------------------------------------------------------------------------

  Future<void> cancelNotification(int id) async {
    try {
      await init();

      await _notificationsPlugin.cancel(id: id);
    } catch (_) {
      // Não propagar erro para o fluxo principal.
    }
  }

  // ---------------------------------------------------------------------------
  // CANCELAR TODAS
  // ---------------------------------------------------------------------------

  Future<void> cancelAllNotifications() async {
    try {
      await init();

      await _notificationsPlugin.cancelAll();
    } catch (_) {
      // Não propagar erro para o fluxo principal.
    }
  }

  Future<bool> _isEnabled(String? preferenceKey) async {
    final preferences = await SharedPreferences.getInstance();
    final allEnabled =
        preferences.getBool(NotificationPreferenceKeys.allNotifications) ??
        true;

    if (!allEnabled) return false;
    if (preferenceKey == null) return true;

    return preferences.getBool(preferenceKey) ?? true;
  }

  bool get _isAndroid => isAndroidOverride ?? Platform.isAndroid;

  AndroidFlutterLocalNotificationsPlugin? get _androidPlugin =>
      _androidPluginOverride ??
      _notificationsPlugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();

  Future<bool> _canScheduleExactNotifications() async {
    try {
      return await _androidPlugin?.canScheduleExactNotifications() == true;
    } catch (_) {
      return false;
    }
  }
}
