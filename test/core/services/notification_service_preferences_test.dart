import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/services/notification_preferences.dart';
import 'package:life_os/core/services/notification_service.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/features/health/services/medication_reminder_lifecycle.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/timezone.dart';

class _RecordingNotificationsPlugin extends Fake
    implements FlutterLocalNotificationsPlugin {
  int initializeCalls = 0;
  int showCalls = 0;
  int scheduleCalls = 0;
  AndroidScheduleMode? lastScheduleMode;
  NotificationDetails? lastNotificationDetails;
  DateTimeComponents? lastDateTimeComponents;
  String? lastTitle;
  String? lastBody;
  String? lastPayload;
  TZDateTime? lastScheduledDate;
  InitializationSettings? initializationSettings;
  DidReceiveNotificationResponseCallback? foregroundCallback;
  DidReceiveBackgroundNotificationResponseCallback? backgroundCallback;
  NotificationAppLaunchDetails? launchDetails;
  final List<int> cancelledIds = <int>[];
  int cancelAllCalls = 0;
  bool throwOnSchedule = false;
  bool throwOnCancelAll = false;
  bool throwOnCancel = false;
  bool throwOnPending = false;
  final pending = <PendingNotificationRequest>[];
  final scheduledDates = <TZDateTime>[];
  Future<bool?> Function(int call)? initializeHandler;

  @override
  Future<bool?> initialize({
    required InitializationSettings settings,
    DidReceiveNotificationResponseCallback? onDidReceiveNotificationResponse,
    DidReceiveBackgroundNotificationResponseCallback?
    onDidReceiveBackgroundNotificationResponse,
  }) async {
    initializeCalls += 1;
    initializationSettings = settings;
    foregroundCallback = onDidReceiveNotificationResponse;
    backgroundCallback = onDidReceiveBackgroundNotificationResponse;
    final handler = initializeHandler;
    if (handler != null) return handler(initializeCalls);
    return true;
  }

  @override
  Future<NotificationAppLaunchDetails?>
  getNotificationAppLaunchDetails() async {
    return launchDetails;
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
    lastNotificationDetails = notificationDetails;
    lastDateTimeComponents = matchDateTimeComponents;
    lastTitle = title;
    lastBody = body;
    lastPayload = payload;
    lastScheduledDate = scheduledDate;
    scheduledDates.add(scheduledDate);
    if (throwOnSchedule) {
      throw StateError('private scheduling failure');
    }
    pending.removeWhere((request) => request.id == id);
    pending.add(PendingNotificationRequest(id, title, body, payload));
  }

  @override
  Future<void> cancel({required int id, String? tag}) async {
    cancelledIds.add(id);
    if (throwOnCancel) throw StateError('private-cancel-marker');
    pending.removeWhere((request) => request.id == id);
  }

  @override
  Future<List<PendingNotificationRequest>> pendingNotificationRequests() async {
    if (throwOnPending) throw StateError('private-pending-marker');
    return List.of(pending);
  }

  @override
  Future<void> cancelAll() async {
    cancelAllCalls += 1;
    if (throwOnCancelAll) {
      throw StateError('private cancel all failure');
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

DeviceTimeZoneResolver _timeZoneResolver(String identifier) =>
    () async => identifier;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('cancelamento estrito chama o plugin e conclui', () async {
    final plugin = _RecordingNotificationsPlugin();
    final service = NotificationService(notificationsPlugin: plugin);

    await service.cancelAllNotificationsOrThrow();

    expect(plugin.cancelAllCalls, 1);
  });

  test('cancelamento estrito propaga falha do plugin', () async {
    final plugin = _RecordingNotificationsPlugin()..throwOnCancelAll = true;
    final service = NotificationService(notificationsPlugin: plugin);

    await expectLater(
      service.cancelAllNotificationsOrThrow(),
      throwsStateError,
    );
    expect(plugin.cancelAllCalls, 1);
  });

  test('cancelamento best-effort preserva falha isolada da UI', () async {
    final plugin = _RecordingNotificationsPlugin()..throwOnCancelAll = true;
    final service = NotificationService(notificationsPlugin: plugin);

    await service.cancelAllNotifications();

    expect(plugin.cancelAllCalls, 1);
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
      deviceTimeZoneResolver: _timeZoneResolver('UTC'),
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
    expect(plugin.lastNotificationDetails?.android?.actions, isNull);
    expect(plugin.lastNotificationDetails?.iOS?.categoryIdentifier, isNull);
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
        deviceTimeZoneResolver: _timeZoneResolver('UTC'),
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
      deviceTimeZoneResolver: _timeZoneResolver('UTC'),
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

  test(
    'medicamento recorrente usa timezone real e preserva wall-clock',
    () async {
      final plugin = _RecordingNotificationsPlugin();
      final service = NotificationService(
        notificationsPlugin: plugin,
        deviceTimeZoneResolver: _timeZoneResolver('America/Sao_Paulo'),
        isAndroidOverride: false,
      );

      final scheduled = await service.scheduleMedicationNotification(
        id: 6,
        title: 'Título privado',
        body: 'Conteúdo privado',
        scheduledDate: DateTime(2099, 8, 26, 21),
        repeatDaily: true,
      );

      expect(scheduled, isTrue);
      expect(plugin.lastScheduledDate?.location.name, 'America/Sao_Paulo');
      expect(plugin.lastScheduledDate?.hour, 21);
      expect(plugin.lastScheduledDate?.minute, 0);
      expect(plugin.lastDateTimeComponents, DateTimeComponents.time);
    },
  );

  test(
    'timezone diferente preserva os mesmos componentes wall-clock',
    () async {
      final plugin = _RecordingNotificationsPlugin();
      final service = NotificationService(
        notificationsPlugin: plugin,
        deviceTimeZoneResolver: _timeZoneResolver('America/New_York'),
        isAndroidOverride: false,
      );

      final scheduled = await service.scheduleMedicationNotification(
        id: 7,
        title: 'Título privado',
        body: 'Conteúdo privado',
        scheduledDate: DateTime(2099, 8, 26, 21, 35),
      );

      expect(scheduled, isTrue);
      expect(plugin.lastScheduledDate?.location.name, 'America/New_York');
      expect(plugin.lastScheduledDate?.hour, 21);
      expect(plugin.lastScheduledDate?.minute, 35);
    },
  );

  test('timezone inválida falha sem chamar zonedSchedule', () async {
    final plugin = _RecordingNotificationsPlugin();
    final service = NotificationService(
      notificationsPlugin: plugin,
      deviceTimeZoneResolver: _timeZoneResolver('Invalid/Time_Zone'),
      isAndroidOverride: false,
    );

    final scheduled = await service.scheduleMedicationNotification(
      id: 8,
      title: 'Título privado',
      body: 'Conteúdo privado',
      scheduledDate: DateTime(2099, 8, 26, 21),
    );

    expect(scheduled, isFalse);
    expect(plugin.scheduleCalls, 0);
  });

  test('timezone vazia falha sem chamar zonedSchedule', () async {
    final plugin = _RecordingNotificationsPlugin();
    final service = NotificationService(
      notificationsPlugin: plugin,
      deviceTimeZoneResolver: _timeZoneResolver('   '),
      isAndroidOverride: false,
    );

    final scheduled = await service.scheduleMedicationNotification(
      id: 9,
      title: 'Título privado',
      body: 'Conteúdo privado',
      scheduledDate: DateTime(2099, 8, 26, 21),
    );

    expect(scheduled, isFalse);
    expect(plugin.scheduleCalls, 0);
  });

  test('falha do resolver retorna false sem chamar zonedSchedule', () async {
    final plugin = _RecordingNotificationsPlugin();
    final service = NotificationService(
      notificationsPlugin: plugin,
      deviceTimeZoneResolver: () async {
        throw StateError('private timezone failure');
      },
      isAndroidOverride: false,
    );

    final scheduled = await service.scheduleMedicationNotification(
      id: 9,
      title: 'Título privado',
      body: 'Conteúdo privado',
      scheduledDate: DateTime(2099, 8, 26, 21),
    );

    expect(scheduled, isFalse);
    expect(plugin.scheduleCalls, 0);
  });

  test('cycle reminder usa canal neutro privado e exact disponível', () async {
    final plugin = _RecordingNotificationsPlugin();
    final service = NotificationService(
      notificationsPlugin: plugin,
      androidPlugin: _FakeAndroidNotificationsPlugin(capabilityResults: [true]),
      deviceTimeZoneResolver: _timeZoneResolver('America/Sao_Paulo'),
      isAndroidOverride: true,
    );

    final scheduled = await service.scheduleCycleReminderNotification(
      id: 81,
      title: 'Lembrete pessoal',
      body: 'Você tem um lembrete programado.',
      scheduledDate: DateTime(2026, 8, 26, 9),
      matchDateTimeComponents: DateTimeComponents.time,
      payload: 'private-action-payload',
    );

    final android = plugin.lastNotificationDetails?.android;
    expect(scheduled, isTrue);
    expect(plugin.lastScheduleMode, AndroidScheduleMode.exactAllowWhileIdle);
    expect(plugin.lastDateTimeComponents, DateTimeComponents.time);
    expect(plugin.lastScheduledDate?.location.name, 'America/Sao_Paulo');
    expect(plugin.lastScheduledDate?.hour, 9);
    expect(plugin.lastScheduledDate?.minute, 0);
    expect(android?.channelId, 'cycle_personal_reminders_channel');
    expect(android?.channelName, 'Lembretes pessoais');
    expect(android?.visibility, NotificationVisibility.private);
    expect(android?.actions, hasLength(1));
    final action = android!.actions!.single;
    expect(action.id, cycleReminderSnoozeActionId);
    expect(action.title, 'Lembrar depois');
    expect(action.showsUserInterface, isTrue);
    expect(action.cancelNotification, isTrue);
    expect(
      plugin.lastNotificationDetails?.iOS?.categoryIdentifier,
      cycleReminderActionCategoryId,
    );
    expect(plugin.lastPayload, 'private-action-payload');
    expect(plugin.backgroundCallback, isNull);

    final categories =
        plugin.initializationSettings?.iOS?.notificationCategories;
    expect(categories, hasLength(2));
    final category = categories!.singleWhere(
      (candidate) => candidate.identifier == cycleReminderActionCategoryId,
    );
    expect(category.identifier, cycleReminderActionCategoryId);
    expect(category.actions, hasLength(1));
    expect(category.actions.single.identifier, cycleReminderSnoozeActionId);
    expect(category.actions.single.title, 'Lembrar depois');
    expect(
      category.actions.single.options,
      contains(DarwinNotificationActionOption.foreground),
    );
    final pillCategory = categories.singleWhere(
      (candidate) => candidate.identifier == cycleReminderPillActionCategoryId,
    );
    expect(pillCategory.actions.map((action) => action.identifier), <String>[
      cycleReminderDoneActionId,
      cycleReminderSnoozeActionId,
    ]);
    expect(
      pillCategory.actions
          .expand((action) => action.options)
          .every(
            (option) => option == DarwinNotificationActionOption.foreground,
          ),
      isTrue,
    );
  });

  test('pill recurring mostra Feito e Lembrar depois em foreground', () async {
    final plugin = _RecordingNotificationsPlugin();
    final service = NotificationService(
      notificationsPlugin: plugin,
      androidPlugin: _FakeAndroidNotificationsPlugin(capabilityResults: [true]),
      deviceTimeZoneResolver: _timeZoneResolver('UTC'),
      isAndroidOverride: true,
    );

    await service.scheduleCycleReminderNotification(
      id: 811,
      title: 'Lembrete pessoal',
      body: 'Você tem um lembrete programado.',
      scheduledDate: DateTime(2026, 8, 26, 9),
      matchDateTimeComponents: DateTimeComponents.time,
      payload: 'private-action-payload',
      includeDoneAction: true,
    );

    final actions = plugin.lastNotificationDetails!.android!.actions!;
    expect(actions.map((action) => action.id), <String>[
      cycleReminderDoneActionId,
      cycleReminderSnoozeActionId,
    ]);
    expect(actions.map((action) => action.title), <String>[
      'Feito',
      'Lembrar depois',
    ]);
    expect(actions.every((action) => action.showsUserInterface), isTrue);
    expect(
      plugin.lastNotificationDetails?.iOS?.categoryIdentifier,
      cycleReminderPillActionCategoryId,
    );
  });

  test(
    'cycle weekly usa timezone real e preserva recorrência semanal',
    () async {
      final plugin = _RecordingNotificationsPlugin();
      final service = NotificationService(
        notificationsPlugin: plugin,
        deviceTimeZoneResolver: _timeZoneResolver('America/Sao_Paulo'),
        isAndroidOverride: false,
      );

      final scheduled = await service.scheduleCycleReminderNotification(
        id: 812,
        title: 'Lembrete pessoal',
        body: 'Você tem um lembrete programado.',
        scheduledDate: DateTime(2099, 8, 26, 18, 40),
        matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime,
        payload: 'private-action-payload',
      );

      expect(scheduled, isTrue);
      expect(plugin.lastScheduledDate?.location.name, 'America/Sao_Paulo');
      expect(plugin.lastScheduledDate?.hour, 18);
      expect(plugin.lastScheduledDate?.minute, 40);
      expect(
        plugin.lastDateTimeComponents,
        DateTimeComponents.dayOfWeekAndTime,
      );
    },
  );

  test(
    'cycle reminder mantém fallback inexact quando exact está negado',
    () async {
      final plugin = _RecordingNotificationsPlugin();
      final service = NotificationService(
        notificationsPlugin: plugin,
        androidPlugin: _FakeAndroidNotificationsPlugin(
          capabilityResults: [false],
        ),
        deviceTimeZoneResolver: _timeZoneResolver('UTC'),
        isAndroidOverride: true,
      );

      final scheduled = await service.scheduleCycleReminderNotification(
        id: 82,
        title: 'Lembrete pessoal',
        body: 'Você tem um lembrete programado.',
        scheduledDate: DateTime(2026, 8, 26, 9),
        matchDateTimeComponents: DateTimeComponents.time,
        payload: 'private-action-payload',
      );

      expect(scheduled, isTrue);
      expect(
        plugin.lastScheduleMode,
        AndroidScheduleMode.inexactAllowWhileIdle,
      );
    },
  );

  test('snooze cycle é one-shot exact sem pedir permissão', () async {
    final plugin = _RecordingNotificationsPlugin();
    final androidPlugin = _FakeAndroidNotificationsPlugin(
      capabilityResults: [true],
    );
    final service = NotificationService(
      notificationsPlugin: plugin,
      androidPlugin: androidPlugin,
      deviceTimeZoneResolver: _timeZoneResolver('America/Sao_Paulo'),
      isAndroidOverride: true,
    );

    final scheduled = await service.scheduleCycleReminderSnoozeNotification(
      id: 83,
      title: 'Lembrete pessoal',
      body: 'Você tem um lembrete programado.',
      scheduledDate: DateTime(2026, 8, 26, 9, 15),
      payload: 'private-action-payload',
    );

    expect(scheduled, isTrue);
    expect(plugin.lastDateTimeComponents, isNull);
    expect(plugin.lastScheduledDate?.location.name, 'America/Sao_Paulo');
    expect(plugin.lastScheduledDate?.hour, 9);
    expect(plugin.lastScheduledDate?.minute, 15);
    expect(plugin.lastScheduleMode, AndroidScheduleMode.exactAllowWhileIdle);
    expect(androidPlugin.permissionRequests, 0);
    expect(androidPlugin.notificationPermissionRequests, 0);
    expect(
      plugin.lastNotificationDetails!.android!.actions!.map(
        (action) => action.id,
      ),
      <String>[cycleReminderSnoozeActionId],
    );
    expect(
      plugin.lastNotificationDetails?.iOS?.categoryIdentifier,
      cycleReminderActionCategoryId,
    );
  });

  test('pill snooze preserva Feito e Lembrar depois', () async {
    final plugin = _RecordingNotificationsPlugin();
    final service = NotificationService(
      notificationsPlugin: plugin,
      androidPlugin: _FakeAndroidNotificationsPlugin(capabilityResults: [true]),
      deviceTimeZoneResolver: _timeZoneResolver('UTC'),
      isAndroidOverride: true,
    );

    await service.scheduleCycleReminderSnoozeNotification(
      id: 831,
      title: 'Lembrete pessoal',
      body: 'Você tem um lembrete programado.',
      scheduledDate: DateTime(2026, 8, 26, 9, 15),
      payload: 'private-action-payload',
      includeDoneAction: true,
    );

    expect(
      plugin.lastNotificationDetails!.android!.actions!.map(
        (action) => action.id,
      ),
      <String>[cycleReminderDoneActionId, cycleReminderSnoozeActionId],
    );
    expect(
      plugin.lastNotificationDetails?.iOS?.categoryIdentifier,
      cycleReminderPillActionCategoryId,
    );
  });

  test('snooze cycle usa fallback inexact sem pedir permissão', () async {
    final plugin = _RecordingNotificationsPlugin();
    final androidPlugin = _FakeAndroidNotificationsPlugin(
      capabilityResults: [false],
    );
    final service = NotificationService(
      notificationsPlugin: plugin,
      androidPlugin: androidPlugin,
      deviceTimeZoneResolver: _timeZoneResolver('UTC'),
      isAndroidOverride: true,
    );

    await service.scheduleCycleReminderSnoozeNotification(
      id: 84,
      title: 'Lembrete pessoal',
      body: 'Você tem um lembrete programado.',
      scheduledDate: DateTime(2026, 8, 26, 9, 15),
      payload: 'private-action-payload',
    );

    expect(plugin.lastScheduleMode, AndroidScheduleMode.inexactAllowWhileIdle);
    expect(androidPlugin.permissionRequests, 0);
  });

  test('show e cancelamento não dependem do resolver de timezone', () async {
    final plugin = _RecordingNotificationsPlugin();
    var resolverCalls = 0;
    final service = NotificationService(
      notificationsPlugin: plugin,
      deviceTimeZoneResolver: () async {
        resolverCalls += 1;
        throw StateError('private timezone failure');
      },
    );

    await service.showNotification(
      'Título privado',
      'Conteúdo privado',
      id: 90,
    );
    await service.cancelNotification(90);

    expect(plugin.showCalls, 1);
    expect(plugin.cancelledIds, <int>[90]);
    expect(resolverCalls, 0);
  });

  test('duas chamadas concorrentes compartilham um initialize', () async {
    final initializeGate = Completer<bool?>();
    final plugin = _RecordingNotificationsPlugin()
      ..initializeHandler = (_) => initializeGate.future;
    final service = NotificationService(notificationsPlugin: plugin);

    final first = service.init();
    final second = service.init();

    expect(identical(first, second), isTrue);
    expect(plugin.initializeCalls, 1);
    initializeGate.complete(true);
    await Future.wait([first, second]);
  });

  test('quatro chamadas concorrentes executam um initialize', () async {
    final initializeGate = Completer<bool?>();
    final plugin = _RecordingNotificationsPlugin()
      ..initializeHandler = (_) => initializeGate.future;
    final service = NotificationService(notificationsPlugin: plugin);

    final operations = List<Future<void>>.generate(4, (_) => service.init());

    expect(
      operations.every((operation) => identical(operation, operations[0])),
      isTrue,
    );
    expect(plugin.initializeCalls, 1);
    initializeGate.complete(true);
    await Future.wait(operations);
  });

  test('init depois do sucesso retorna sem novo initialize', () async {
    final plugin = _RecordingNotificationsPlugin();
    final service = NotificationService(notificationsPlugin: plugin);

    await service.init();
    await service.init();

    expect(plugin.initializeCalls, 1);
  });

  test('falha concorrente é compartilhada e propagada aos callers', () async {
    final initializeGate = Completer<bool?>();
    final plugin = _RecordingNotificationsPlugin()
      ..initializeHandler = (_) => initializeGate.future;
    final service = NotificationService(notificationsPlugin: plugin);
    final failure = StateError('initialize failed');

    final first = service.init();
    final second = service.init();
    final observedFailures = Future.wait<Object?>([
      first.then<Object?>((_) => null, onError: (Object error) => error),
      second.then<Object?>((_) => null, onError: (Object error) => error),
    ]);
    initializeGate.completeError(failure);

    expect(await observedFailures, [same(failure), same(failure)]);
    expect(plugin.initializeCalls, 1);
  });

  test('init posterior pode tentar novamente após falha', () async {
    final plugin = _RecordingNotificationsPlugin()
      ..initializeHandler = (call) {
        if (call == 1) {
          return Future<bool?>.error(StateError('initialize failed'));
        }
        return Future<bool?>.value(true);
      };
    final service = NotificationService(notificationsPlugin: plugin);

    await expectLater(service.init(), throwsStateError);
    await service.init();
    await service.init();

    expect(plugin.initializeCalls, 2);
  });

  test('operação antiga não limpa retry novo em andamento', () async {
    final firstGate = Completer<bool?>();
    final retryGate = Completer<bool?>();
    final retryStarted = Completer<void>();
    final plugin = _RecordingNotificationsPlugin()
      ..initializeHandler = (call) {
        if (call == 1) return firstGate.future;
        retryStarted.complete();
        return retryGate.future;
      };
    final service = NotificationService(notificationsPlugin: plugin);
    late Future<void> retry;

    final firstObserved = service.init().catchError((Object _) {
      retry = service.init();
      return retry;
    });
    firstGate.completeError(StateError('initialize failed'));
    await retryStarted.future;

    final concurrentWithRetry = service.init();
    expect(identical(concurrentWithRetry, retry), isTrue);
    expect(plugin.initializeCalls, 2);

    retryGate.complete(true);
    await Future.wait([firstObserved, retry, concurrentWithRetry]);
    expect(plugin.initializeCalls, 2);
  });

  test(
    'callback foreground é encaminhado e background não é registrado',
    () async {
      final plugin = _RecordingNotificationsPlugin();
      final service = NotificationService(notificationsPlugin: plugin);
      final received = <NotificationResponse>[];
      service.setNotificationResponseHandler((response) async {
        received.add(response);
      });
      await service.init();

      const response = NotificationResponse(
        notificationResponseType:
            NotificationResponseType.selectedNotificationAction,
        id: 85,
        actionId: cycleReminderSnoozeActionId,
        payload: 'private-action-payload',
      );
      plugin.foregroundCallback!(response);
      await Future<void>.delayed(Duration.zero);

      expect(received, [response]);
      expect(plugin.backgroundCallback, isNull);
    },
  );

  test('handler substituído depois do init é usado imediatamente', () async {
    final plugin = _RecordingNotificationsPlugin();
    final service = NotificationService(notificationsPlugin: plugin);
    var oldHandlerCalls = 0;
    final received = Completer<NotificationResponse>();
    service.setNotificationResponseHandler((_) async {
      oldHandlerCalls += 1;
    });
    await service.init();
    service.setNotificationResponseHandler((response) async {
      received.complete(response);
    });

    const response = NotificationResponse(
      notificationResponseType:
          NotificationResponseType.selectedNotificationAction,
      id: 87,
      actionId: cycleReminderSnoozeActionId,
      payload: 'private-action-payload',
    );
    plugin.foregroundCallback!(response);

    expect(await received.future, response);
    expect(oldHandlerCalls, 0);
    expect(plugin.initializeCalls, 1);
  });

  for (final zone in ['America/Sao_Paulo', 'America/New_York']) {
    test(
      'one-shots V2 preservam wall-clock ao avançar calendário em $zone',
      () async {
        final plugin = _RecordingNotificationsPlugin();
        final service = NotificationService(
          notificationsPlugin: plugin,
          deviceTimeZoneResolver: _timeZoneResolver(zone),
          isAndroidOverride: false,
          now: () => DateTime(2030, 3, 8),
        );
        for (var day = 9; day <= 10; day++) {
          expect(
            await service.scheduleMedicationNotification(
              id: day,
              title: 'Test',
              body: 'Test',
              scheduledDate: DateTime(2030, 3, day, 21, 35),
              repeatDaily: false,
              payload: 'life_os_medication_v2:opaque-id',
            ),
            isTrue,
          );
        }
        expect(plugin.lastDateTimeComponents, isNull);
        expect(plugin.lastPayload, 'life_os_medication_v2:opaque-id');
        expect(plugin.scheduledDates.map((date) => date.hour), [21, 21]);
        expect(plugin.scheduledDates.map((date) => date.minute), [35, 35]);
        expect(plugin.scheduledDates.map((date) => date.day), [9, 10]);
        expect(
          plugin.scheduledDates.map((date) => date.location.name),
          everyElement(zone),
        );
        expect(
          plugin.scheduledDates.last
              .difference(plugin.scheduledDates.first)
              .inHours,
          zone == 'America/New_York' ? 23 : 24,
        );
      },
    );
  }

  test(
    'lifecycle real materializa finitos no plugin sem recurrence e respeita end bound',
    () async {
      final db = AppDatabase(executor: NativeDatabase.memory());
      addTearDown(db.closeDatabase);
      await db
          .into(db.medications)
          .insert(
            MedicationsCompanion.insert(
              firestoreId: 'finite',
              name: 'Test',
              startDate: DateTime(2030, 3, 9, 21, 35),
              endDate: Value(DateTime(2030, 3, 11)),
            ),
          );
      final plugin = _RecordingNotificationsPlugin()
        ..pending.add(
          PendingNotificationRequest(
            notificationIdForMedication('finite'),
            'Hora do medicamento 💊',
            'Está na hora de tomar: Test',
            null,
          ),
        );
      final clock = DateTime(2030, 3, 9, 12);
      final service = NotificationService(
        notificationsPlugin: plugin,
        deviceTimeZoneResolver: _timeZoneResolver('America/New_York'),
        isAndroidOverride: false,
        now: () => clock,
      );
      final lifecycle = MedicationReminderLifecycleService(
        db,
        service,
        now: () => clock,
      );
      final result = await lifecycle.rebuildMedicationReminders();
      expect(result.failed, 0);
      expect(result.scheduled, 3);
      expect(plugin.scheduleCalls, 3);
      expect(plugin.lastDateTimeComponents, isNull);
      expect(plugin.scheduledDates.map((date) => date.day), [9, 10, 11]);
      expect(plugin.scheduledDates.map((date) => date.hour), everyElement(21));
      expect(
        plugin.scheduledDates[1].difference(plugin.scheduledDates[0]).inHours,
        23,
      );
      expect(plugin.pending, hasLength(3));
      expect(
        plugin.pending.map((request) => request.payload),
        everyElement('${medicationReminderPayloadPrefix}finite'),
      );
      expect(
        plugin.cancelledIds,
        contains(notificationIdForMedication('finite')),
      );
      expect(plugin.cancelAllCalls, 0);
    },
  );

  test(
    'timezone com dia civil inexistente não desloca one-shot para o dia seguinte',
    () async {
      final plugin = _RecordingNotificationsPlugin();
      final service = NotificationService(
        notificationsPlugin: plugin,
        deviceTimeZoneResolver: _timeZoneResolver('Pacific/Apia'),
        isAndroidOverride: false,
        now: () => DateTime(2011, 12, 29),
      );
      expect(
        await service.scheduleMedicationNotification(
          id: 1,
          title: 'Test',
          body: 'Test',
          scheduledDate: DateTime(2011, 12, 30, 21),
        ),
        isFalse,
      );
      expect(plugin.scheduleCalls, 0);
    },
  );

  test('one-shot vencido não é deslocado para amanhã', () async {
    final plugin = _RecordingNotificationsPlugin();
    final service = NotificationService(
      notificationsPlugin: plugin,
      deviceTimeZoneResolver: _timeZoneResolver('UTC'),
      isAndroidOverride: false,
      now: () => DateTime(2030, 3, 10, 22),
    );
    expect(
      await service.scheduleMedicationNotification(
        id: 1,
        title: 'Test',
        body: 'Test',
        scheduledDate: DateTime(2030, 3, 10, 21),
      ),
      isFalse,
    );
    expect(plugin.scheduleCalls, 0);
  });

  test('pending requests expõe inventário nativo e propaga falha', () async {
    final plugin = _RecordingNotificationsPlugin()
      ..pending.add(
        const PendingNotificationRequest(
          1,
          'Test',
          'Test',
          'life_os_medication_v2:id',
        ),
      );
    final service = NotificationService(notificationsPlugin: plugin);
    expect((await service.pendingNotificationRequests()).single.id, 1);
    plugin.throwOnPending = true;
    await expectLater(service.pendingNotificationRequests(), throwsStateError);
  });

  test(
    'cancelamento individual verificável propaga erro, wrapper continua best effort',
    () async {
      final plugin = _RecordingNotificationsPlugin()..throwOnCancel = true;
      final service = NotificationService(notificationsPlugin: plugin);
      await expectLater(service.cancelNotificationOrThrow(1), throwsStateError);
      await expectLater(service.cancelNotification(1), completes);
      expect(plugin.cancelledIds, [1, 1]);
      plugin.throwOnCancel = false;
      await expectLater(service.cancelNotificationOrThrow(2), completes);
      expect(plugin.cancelledIds, [1, 1, 2]);
    },
  );

  test('launch details são expostos pelo owner do plugin', () async {
    const response = NotificationResponse(
      notificationResponseType:
          NotificationResponseType.selectedNotificationAction,
      id: 86,
      actionId: cycleReminderSnoozeActionId,
    );
    final plugin = _RecordingNotificationsPlugin()
      ..launchDetails = const NotificationAppLaunchDetails(
        true,
        notificationResponse: response,
      );
    final service = NotificationService(notificationsPlugin: plugin);

    final details = await service.getNotificationAppLaunchDetails();

    expect(details?.didNotificationLaunchApp, isTrue);
    expect(details?.notificationResponse, response);
  });
}
