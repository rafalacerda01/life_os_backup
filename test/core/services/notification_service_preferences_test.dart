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
  AndroidScheduleMode? lastScheduleMode;
  bool throwOnSchedule = false;

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
    lastScheduleMode = androidScheduleMode;
    if (throwOnSchedule) {
      throw StateError('private scheduling failure');
    }
  }
}

class _FakeAndroidNotificationsPlugin extends Fake
    implements AndroidFlutterLocalNotificationsPlugin {
  _FakeAndroidNotificationsPlugin({
    required List<Object?> capabilityResults,
    this.requestResult = true,
  }) : _capabilityResults = List<Object?>.from(capabilityResults);

  final List<Object?> _capabilityResults;
  final Object? requestResult;
  int capabilityChecks = 0;
  int permissionRequests = 0;
  int notificationPermissionRequests = 0;

  @override
  Future<bool?> requestNotificationsPermission() async {
    notificationPermissionRequests += 1;
    return true;
  }

  @override
  Future<bool?> canScheduleExactNotifications() async {
    capabilityChecks += 1;
    final result = _capabilityResults.removeAt(0);
    if (result is Exception) throw result;
    return result as bool?;
  }

  @override
  Future<bool?> requestExactAlarmsPermission() async {
    permissionRequests += 1;
    if (requestResult is Exception) throw requestResult!;
    return requestResult as bool?;
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

  test('próxima ocorrência usa hoje quando o horário ainda não passou', () {
    final result = nextDailyMedicationOccurrence(
      DateTime(2026, 8, 20, 21),
      DateTime(2026, 8, 25, 11, 47),
    );

    expect(result, DateTime(2026, 8, 25, 21));
  });

  test('próxima ocorrência usa amanhã quando o horário já passou', () {
    final result = nextDailyMedicationOccurrence(
      DateTime(2026, 8, 20, 21),
      DateTime(2026, 8, 25, 22),
    );

    expect(result, DateTime(2026, 8, 26, 21));
  });

  test('próxima ocorrência preserva tratamento futuro', () {
    final scheduledDate = DateTime(2026, 8, 30, 21);

    expect(
      nextDailyMedicationOccurrence(
        scheduledDate,
        DateTime(2026, 8, 25, 11, 47),
      ),
      scheduledDate,
    );
  });

  test('próxima ocorrência preserva meia-noite explícita', () {
    final result = nextDailyMedicationOccurrence(
      DateTime(2026, 8, 20),
      DateTime(2026, 8, 25, 11, 47),
    );

    expect(result, DateTime(2026, 8, 26));
  });

  test(
    'preferência global false bloqueia pedido de permissão antes do init',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        NotificationPreferenceKeys.allNotifications: false,
        NotificationPreferenceKeys.medicationReminders: true,
      });
      final plugin = _RecordingNotificationsPlugin();
      final androidPlugin = _FakeAndroidNotificationsPlugin(
        capabilityResults: const [],
      );
      final service = NotificationService(
        notificationsPlugin: plugin,
        androidPlugin: androidPlugin,
        isAndroidOverride: true,
      );

      final granted = await service.requestPermissions(
        preferenceKey: NotificationPreferenceKeys.medicationReminders,
      );

      expect(granted, isFalse);
      expect(plugin.initializeCalls, 0);
      expect(androidPlugin.notificationPermissionRequests, 0);
    },
  );

  test(
    'preferência de medicamento false bloqueia pedido antes do init',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        NotificationPreferenceKeys.allNotifications: true,
        NotificationPreferenceKeys.medicationReminders: false,
      });
      final plugin = _RecordingNotificationsPlugin();
      final androidPlugin = _FakeAndroidNotificationsPlugin(
        capabilityResults: const [],
      );
      final service = NotificationService(
        notificationsPlugin: plugin,
        androidPlugin: androidPlugin,
        isAndroidOverride: true,
      );

      final granted = await service.requestPermissions(
        preferenceKey: NotificationPreferenceKeys.medicationReminders,
      );

      expect(granted, isFalse);
      expect(plugin.initializeCalls, 0);
      expect(androidPlugin.notificationPermissionRequests, 0);
    },
  );

  test('preferências ligadas preservam pedido normal de permissão', () async {
    final plugin = _RecordingNotificationsPlugin();
    final androidPlugin = _FakeAndroidNotificationsPlugin(
      capabilityResults: const [],
    );
    final service = NotificationService(
      notificationsPlugin: plugin,
      androidPlugin: androidPlugin,
      isAndroidOverride: true,
    );

    final granted = await service.requestPermissions(
      preferenceKey: NotificationPreferenceKeys.medicationReminders,
    );

    expect(granted, isTrue);
    expect(plugin.initializeCalls, 1);
    expect(androidPlugin.notificationPermissionRequests, 1);
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

      final scheduled = await service.scheduleMedicationNotification(
        id: 1,
        title: 'Título privado',
        body: 'Conteúdo privado',
        scheduledDate: DateTime.now().add(const Duration(hours: 1)),
      );

      expect(plugin.initializeCalls, 0);
      expect(plugin.scheduleCalls, 0);
      expect(scheduled, isFalse);
    },
  );

  test('medication_reminders false bloqueia novo agendamento', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      NotificationPreferenceKeys.allNotifications: true,
      NotificationPreferenceKeys.medicationReminders: false,
    });
    final plugin = _RecordingNotificationsPlugin();
    final service = NotificationService(notificationsPlugin: plugin);

    final scheduled = await service.scheduleMedicationNotification(
      id: 2,
      title: 'Título privado',
      body: 'Conteúdo privado',
      scheduledDate: DateTime.now().add(const Duration(hours: 1)),
      preferenceKey: NotificationPreferenceKeys.medicationReminders,
    );

    expect(plugin.initializeCalls, 0);
    expect(plugin.scheduleCalls, 0);
    expect(scheduled, isFalse);
  });

  test('exact já permitido não solicita permissão novamente', () async {
    final plugin = _RecordingNotificationsPlugin();
    final androidPlugin = _FakeAndroidNotificationsPlugin(
      capabilityResults: [true],
    );
    final service = NotificationService(
      notificationsPlugin: plugin,
      androidPlugin: androidPlugin,
      isAndroidOverride: true,
    );

    expect(await service.requestExactAlarmPermission(), isTrue);
    expect(androidPlugin.capabilityChecks, 1);
    expect(androidPlugin.permissionRequests, 0);
  });

  test('exact negado é solicitado e rechecado como permitido', () async {
    final androidPlugin = _FakeAndroidNotificationsPlugin(
      capabilityResults: [false, true],
    );
    final service = NotificationService(
      notificationsPlugin: _RecordingNotificationsPlugin(),
      androidPlugin: androidPlugin,
      isAndroidOverride: true,
    );

    expect(await service.requestExactAlarmPermission(), isTrue);
    expect(androidPlugin.capabilityChecks, 2);
    expect(androidPlugin.permissionRequests, 1);
  });

  test('recheck ainda negado retorna false', () async {
    final androidPlugin = _FakeAndroidNotificationsPlugin(
      capabilityResults: [false, false],
    );
    final service = NotificationService(
      notificationsPlugin: _RecordingNotificationsPlugin(),
      androidPlugin: androidPlugin,
      isAndroidOverride: true,
    );

    expect(await service.requestExactAlarmPermission(), isFalse);
    expect(androidPlugin.capabilityChecks, 2);
    expect(androidPlugin.permissionRequests, 1);
  });

  test('erro ao consultar capacidade exact retorna false', () async {
    final androidPlugin = _FakeAndroidNotificationsPlugin(
      capabilityResults: [StateError('private capability failure')],
    );
    final service = NotificationService(
      notificationsPlugin: _RecordingNotificationsPlugin(),
      androidPlugin: androidPlugin,
      isAndroidOverride: true,
    );

    expect(await service.requestExactAlarmPermission(), isFalse);
    expect(androidPlugin.permissionRequests, 0);
  });

  test('erro ao solicitar exact retorna false', () async {
    final androidPlugin = _FakeAndroidNotificationsPlugin(
      capabilityResults: [false],
      requestResult: StateError('private permission failure'),
    );
    final service = NotificationService(
      notificationsPlugin: _RecordingNotificationsPlugin(),
      androidPlugin: androidPlugin,
      isAndroidOverride: true,
    );

    expect(await service.requestExactAlarmPermission(), isFalse);
    expect(androidPlugin.permissionRequests, 1);
  });

  test('retorno true do request não substitui recheck false', () async {
    final androidPlugin = _FakeAndroidNotificationsPlugin(
      capabilityResults: [false, false],
      requestResult: true,
    );
    final service = NotificationService(
      notificationsPlugin: _RecordingNotificationsPlugin(),
      androidPlugin: androidPlugin,
      isAndroidOverride: true,
    );

    expect(await service.requestExactAlarmPermission(), isFalse);
    expect(androidPlugin.capabilityChecks, 2);
  });

  test('capacidade exact usa exactAllowWhileIdle e retorna true', () async {
    final plugin = _RecordingNotificationsPlugin();
    final androidPlugin = _FakeAndroidNotificationsPlugin(
      capabilityResults: [true],
    );
    final service = NotificationService(
      notificationsPlugin: plugin,
      androidPlugin: androidPlugin,
      isAndroidOverride: true,
    );

    final scheduled = await service.scheduleMedicationNotification(
      id: 3,
      title: 'Título privado',
      body: 'Conteúdo privado',
      scheduledDate: DateTime.now().add(const Duration(hours: 1)),
    );

    expect(scheduled, isTrue);
    expect(plugin.lastScheduleMode, AndroidScheduleMode.exactAllowWhileIdle);
    expect(androidPlugin.permissionRequests, 0);
  });

  test(
    'capacidade exact false usa fallback inexact sem pedir permissão',
    () async {
      final plugin = _RecordingNotificationsPlugin();
      final androidPlugin = _FakeAndroidNotificationsPlugin(
        capabilityResults: [false],
      );
      final service = NotificationService(
        notificationsPlugin: plugin,
        androidPlugin: androidPlugin,
        isAndroidOverride: true,
      );

      final scheduled = await service.scheduleMedicationNotification(
        id: 4,
        title: 'Título privado',
        body: 'Conteúdo privado',
        scheduledDate: DateTime.now().add(const Duration(hours: 1)),
      );

      expect(scheduled, isTrue);
      expect(
        plugin.lastScheduleMode,
        AndroidScheduleMode.inexactAllowWhileIdle,
      );
      expect(androidPlugin.permissionRequests, 0);
    },
  );

  test('falha de zonedSchedule retorna false', () async {
    final plugin = _RecordingNotificationsPlugin()..throwOnSchedule = true;
    final service = NotificationService(
      notificationsPlugin: plugin,
      androidPlugin: _FakeAndroidNotificationsPlugin(capabilityResults: [true]),
      isAndroidOverride: true,
    );

    final scheduled = await service.scheduleMedicationNotification(
      id: 5,
      title: 'Título privado',
      body: 'Conteúdo privado',
      scheduledDate: DateTime.now().add(const Duration(hours: 1)),
    );

    expect(scheduled, isFalse);
    expect(plugin.scheduleCalls, 1);
  });
}
