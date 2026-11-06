import 'native_notification_registry.dart';
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:life_os/core/services/notification_preferences.dart';
import 'package:life_os/core/utils/app_logger.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

const String cycleReminderSnoozeActionId = 'cycle_reminder_snooze';
const String cycleReminderDoneActionId = 'cycle_reminder_done';
const String cycleReminderActionCategoryId =
    'life_os_personal_reminder_actions_v1';
const String cycleReminderPillActionCategoryId =
    'life_os_pill_reminder_actions_v1';

typedef NotificationResponseHandler =
    Future<void> Function(NotificationResponse response);
typedef DeviceTimeZoneResolver = Future<String> Function();

Future<String> _resolveDeviceTimeZone() async {
  final timeZone = await FlutterTimezone.getLocalTimezone();
  return timeZone.identifier;
}

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
    DeviceTimeZoneResolver? deviceTimeZoneResolver,
    DateTime Function()? now,
    this.isAndroidOverride,
  }) : _now = now ?? DateTime.now,
       _androidPluginOverride = androidPlugin,
       _deviceTimeZoneResolver =
           deviceTimeZoneResolver ?? _resolveDeviceTimeZone,
       _notificationsPlugin =
           notificationsPlugin ?? FlutterLocalNotificationsPlugin();

  static final NotificationService instance = NotificationService();

  final FlutterLocalNotificationsPlugin _notificationsPlugin;
  final AndroidFlutterLocalNotificationsPlugin? _androidPluginOverride;
  final DeviceTimeZoneResolver _deviceTimeZoneResolver;
  final DateTime Function() _now;
  final bool? isAndroidOverride;

  bool _initialized = false;
  Future<void>? _initializationOperation;
  NotificationResponseHandler? _notificationResponseHandler;

  // ---------------------------------------------------------------------------
  // INICIALIZAÇÃO
  // ---------------------------------------------------------------------------

  Future<void> init() {
    if (_initialized) return Future<void>.value();

    final existingOperation = _initializationOperation;
    if (existingOperation != null) return existingOperation;

    late final Future<void> operation;
    operation = _initializeOnce().whenComplete(() {
      if (identical(_initializationOperation, operation)) {
        _initializationOperation = null;
      }
    });
    _initializationOperation = operation;
    return operation;
  }

  Future<void> _initializeOnce() async {
    tz.initializeTimeZones();

    const AndroidInitializationSettings androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    final DarwinInitializationSettings iosSettings =
        DarwinInitializationSettings(
          notificationCategories: <DarwinNotificationCategory>[
            DarwinNotificationCategory(
              cycleReminderPillActionCategoryId,
              actions: <DarwinNotificationAction>[
                DarwinNotificationAction.plain(
                  cycleReminderDoneActionId,
                  'Feito',
                  options: <DarwinNotificationActionOption>{
                    DarwinNotificationActionOption.foreground,
                  },
                ),
                DarwinNotificationAction.plain(
                  cycleReminderSnoozeActionId,
                  'Lembrar depois',
                  options: <DarwinNotificationActionOption>{
                    DarwinNotificationActionOption.foreground,
                  },
                ),
              ],
            ),
            DarwinNotificationCategory(
              cycleReminderActionCategoryId,
              actions: <DarwinNotificationAction>[
                DarwinNotificationAction.plain(
                  cycleReminderSnoozeActionId,
                  'Lembrar depois',
                  options: <DarwinNotificationActionOption>{
                    DarwinNotificationActionOption.foreground,
                  },
                ),
              ],
            ),
          ],
        );

    final InitializationSettings initializationSettings =
        InitializationSettings(android: androidSettings, iOS: iosSettings);

    await _notificationsPlugin.initialize(
      settings: initializationSettings,
      onDidReceiveNotificationResponse: _onNotificationResponse,
    );

    _initialized = true;
  }

  void _onNotificationResponse(NotificationResponse response) {
    final handler = _notificationResponseHandler;
    if (handler == null) return;
    unawaited(
      handler(response).catchError((_) {
        AppLogger.w('[NotificationService] Falha no callback local.');
      }),
    );
  }

  void setNotificationResponseHandler(NotificationResponseHandler? handler) {
    _notificationResponseHandler = handler;
  }

  Future<NotificationAppLaunchDetails?> getNotificationAppLaunchDetails() {
    return _notificationsPlugin.getNotificationAppLaunchDetails();
  }

  // ---------------------------------------------------------------------------
  // PERMISSÕES
  // ---------------------------------------------------------------------------

  Future<bool> requestPermissions({String? preferenceKey}) =>
      _requestPermissions(preferenceKey: preferenceKey);
  Future<bool> requestOwnedPermissions() =>
      _requestPermissions(skipLegacyPreference: true);
  Future<bool> _requestPermissions({
    String? preferenceKey,
    bool skipLegacyPreference = false,
  }) async {
    try {
      if (!skipLegacyPreference && !await _isEnabled(preferenceKey))
        return false;

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

      final actualId = id ?? Random().nextInt(100000);
      await _legacyEffect(
        actualId,
        () => _notificationsPlugin.show(
          id: actualId,
          title: title,
          body: body,
          notificationDetails: notificationDetails,
        ),
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
    String? payload,
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

      final now = _now();
      final validDate = repeatDaily
          ? nextDailyMedicationOccurrence(scheduledDate, now)
          : scheduledDate;

      if (!repeatDaily && validDate.isBefore(now)) {
        return false;
      }
      final location = await _resolveTimeZoneLocation();
      if (!repeatDaily && validDate.isBefore(_now())) return false;
      final nativeDate = _wallClockInLocation(validDate, location);
      // A timezone's skipped civil day must not move a finite alarm past its bound.
      if (!repeatDaily &&
          (nativeDate.year != validDate.year ||
              nativeDate.month != validDate.month ||
              nativeDate.day != validDate.day)) {
        return false;
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

      await _legacyEffect(
        id,
        () => _notificationsPlugin.zonedSchedule(
          id: id,
          title: title,
          body: body,
          scheduledDate: nativeDate,
          notificationDetails: notificationDetails,

          androidScheduleMode: scheduleMode,

          matchDateTimeComponents: repeatDaily ? DateTimeComponents.time : null,
          payload: payload,
        ),
      );

      return true;
    } catch (_) {
      AppLogger.w(
        '[NotificationService] Falha no agendamento local de medicamento.',
      );
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
    required String payload,
    bool includeDoneAction = false,
  }) async {
    return _scheduleCycleReminder(
      id: id,
      title: title,
      body: body,
      scheduledDate: scheduledDate,
      matchDateTimeComponents: matchDateTimeComponents,
      payload: payload,
      includeDoneAction: includeDoneAction,
    );
  }

  Future<bool> scheduleCycleReminderSnoozeNotification({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledDate,
    required String payload,
    bool includeDoneAction = false,
  }) {
    return _scheduleCycleReminder(
      id: id,
      title: title,
      body: body,
      scheduledDate: scheduledDate,
      payload: payload,
      includeDoneAction: includeDoneAction,
    );
  }

  Future<bool> _scheduleCycleReminder({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledDate,
    required String payload,
    DateTimeComponents? matchDateTimeComponents,
    bool includeDoneAction = false,
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
      final location = await _resolveTimeZoneLocation();

      final actions = includeDoneAction
          ? const <AndroidNotificationAction>[
              AndroidNotificationAction(
                cycleReminderDoneActionId,
                'Feito',
                showsUserInterface: true,
                cancelNotification: true,
              ),
              AndroidNotificationAction(
                cycleReminderSnoozeActionId,
                'Lembrar depois',
                showsUserInterface: true,
                cancelNotification: true,
              ),
            ]
          : const <AndroidNotificationAction>[
              AndroidNotificationAction(
                cycleReminderSnoozeActionId,
                'Lembrar depois',
                showsUserInterface: true,
                cancelNotification: true,
              ),
            ];
      final androidDetails = AndroidNotificationDetails(
        'cycle_personal_reminders_channel',
        'Lembretes pessoais',
        channelDescription: 'Lembretes pessoais configurados no Life OS',
        importance: Importance.max,
        priority: Priority.high,
        visibility: NotificationVisibility.private,
        actions: actions,
      );
      final notificationDetails = NotificationDetails(
        android: androidDetails,
        iOS: DarwinNotificationDetails(
          categoryIdentifier: includeDoneAction
              ? cycleReminderPillActionCategoryId
              : cycleReminderActionCategoryId,
        ),
      );

      await _legacyEffect(
        id,
        () => _notificationsPlugin.zonedSchedule(
          id: id,
          title: title,
          body: body,
          scheduledDate: _wallClockInLocation(scheduledDate, location),
          notificationDetails: notificationDetails,
          androidScheduleMode: scheduleMode,
          matchDateTimeComponents: matchDateTimeComponents,
          payload: payload,
        ),
      );

      return true;
    } catch (_) {
      AppLogger.w(
        '[NotificationService] Falha no agendamento local de lembrete.',
      );
      return false;
    }
  }

  Future<bool> cancelCycleReminderNotification(int id) async {
    try {
      await init();
      await _legacyEffect(id, () => _notificationsPlugin.cancel(id: id));
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
      await cancelNotificationOrThrow(id);
    } catch (_) {
      // Não propagar erro para o fluxo principal.
    }
  }

  Future<void> cancelNotificationOrThrow(int id) async {
    await init();
    await _legacyEffect(id, () => _notificationsPlugin.cancel(id: id));
  }

  Future<List<PendingNotificationRequest>> pendingNotificationRequests() async {
    await init();
    return _notificationsPlugin.pendingNotificationRequests();
  }

  // ---------------------------------------------------------------------------
  // CANCELAR TODAS
  // ---------------------------------------------------------------------------

  Future<void> cancelAllNotifications() async {
    try {
      await cancelAllNotificationsOrThrow();
    } catch (_) {
      // Não propagar erro para o fluxo principal.
    }
  }

  Future<void> cancelAllNotificationsOrThrow() async {
    await init();
    // Broad cancelAll can erase a later generation. Enumerate legacy entries;
    // bound owners use tags and their own durable registry/facade.
    final pending = await _notificationsPlugin.pendingNotificationRequests();
    final active = await _notificationsPlugin.getActiveNotifications();
    final protectedIds = {
      ...pending
          .where((p) => p.payload?.startsWith('life_os_owned_v2:') == true)
          .map((p) => p.id),
      ...active
          .where((p) => p.tag?.startsWith('lifeos:') == true)
          .map((p) => p.id)
          .whereType<int>(),
    };
    for (final id in {
      ...pending.map((p) => p.id),
      ...active.map((p) => p.id).whereType<int>(),
    }) {
      if (!protectedIds.contains(id))
        await _legacyEffect(id, () => _notificationsPlugin.cancel(id: id));
    }
  }

  Future<T> _legacyEffect<T>(
    int id,
    Future<T> Function() effect,
  ) => NativeNotificationEffectGate.run(() async {
    final pending = await _notificationsPlugin.pendingNotificationRequests();
    final active = await _notificationsPlugin.getActiveNotifications();
    if (pending.any(
          (p) =>
              p.id == id &&
              p.payload?.startsWith(ownedNotificationPrefix) == true,
        ) ||
        active.any((p) => p.id == id && p.tag?.startsWith('lifeos:') == true)) {
      throw StateError('NATIVE_GENERATIONAL_OWNER_PROTECTED');
    }
    return effect();
  });

  Future<List<ActiveNotification>> activeNotificationRequests() async {
    await init();
    return _notificationsPlugin.getActiveNotifications();
  }

  Future<void> cancelOwnedNotification(int id, String tag) async {
    await init();
    await _notificationsPlugin.cancel(id: id, tag: tag);
  }

  Future<bool> scheduleOwnedNotification({
    required int id,
    required String tag,
    required String payload,
    required String kind,
    required String title,
    required String body,
    required DateTime scheduledDate,
    bool repeatDaily = false,
    int? weekday,
    bool includeDoneAction = false,
    bool snooze = false,
    bool immediate = false,
    bool Function()? canSend,
  }) async {
    void permit() {
      if (canSend?.call() != true) throw StateError('NATIVE_SCOPE_CLOSED');
    }

    permit();
    await init();
    permit();
    if (!_isAndroid) throw StateError('OWNED_NATIVE_PLATFORM_CLOSED');
    final mode = await _canScheduleExactNotifications()
        ? AndroidScheduleMode.exactAllowWhileIdle
        : AndroidScheduleMode.inexactAllowWhileIdle;
    permit();
    final location = await _resolveTimeZoneLocation();
    permit();
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        'life_os_owned_notifications',
        'Lembretes Life OS',
        tag: tag,
        importance: Importance.max,
        priority: Priority.high,
        actions: kind == 'cycle'
            ? [
                const AndroidNotificationAction(
                  cycleReminderSnoozeActionId,
                  'Adiar',
                  showsUserInterface: true,
                  cancelNotification: true,
                ),
                if (includeDoneAction)
                  const AndroidNotificationAction(
                    cycleReminderDoneActionId,
                    'Concluído',
                    showsUserInterface: true,
                    cancelNotification: true,
                  ),
              ]
            : null,
      ),
    );
    permit();
    if (immediate) {
      await _notificationsPlugin.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: details,
        payload: payload,
      );
      return true;
    }
    final date = repeatDaily
        ? nextDailyMedicationOccurrence(scheduledDate, _now())
        : scheduledDate;
    permit();
    await _notificationsPlugin.zonedSchedule(
      id: id,
      title: title,
      body: body,
      scheduledDate: _wallClockInLocation(date, location),
      notificationDetails: details,
      payload: payload,
      androidScheduleMode: mode,
      matchDateTimeComponents: weekday != null
          ? DateTimeComponents.dayOfWeekAndTime
          : repeatDaily
          ? DateTimeComponents.time
          : null,
    );
    return true;
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

  Future<tz.Location> _resolveTimeZoneLocation() async {
    final identifier = (await _deviceTimeZoneResolver()).trim();
    if (identifier.isEmpty) {
      throw StateError('DEVICE_TIME_ZONE_UNAVAILABLE');
    }
    return tz.getLocation(identifier);
  }

  tz.TZDateTime _wallClockInLocation(DateTime value, tz.Location location) {
    return tz.TZDateTime(
      location,
      value.year,
      value.month,
      value.day,
      value.hour,
      value.minute,
      value.second,
      value.millisecond,
      value.microsecond,
    );
  }
}
