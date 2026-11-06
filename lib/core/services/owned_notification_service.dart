import 'dart:convert';
import 'package:crypto/crypto.dart';
// ignore_for_file: prefer_initializing_formals
import 'dart:io';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../database/local_database_identity.dart';
import 'notification_service.dart';
import 'notification_preferences.dart';
import 'native_notification_registry.dart';

/// Captured owner facade. It never forwards a global cancel. Numeric IDs are
/// reserved durably; Android tags isolate legacy id-only cancellation too.
class OwnedNotificationService implements NotificationService {
  OwnedNotificationService({
    required this.identity,
    required NotificationService native,
    required bool Function() isCurrent,
    Future<NativeNotificationRegistry> Function()? registry,
    bool? android,
    Future<NotificationPreferences> Function()? preferences,
  }) : _native = native,
       _isCurrent = isCurrent,
       _registry = registry ?? NativeNotificationRegistry.open,
       _android = android ?? Platform.isAndroid,
       _preferences =
           preferences ?? NotificationPreferencesStore.scoped(identity).load {
    if (!identity.isBound)
      throw ArgumentError('LOCAL_GENERATION_BINDING_REQUIRED');
  }
  final LocalDatabaseIdentity identity;
  final NotificationService _native;
  final bool Function() _isCurrent;
  final Future<NativeNotificationRegistry> Function() _registry;
  final Future<NotificationPreferences> Function() _preferences;
  final bool _android;
  Future<T> _serial<T>(Future<T> Function() action) =>
      NativeNotificationEffectGate.run(action);
  void _current() {
    if (!_android || !_isCurrent()) throw StateError('NATIVE_SCOPE_CLOSED');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('UNSCOPED_NOTIFICATION_API_REFUSED');
  @override
  Future<void> init() async {
    _current();
    await _native.init();
    _current();
  }

  bool _enabled(NotificationPreferences p, String? key) =>
      p.allNotifications &&
      switch (key) {
        NotificationPreferenceKeys.studyReminders => p.studyReminders,
        NotificationPreferenceKeys.habitReminders => p.habitReminders,
        NotificationPreferenceKeys.medicationReminders => p.medicationReminders,
        null || NotificationPreferenceKeys.allNotifications => true,
        _ => false,
      };
  @override
  Future<bool> requestPermissions({String? preferenceKey}) async {
    _current();
    final preferences = await _preferences();
    _current();
    if (!_enabled(preferences, preferenceKey)) return false;
    final allowed = await _native.requestOwnedPermissions();
    _current();
    return allowed;
  }

  @override
  Future<bool> requestExactAlarmPermission() async {
    _current();
    final ok = await _native.requestExactAlarmPermission();
    _current();
    return ok;
  }

  Future<bool> _schedule(
    int logicalId,
    String? payload,
    String kind,
    String title,
    String body,
    DateTime date, {
    bool repeatDaily = false,
    int? weekday,
    bool done = false,
    bool snooze = false,
    bool immediate = false,
    String? preferenceKey,
  }) => _serial(() async {
    _current();
    final registry = await _registry();
    _current();
    final preferences = await _preferences();
    _current();
    if (!_enabled(
      preferences,
      preferenceKey ??
          (kind == 'medication'
              ? NotificationPreferenceKeys.medicationReminders
              : null),
    ))
      return false;
    final pending = await _native.pendingNotificationRequests();
    _current();
    final active = await _native.activeNotificationRequests();
    _current();
    final known = registry.records(identity).map((r) => r.payload).toSet();
    if (pending.any(
      (p) =>
          p.payload?.startsWith(ownedNotificationPrefix) == true &&
          p.payload!.contains(identity.namespace) &&
          !known.contains(
            p.payload == null
                ? null
                : sha256.convert(utf8.encode(p.payload!)).toString(),
          ),
    ))
      throw StateError('NATIVE_UNMANIFESTED_OWNER');
    final row = registry.reserve(identity, logicalId, payload, {
      ...pending.map((p) => p.id),
      ...active.map((p) => p.id).whereType<int>(),
    });
    try {
      final ok = await _native.scheduleOwnedNotification(
        id: row.id,
        tag: row.tag,
        payload: row.deliveryPayload!,
        canSend: () => _isCurrent() && !registry.sealed(identity),
        kind: kind,
        title: title,
        body: body,
        scheduledDate: date,
        repeatDaily: repeatDaily,
        weekday: weekday,
        includeDoneAction: done,
        snooze: snooze,
        immediate: immediate,
      );
      if (!ok || !_isCurrent()) {
        registry.state(row, 'UNKNOWN');
        await _cancelRow(registry, row);
        return false;
      }
      registry.state(row, 'ACTIVE');
      return true;
    } catch (_) {
      registry.state(row, 'UNKNOWN');
      rethrow;
    }
  });
  Future<void> _cancelRow(
    NativeNotificationRegistry registry,
    NativeNotificationOwnership row,
  ) async {
    // Cleanup capability is the captured durable owner, not the current UID.
    final pending = await _native.pendingNotificationRequests();
    final active = await _native.activeNotificationRequests();
    if (pending.any(
          (p) => p.id == row.id && !registry.matches(row, p.payload),
        ) ||
        active.any((p) => p.id == row.id && p.tag != row.tag)) {
      registry.state(row, 'UNKNOWN');
      throw StateError('NATIVE_OWNERSHIP_UNKNOWN');
    }
    await _native.cancelOwnedNotification(row.id, row.tag);
    if ((await _native.pendingNotificationRequests()).any(
          (p) => p.id == row.id && registry.matches(row, p.payload),
        ) ||
        (await _native.activeNotificationRequests()).any(
          (p) => p.id == row.id && p.tag == row.tag,
        )) {
      registry.state(row, 'UNKNOWN');
      throw StateError('NATIVE_CANCELLATION_UNKNOWN');
    }
    registry.state(row, 'RETIRED');
  }

  @override
  Future<bool> scheduleMedicationNotification({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledDate,
    String? preferenceKey,
    bool repeatDaily = false,
    String? payload,
  }) => _schedule(
    id,
    payload,
    'medication',
    title,
    body,
    scheduledDate,
    repeatDaily: repeatDaily,
    preferenceKey: preferenceKey,
  );
  @override
  Future<bool> scheduleCycleReminderNotification({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledDate,
    required DateTimeComponents matchDateTimeComponents,
    required String payload,
    bool includeDoneAction = false,
  }) => _schedule(
    id,
    payload,
    'cycle',
    title,
    body,
    scheduledDate,
    repeatDaily: matchDateTimeComponents == DateTimeComponents.time,
    weekday: matchDateTimeComponents == DateTimeComponents.dayOfWeekAndTime
        ? scheduledDate.weekday
        : null,
    done: includeDoneAction,
  );
  @override
  Future<bool> scheduleCycleReminderSnoozeNotification({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledDate,
    required String payload,
    bool includeDoneAction = false,
  }) => _schedule(
    id,
    payload,
    'cycle',
    title,
    body,
    scheduledDate,
    done: includeDoneAction,
    snooze: true,
  );
  @override
  Future<void> showNotification(
    String title,
    String body, {
    String? preferenceKey,
    int? id,
  }) async {
    if (!await _schedule(
      id ?? 0,
      null,
      'general',
      title,
      body,
      DateTime.now(),
      immediate: true,
      preferenceKey: preferenceKey,
    ))
      throw StateError('NATIVE_SCHEDULE_UNCONFIRMED');
  }

  @override
  Future<List<PendingNotificationRequest>> pendingNotificationRequests() async {
    _current();
    final registry = await _registry();
    _current();
    final records = {for (final r in registry.records(identity)) r.id: r};
    final pending = await _native.pendingNotificationRequests();
    _current();
    final result = <PendingNotificationRequest>[];
    for (final p in pending) {
      final r = records[p.id];
      if (r == null) continue;
      if (!registry.matches(r, p.payload) || r.state == 'RETIRED')
        throw StateError('NATIVE_OWNERSHIP_UNKNOWN');
      result.add(
        PendingNotificationRequest(
          r.logicalId,
          p.title,
          p.body,
          registry.originalPayload(r, p.payload),
        ),
      );
    }
    return result;
  }

  @override
  Future<void> cancelNotificationOrThrow(int id) => _serial(() async {
    if (!_android) throw StateError('NATIVE_SCOPE_CLOSED');
    final registry = await _registry();
    for (final row
        in registry
            .records(identity)
            .where((r) => r.logicalId == id && r.state != 'RETIRED')) {
      await _cancelRow(registry, row);
    }
  });
  @override
  Future<void> cancelNotification(int id) => cancelNotificationOrThrow(id);
  @override
  Future<bool> cancelCycleReminderNotification(int id) async {
    try {
      await cancelNotificationOrThrow(id);
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> cancelAllNotificationsOrThrow() => _serial(() async {
    if (!_android) throw StateError('NATIVE_SCOPE_CLOSED');
    final registry = await _registry();
    for (final row
        in registry.records(identity).where((r) => r.state != 'RETIRED')) {
      await _cancelRow(registry, row);
    }
  });
  @override
  Future<void> cancelAllNotifications() => cancelAllNotificationsOrThrow();
  Future<void> retire() => _serial(() async {
    if (!_android) throw StateError('NATIVE_SCOPE_CLOSED');
    final registry = await _registry();
    registry.seal(identity);
    for (final row
        in registry.records(identity).where((r) => r.state != 'RETIRED')) {
      await _cancelRow(registry, row);
    }
    if (registry.records(identity).any((r) => r.state != 'RETIRED'))
      throw StateError('NATIVE_CLEANUP_INCOMPLETE');
  });
  Future<NotificationResponse?> _response(
    NotificationResponse? response,
  ) async {
    if (response == null || !_isCurrent()) return null;
    final registry = await _registry();
    if (!_isCurrent() || registry.sealed(identity)) return null;
    final rows = registry
        .records(identity)
        .where(
          (r) =>
              r.id == response.id &&
              registry.matches(r, response.payload) &&
              r.state == 'ACTIVE',
        );
    if (rows.length != 1) return null;
    final row = rows.single;
    return NotificationResponse(
      notificationResponseType: response.notificationResponseType,
      id: row.logicalId,
      actionId: response.actionId,
      input: response.input,
      payload: registry.originalPayload(row, response.payload),
      data: response.data,
    );
  }

  @override
  void setNotificationResponseHandler(NotificationResponseHandler? handler) {
    if (handler == null)
      return; // An old facade cannot remove B's current handler.
    _current();
    _native.setNotificationResponseHandler((response) async {
      final owned = await _response(response);
      if (owned != null && _isCurrent()) await handler(owned);
    });
  }

  @override
  Future<NotificationAppLaunchDetails?>
  getNotificationAppLaunchDetails() async {
    _current();
    final details = await _native.getNotificationAppLaunchDetails();
    _current();
    final response = await _response(details?.notificationResponse);
    return NotificationAppLaunchDetails(
      response != null && details?.didNotificationLaunchApp == true,
      notificationResponse: response,
    );
  }
}
