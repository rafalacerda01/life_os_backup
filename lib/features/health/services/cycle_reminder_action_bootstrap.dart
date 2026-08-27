import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/core/services/notification_service.dart';
import 'package:life_os/core/utils/app_logger.dart';
import 'package:life_os/features/settings/presentation/providers/notification_provider.dart';

import 'cycle_reminder_action_coordinator.dart';

typedef CycleReminderBootstrapRetry = Future<void> Function();
typedef CycleReminderBootstrapRetryScheduler =
    void Function(CycleReminderBootstrapRetry retry);

void _scheduleCycleReminderBootstrapRetry(CycleReminderBootstrapRetry retry) {
  scheduleMicrotask(() => unawaited(retry()));
}

class CycleReminderActionBootstrap {
  CycleReminderActionBootstrap(
    this._service,
    this._coordinator, {
    CycleReminderBootstrapRetryScheduler? retryScheduler,
  }) : _retryScheduler = retryScheduler ?? _scheduleCycleReminderBootstrapRetry;

  static const int _maximumAttempts = 2;

  final NotificationService _service;
  final CycleReminderActionSessionCoordinator _coordinator;
  final CycleReminderBootstrapRetryScheduler _retryScheduler;

  Future<void>? _startOperation;
  int _attempts = 0;
  bool _started = false;
  bool _handlerRegistered = false;
  bool _launchActionDispatched = false;
  bool _retryScheduled = false;
  bool _disposed = false;

  Future<void> start() {
    if (_started || _disposed || _attempts >= _maximumAttempts) {
      return Future<void>.value();
    }

    final existingOperation = _startOperation;
    if (existingOperation != null) return existingOperation;

    if (!_handlerRegistered) {
      _service.setNotificationResponseHandler(_coordinator.handle);
      _handlerRegistered = true;
    }

    _attempts += 1;
    late final Future<void> operation;
    operation = _startOnce().whenComplete(() {
      if (identical(_startOperation, operation)) {
        _startOperation = null;
      }
      if (!_started) _scheduleRetry();
    });
    _startOperation = operation;
    return operation;
  }

  Future<void> _startOnce() async {
    try {
      await _service.init();
      if (_disposed) return;

      final launchDetails = await _service.getNotificationAppLaunchDetails();
      if (_disposed) return;

      final response = launchDetails?.notificationResponse;
      if (launchDetails?.didNotificationLaunchApp == true &&
          response != null &&
          response.actionId == cycleReminderSnoozeActionId &&
          !_launchActionDispatched) {
        _launchActionDispatched = true;
        await _coordinator.handle(response);
      }
      if (!_disposed) _started = true;
    } on Object {
      AppLogger.w(
        '[CycleReminderAction] Falha no bootstrap local de notificações.',
      );
    }
  }

  void _scheduleRetry() {
    if (_started ||
        _disposed ||
        _retryScheduled ||
        _attempts >= _maximumAttempts) {
      return;
    }

    _retryScheduled = true;
    _retryScheduler(() async {
      _retryScheduled = false;
      if (_started || _disposed) return;
      await start();
    });
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _retryScheduled = false;
    _handlerRegistered = false;
    _service.setNotificationResponseHandler(null);
  }
}

final cycleReminderActionBootstrapProvider =
    Provider<CycleReminderActionBootstrap>((ref) {
      final service = ref.watch(notificationServiceProvider);
      final bootstrap = CycleReminderActionBootstrap(
        service,
        ref.watch(cycleReminderActionCoordinatorProvider),
      );
      unawaited(bootstrap.start());
      ref.onDispose(bootstrap.dispose);
      return bootstrap;
    });
