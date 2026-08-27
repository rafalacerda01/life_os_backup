import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/core/services/notification_preferences.dart';
import 'package:life_os/core/services/notification_service.dart';
import 'package:life_os/core/utils/app_logger.dart';
import 'package:life_os/features/health/presentation/cycle/cycle_reminder_preferences.dart';
import 'package:life_os/features/settings/presentation/providers/notification_provider.dart';

import 'cycle_reminder_action_security.dart';
import 'cycle_reminder_notification_lifecycle.dart';
import 'cycle_reminder_mutation_gate.dart';
import 'cycle_reminder_operation_epoch.dart';
import 'cycle_reminder_session_authority.dart';
import 'cycle_reminder_session_cleanup.dart';

const Duration cycleReminderSnoozeDuration = Duration(minutes: 15);

typedef CycleReminderGlobalPreferenceLoader = Future<bool> Function();
typedef CycleReminderActionPreferencesLoader =
    Future<CycleReminderPreferences?> Function(String userId);

abstract interface class CycleReminderActionNotificationGateway {
  Future<bool> cancel(int id);

  Future<bool> scheduleSnooze({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledDate,
    required String payload,
  });
}

class NotificationServiceCycleReminderActionGateway
    implements CycleReminderActionNotificationGateway {
  const NotificationServiceCycleReminderActionGateway(this._service);

  final NotificationService _service;

  @override
  Future<bool> cancel(int id) => _service.cancelCycleReminderNotification(id);

  @override
  Future<bool> scheduleSnooze({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledDate,
    required String payload,
  }) {
    return _service.scheduleCycleReminderSnoozeNotification(
      id: id,
      title: title,
      body: body,
      scheduledDate: scheduledDate,
      payload: payload,
    );
  }
}

abstract interface class CycleReminderActionSessionCoordinator {
  Future<void> handle(NotificationResponse response);

  Future<void> onSessionPrepared(String userId);

  void onSessionCleared();
}

class CycleReminderActionCoordinator
    implements CycleReminderActionSessionCoordinator {
  factory CycleReminderActionCoordinator({
    required CycleReminderUserIdReader currentUserId,
    required CycleReminderActionTokenReader tokenStore,
    required CycleReminderActionPreferencesLoader loadPreferences,
    required CycleReminderGlobalPreferenceLoader loadGlobalNotifications,
    required CycleReminderOperationEpoch operationEpoch,
    required CycleReminderSessionAuthority sessionAuthority,
    required CycleReminderMutationGate mutationGate,
    required CycleReminderNotificationLifecycle lifecycle,
    required CycleReminderActionNotificationGateway notificationGateway,
    CycleReminderActionPayloadCodec codec =
        const CycleReminderActionPayloadCodec(),
    DateTime Function()? clock,
    void Function(String message)? warningLogger,
  }) {
    return CycleReminderActionCoordinator._(
      currentUserId,
      tokenStore,
      loadPreferences,
      loadGlobalNotifications,
      operationEpoch,
      sessionAuthority,
      mutationGate,
      lifecycle,
      notificationGateway,
      codec,
      clock ?? DateTime.now,
      warningLogger ?? AppLogger.w,
    );
  }

  CycleReminderActionCoordinator._(
    this._currentUserId,
    this._tokenStore,
    this._loadPreferences,
    this._loadGlobalNotifications,
    this._operationEpoch,
    this._sessionAuthority,
    this._mutationGate,
    this._lifecycle,
    this._notificationGateway,
    this._codec,
    this._clock,
    this._warningLogger,
  );

  final CycleReminderUserIdReader _currentUserId;
  final CycleReminderActionTokenReader _tokenStore;
  final CycleReminderActionPreferencesLoader _loadPreferences;
  final CycleReminderGlobalPreferenceLoader _loadGlobalNotifications;
  final CycleReminderOperationEpoch _operationEpoch;
  final CycleReminderSessionAuthority _sessionAuthority;
  final CycleReminderMutationGate _mutationGate;
  final CycleReminderNotificationLifecycle _lifecycle;
  final CycleReminderActionNotificationGateway _notificationGateway;
  final CycleReminderActionPayloadCodec _codec;
  final DateTime Function() _clock;
  final void Function(String message) _warningLogger;

  Future<void> _tail = Future<void>.value();
  NotificationResponse? _pending;
  bool _canBufferPendingAction = true;

  @override
  Future<void> handle(NotificationResponse response) {
    if (response.actionId != cycleReminderSnoozeActionId) {
      return Future<void>.value();
    }

    final preparedUserId = _sessionAuthority.preparedUserId;
    if (preparedUserId == null) {
      if (_canBufferPendingAction) {
        _pending = response;
      }
      return Future<void>.value();
    }
    return _enqueue(() => _process(preparedUserId, response));
  }

  @override
  Future<void> onSessionPrepared(String userId) {
    final normalizedUserId = userId.trim();
    if (normalizedUserId.isEmpty) return Future<void>.value();

    _sessionAuthority.prepare(normalizedUserId);
    _canBufferPendingAction = true;
    final pending = _pending;
    _pending = null;
    if (pending == null) return Future<void>.value();
    return _enqueue(() => _process(normalizedUserId, pending));
  }

  @override
  void onSessionCleared() {
    final previousUserId = _sessionAuthority.clear();
    if (previousUserId != null) {
      _operationEpoch.invalidate(previousUserId);
    }
    _pending = null;
    _canBufferPendingAction = false;
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    _tail = _tail.then((_) async {
      try {
        await operation();
      } on Object {
        _warningLogger(
          '[CycleReminderAction] Ação local ignorada com segurança.',
        );
      }
    });
    return _tail;
  }

  Future<void> _process(String userId, NotificationResponse response) async {
    if (!_isCurrentSession(userId)) return;
    final generation = _operationEpoch.snapshot(userId);

    final payload = _codec.decode(response.payload);
    final notificationId = response.id;
    if (payload == null || notificationId == null) return;

    final storedToken = await _tokenStore.load(userId);
    if (!_isCurrentOperation(userId, generation) ||
        storedToken == null ||
        !constantTimeTokenEquals(storedToken, payload.token)) {
      return;
    }

    if (!cycleReminderNotificationIds(userId).contains(notificationId)) {
      return;
    }

    final preferences = await _loadPreferences(userId);
    if (!_isCurrentOperation(userId, generation)) return;

    final globalEnabled = await _loadGlobalNotifications();
    if (!_isCurrentOperation(userId, generation)) return;

    if (preferences == null || !preferences.enabled || !globalEnabled) {
      await _mutationGate.run(userId, () async {
        if (!_isCurrentOperation(userId, generation)) return;
        await _lifecycle.cancelAllCycleReminders(userId);
      });
      return;
    }

    final snoozeId = cycleReminderNotificationId(
      userId,
      cycleReminderSnoozeSlot,
    );
    final content = cycleReminderNotificationPayload(preferences);
    final authenticatedPayload = _codec.encode(
      CycleReminderActionPayload(storedToken),
    );

    if (!_isCurrentOperation(userId, generation)) return;
    await _mutationGate.run(userId, () async {
      if (!_isCurrentOperation(userId, generation)) return;

      await _notificationGateway.cancel(snoozeId);
      if (!_isCurrentOperation(userId, generation)) return;

      await _notificationGateway.scheduleSnooze(
        id: snoozeId,
        title: content.title,
        body: content.body,
        scheduledDate: _clock().add(cycleReminderSnoozeDuration),
        payload: authenticatedPayload,
      );

      if (!_operationEpoch.isCurrent(userId, generation)) {
        await _notificationGateway.cancel(snoozeId);
        return;
      }
      if (!_isCurrentSession(userId)) {
        await _lifecycle.cancelAllCycleReminders(userId);
      }
    });
  }

  bool _isCurrentOperation(String userId, int generation) {
    return _operationEpoch.isCurrent(userId, generation) &&
        _isCurrentSession(userId);
  }

  bool _isCurrentSession(String userId) {
    return _sessionAuthority.isPreparedFor(userId) &&
        _currentUserId() == userId;
  }
}

final cycleReminderActionCoordinatorProvider =
    Provider<CycleReminderActionSessionCoordinator>((ref) {
      final notificationStore = ref.watch(notificationPreferencesStoreProvider);
      final notificationService = ref.watch(notificationServiceProvider);
      return CycleReminderActionCoordinator(
        currentUserId: ref.watch(cycleReminderUserIdReaderProvider),
        tokenStore: ref.watch(cycleReminderActionTokenStoreProvider),
        loadPreferences: ref.watch(cycleReminderPreferencesStoreProvider).load,
        loadGlobalNotifications: () async {
          final preferences = await notificationStore.load();
          return preferences.allNotifications;
        },
        operationEpoch: ref.watch(cycleReminderOperationEpochProvider),
        sessionAuthority: ref.watch(cycleReminderSessionAuthorityProvider),
        mutationGate: ref.watch(cycleReminderMutationGateProvider),
        lifecycle: ref.watch(cycleReminderNotificationLifecycleProvider),
        notificationGateway: NotificationServiceCycleReminderActionGateway(
          notificationService,
        ),
      );
    });

final cycleReminderSessionCleanupProvider =
    Provider<CycleReminderSessionCleanup>((ref) {
      return CycleReminderSessionCleanup(
        ref.watch(cycleReminderMutationGateProvider),
        ref.watch(cycleReminderNotificationLifecycleProvider),
      );
    });
