import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/services/notification_preferences.dart';
import 'package:life_os/core/services/notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/timezone.dart';

class _RecordingNotificationsPlugin extends Fake
    implements FlutterLocalNotificationsPlugin {
  int initializeCalls = 0;
  int showCalls = 0;
  int scheduleCalls = 0;

  @override
  Future<bool?> initialize({
    required InitializationSettings settings,
    DidReceiveNotificationResponseCallback? onDidReceiveNotificationResponse,
    DidReceiveBackgroundNotificationResponseCallback?
    onDidReceiveBackgroundNotificationResponse,
  }) async {
    initializeCalls += 1;
    return true;
  }

  @override
  Future<void> show({
    required int id,
    String? title,
    String? body,
    NotificationDetails? notificationDetails,
    String? payload,
  }) async {
    showCalls += 1;
  }

  @override
  Future<void> zonedSchedule({
    required int id,
    required TZDateTime scheduledDate,
    required NotificationDetails notificationDetails,
    required AndroidScheduleMode androidScheduleMode,
    String? title,
    String? body,
    String? payload,
    DateTimeComponents? matchDateTimeComponents,
  }) async {
    scheduleCalls += 1;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('all_notifications false bloqueia showNotification', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      NotificationPreferenceKeys.allNotifications: false,
    });
    final plugin = _RecordingNotificationsPlugin();
    final service = NotificationService(notificationsPlugin: plugin);

    await service.showNotification('Título privado', 'Conteúdo privado');

    expect(plugin.initializeCalls, 0);
    expect(plugin.showCalls, 0);
  });

  test(
    'all_notifications false bloqueia scheduleMedicationNotification',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        NotificationPreferenceKeys.allNotifications: false,
        NotificationPreferenceKeys.medicationReminders: true,
      });
      final plugin = _RecordingNotificationsPlugin();
      final service = NotificationService(notificationsPlugin: plugin);

      await service.scheduleMedicationNotification(
        id: 1,
        title: 'Título privado',
        body: 'Conteúdo privado',
        scheduledDate: DateTime.now().add(const Duration(hours: 1)),
      );

      expect(plugin.initializeCalls, 0);
      expect(plugin.scheduleCalls, 0);
    },
  );

  test('medication_reminders false bloqueia novo agendamento', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      NotificationPreferenceKeys.allNotifications: true,
      NotificationPreferenceKeys.medicationReminders: false,
    });
    final plugin = _RecordingNotificationsPlugin();
    final service = NotificationService(notificationsPlugin: plugin);

    await service.scheduleMedicationNotification(
      id: 2,
      title: 'Título privado',
      body: 'Conteúdo privado',
      scheduledDate: DateTime.now().add(const Duration(hours: 1)),
      preferenceKey: NotificationPreferenceKeys.medicationReminders,
    );

    expect(plugin.initializeCalls, 0);
    expect(plugin.scheduleCalls, 0);
  });
}
