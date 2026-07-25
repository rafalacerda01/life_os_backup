import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';
import 'dart:math';

class NotificationService {
  final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();

  Future<void> init() async {
    const AndroidInitializationSettings androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    const InitializationSettings initializationSettings =
        InitializationSettings(
          android: androidSettings,
          iOS: DarwinInitializationSettings(),
        );

    // Na versão 17+, "settings" é obrigatório
    await _notificationsPlugin.initialize(
      settings: initializationSettings,
      onDidReceiveNotificationResponse: (NotificationResponse response) {
        // Lógica para quando o usuário clicar na notificação
      },
    );
    tz.initializeTimeZones();
  }

  Future<void> requestPermissions() async {
    if (Platform.isAndroid) {
      await _notificationsPlugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();

      await _notificationsPlugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestExactAlarmsPermission();
    } else if (Platform.isIOS) {
      await _notificationsPlugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >()
          ?.requestPermissions(alert: true, badge: true, sound: true);
    }
  }

  Future<void> showNotification(
    String title,
    String body, {
    String? preferenceKey,
    int? id,
  }) async {
    if (preferenceKey != null) {
      final prefs = await SharedPreferences.getInstance();
      bool isEnabled = prefs.getBool(preferenceKey) ?? true;
      if (!isEnabled) return;
    }

    const AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
          'life_os_channel',
          'Life OS Notificações',
          importance: Importance.max,
          priority: Priority.high,
        );

    // Parâmetros nomeados corretamente aplicados
    await _notificationsPlugin.show(
      id: id ?? Random().nextInt(10000),
      title: title,
      body: body,
      notificationDetails: const NotificationDetails(android: androidDetails),
    );
  }

  Future<void> scheduleMedicationNotification({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledDate,
    String? preferenceKey,
    bool repeatDaily = false,
  }) async {
    if (preferenceKey != null) {
      final prefs = await SharedPreferences.getInstance();
      bool isEnabled = prefs.getBool(preferenceKey) ?? true;
      if (!isEnabled) return;
    }

    DateTime validDate = scheduledDate;
    if (validDate.isBefore(DateTime.now())) {
      validDate = validDate.add(const Duration(days: 1));
    }

    const AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
          'medication_reminders_channel',
          'Lembretes de Medicamentos',
          importance: Importance.max,
          priority: Priority.high,
        );

    // Parâmetros nomeados para agendamento
    await _notificationsPlugin.zonedSchedule(
      id: id,
      title: title,
      body: body,
      scheduledDate: tz.TZDateTime.from(validDate, tz.local),
      notificationDetails: const NotificationDetails(android: androidDetails),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      matchDateTimeComponents: repeatDaily ? DateTimeComponents.time : null,
    );
  }

  Future<void> cancelNotification(int id) async {
    // ID nomeado obrigatório
    await _notificationsPlugin.cancel(id: id);
  }

  Future<void> cancelAllNotifications() async {
    await _notificationsPlugin.cancelAll();
  }
}
