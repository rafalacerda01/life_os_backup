import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/services/notification_service.dart';
import 'package:life_os/features/health/services/cycle_reminder_action_bootstrap.dart';
import 'package:life_os/features/health/services/cycle_reminder_action_coordinator.dart';
import 'package:life_os/features/settings/presentation/providers/notification_provider.dart';

class _BootstrapNotificationService extends NotificationService {
  int initCalls = 0;
  int launchDetailCalls = 0;
  int handlerRegistrations = 0;
  int handlerClears = 0;
  NotificationResponseHandler? handler;
  NotificationAppLaunchDetails? launchDetails;
  Future<void> Function(int call)? initHandler;
  Future<NotificationAppLaunchDetails?> Function(int call)?
  launchDetailsHandler;

  @override
  Future<void> init() async {
    initCalls += 1;
    final callback = initHandler;
    if (callback != null) await callback(initCalls);
  }

  @override
  void setNotificationResponseHandler(NotificationResponseHandler? handler) {
    this.handler = handler;
    if (handler == null) {
      handlerClears += 1;
    } else {
      handlerRegistrations += 1;
    }
  }

  @override
  Future<NotificationAppLaunchDetails?>
  getNotificationAppLaunchDetails() async {
    launchDetailCalls += 1;
    final callback = launchDetailsHandler;
    if (callback != null) return callback(launchDetailCalls);
    return launchDetails;
  }

  Future<void> emit(NotificationResponse response) async {
    final currentHandler = handler;
    if (currentHandler != null) await currentHandler(response);
  }
}

class _ManualRetryScheduler {
  final List<CycleReminderBootstrapRetry> _pending =
      <CycleReminderBootstrapRetry>[];

  int get pendingCount => _pending.length;

  void schedule(CycleReminderBootstrapRetry retry) {
    _pending.add(retry);
  }

  Future<void> runNext() {
    return _pending.removeAt(0)();
  }
}

class _RecordingCoordinator implements CycleReminderActionSessionCoordinator {
  final List<NotificationResponse> responses = <NotificationResponse>[];
  final List<String> preparedUsers = <String>[];
  int clearedSessions = 0;
  Future<void> Function(NotificationResponse response)? handleCallback;

  @override
  Future<void> handle(NotificationResponse response) async {
    responses.add(response);
    final callback = handleCallback;
    if (callback != null) await callback(response);
  }

  @override
  Future<void> onSessionPrepared(String userId) async {
    preparedUsers.add(userId);
  }

  @override
  void onSessionCleared() {
    clearedSessions += 1;
  }
}

class _PendingCoordinator implements CycleReminderActionSessionCoordinator {
  NotificationResponse? pending;
  int received = 0;
  int processed = 0;
  bool prepared = false;

  @override
  Future<void> handle(NotificationResponse response) async {
    received += 1;
    if (prepared) {
      processed += 1;
    } else {
      pending = response;
    }
  }

  @override
  Future<void> onSessionPrepared(String userId) async {
    prepared = true;
    if (pending != null) {
      pending = null;
      processed += 1;
    }
  }

  @override
  void onSessionCleared() {
    prepared = false;
    pending = null;
  }
}

void main() {
  const actionResponse = NotificationResponse(
    notificationResponseType:
        NotificationResponseType.selectedNotificationAction,
    id: 1,
    actionId: cycleReminderSnoozeActionId,
    payload: 'opaque',
  );

  test('bootstrap registra handler e encaminha foreground response', () async {
    final service = _BootstrapNotificationService();
    final coordinator = _RecordingCoordinator();
    final bootstrap = CycleReminderActionBootstrap(service, coordinator);

    await bootstrap.start();
    await service.emit(actionResponse);

    expect(service.initCalls, 1);
    expect(service.handlerRegistrations, 1);
    expect(coordinator.responses, [actionResponse]);
  });

  test('provider de produção dispara retry real após falha inicial', () async {
    final retryStarted = Completer<void>();
    final service = _BootstrapNotificationService()
      ..initHandler = (call) async {
        if (call == 1) throw StateError('init failed');
        retryStarted.complete();
      }
      ..launchDetails = const NotificationAppLaunchDetails(false);
    final container = ProviderContainer(
      overrides: [
        notificationServiceProvider.overrideWithValue(service),
        cycleReminderActionCoordinatorProvider.overrideWithValue(
          _RecordingCoordinator(),
        ),
      ],
    );
    addTearDown(container.dispose);

    final bootstrap = container.read(cycleReminderActionBootstrapProvider);
    await retryStarted.future;
    await bootstrap.start();

    expect(service.initCalls, 2);
    expect(service.launchDetailCalls, 1);
  });

  test('duas chamadas concorrentes compartilham start real', () async {
    final initGate = Completer<void>();
    final service = _BootstrapNotificationService()
      ..initHandler = (_) => initGate.future;
    final coordinator = _RecordingCoordinator();
    final bootstrap = CycleReminderActionBootstrap(service, coordinator);

    final first = bootstrap.start();
    final second = bootstrap.start();

    expect(identical(first, second), isTrue);
    expect(service.initCalls, 1);
    expect(service.handlerRegistrations, 1);
    initGate.complete();
    await Future.wait([first, second]);
    expect(service.launchDetailCalls, 1);
  });

  test(
    'duas chamadas concorrentes compartilham falha e liberam retry',
    () async {
      final initGate = Completer<void>();
      final service = _BootstrapNotificationService()
        ..initHandler = (_) => initGate.future;
      final coordinator = _RecordingCoordinator();
      final retryScheduler = _ManualRetryScheduler();
      final bootstrap = CycleReminderActionBootstrap(
        service,
        coordinator,
        retryScheduler: retryScheduler.schedule,
      );

      final first = bootstrap.start();
      final second = bootstrap.start();
      expect(identical(first, second), isTrue);

      initGate.completeError(StateError('init failed'));
      await Future.wait([first, second]);
      expect(service.initCalls, 1);
      expect(service.launchDetailCalls, 0);
      expect(retryScheduler.pendingCount, 1);

      service.initHandler = null;
      await retryScheduler.runNext();
      expect(service.initCalls, 2);
      expect(service.launchDetailCalls, 1);
    },
  );

  test(
    'quatro chamadas concorrentes consultam launch details uma vez',
    () async {
      final launchGate = Completer<NotificationAppLaunchDetails?>();
      final launchStarted = Completer<void>();
      final service = _BootstrapNotificationService()
        ..launchDetailsHandler = (_) {
          launchStarted.complete();
          return launchGate.future;
        };
      final coordinator = _RecordingCoordinator();
      final bootstrap = CycleReminderActionBootstrap(service, coordinator);

      final operations = List<Future<void>>.generate(
        4,
        (_) => bootstrap.start(),
      );

      expect(
        operations.every((operation) => identical(operation, operations.first)),
        isTrue,
      );
      await launchStarted.future;
      expect(service.initCalls, 1);
      expect(service.launchDetailCalls, 1);
      launchGate.complete(const NotificationAppLaunchDetails(false));
      await Future.wait(operations);
    },
  );

  test('start após sucesso não repete init nem launch details', () async {
    final service = _BootstrapNotificationService();
    final coordinator = _RecordingCoordinator();
    final retryScheduler = _ManualRetryScheduler();
    final bootstrap = CycleReminderActionBootstrap(
      service,
      coordinator,
      retryScheduler: retryScheduler.schedule,
    );

    await bootstrap.start();
    await bootstrap.start();

    expect(service.initCalls, 1);
    expect(service.launchDetailCalls, 1);
    expect(service.handlerRegistrations, 1);
    expect(retryScheduler.pendingCount, 0);
  });

  test(
    'falha de init dispara retry real e segunda tentativa funciona',
    () async {
      final service = _BootstrapNotificationService()
        ..initHandler = (call) async {
          if (call == 1) throw StateError('init failed');
        }
        ..launchDetails = const NotificationAppLaunchDetails(false);
      final coordinator = _RecordingCoordinator();
      final retryScheduler = _ManualRetryScheduler();
      final bootstrap = CycleReminderActionBootstrap(
        service,
        coordinator,
        retryScheduler: retryScheduler.schedule,
      );

      await bootstrap.start();
      expect(service.initCalls, 1);
      expect(service.launchDetailCalls, 0);
      expect(retryScheduler.pendingCount, 1);

      await retryScheduler.runNext();
      expect(service.initCalls, 2);
      expect(service.launchDetailCalls, 1);
      expect(service.handlerRegistrations, 1);
      expect(retryScheduler.pendingCount, 0);
    },
  );

  test('falha de launch details dispara nova consulta e sucesso', () async {
    final service = _BootstrapNotificationService()
      ..launchDetailsHandler = (call) async {
        if (call == 1) throw StateError('launch details failed');
        return const NotificationAppLaunchDetails(false);
      };
    final coordinator = _RecordingCoordinator();
    final retryScheduler = _ManualRetryScheduler();
    final bootstrap = CycleReminderActionBootstrap(
      service,
      coordinator,
      retryScheduler: retryScheduler.schedule,
    );

    await bootstrap.start();
    expect(service.launchDetailCalls, 1);
    expect(retryScheduler.pendingCount, 1);

    await retryScheduler.runNext();
    await bootstrap.start();
    expect(service.launchDetailCalls, 2);
    expect(service.handlerRegistrations, 1);
    expect(retryScheduler.pendingCount, 0);
  });

  test('duas falhas consecutivas respeitam limite sem loop', () async {
    final service = _BootstrapNotificationService()
      ..initHandler = (_) async {
        throw StateError('init failed');
      };
    final retryScheduler = _ManualRetryScheduler();
    final bootstrap = CycleReminderActionBootstrap(
      service,
      _RecordingCoordinator(),
      retryScheduler: retryScheduler.schedule,
    );

    await bootstrap.start();
    expect(retryScheduler.pendingCount, 1);
    await retryScheduler.runNext();

    expect(service.initCalls, 2);
    expect(retryScheduler.pendingCount, 0);
    await bootstrap.start();
    expect(service.initCalls, 2);
  });

  test('launch sem notification conclui sem encaminhar action', () async {
    final service = _BootstrapNotificationService()
      ..launchDetails = const NotificationAppLaunchDetails(false);
    final coordinator = _RecordingCoordinator();
    final bootstrap = CycleReminderActionBootstrap(service, coordinator);

    await bootstrap.start();

    expect(coordinator.responses, isEmpty);
    expect(service.launchDetailCalls, 1);
  });

  test('tap comum sem action não chama coordinator', () async {
    const tapResponse = NotificationResponse(
      notificationResponseType: NotificationResponseType.selectedNotification,
      id: 2,
    );
    final service = _BootstrapNotificationService()
      ..launchDetails = const NotificationAppLaunchDetails(
        true,
        notificationResponse: tapResponse,
      );
    final coordinator = _RecordingCoordinator();
    final retryScheduler = _ManualRetryScheduler();

    await CycleReminderActionBootstrap(
      service,
      coordinator,
      retryScheduler: retryScheduler.schedule,
    ).start();

    expect(coordinator.responses, isEmpty);
    expect(retryScheduler.pendingCount, 0);
  });

  test('cold-start action é encaminhada exatamente uma vez', () async {
    final service = _BootstrapNotificationService()
      ..launchDetails = const NotificationAppLaunchDetails(
        true,
        notificationResponse: actionResponse,
      );
    final coordinator = _RecordingCoordinator();
    final bootstrap = CycleReminderActionBootstrap(service, coordinator);

    await bootstrap.start();
    await bootstrap.start();

    expect(coordinator.responses, [actionResponse]);
    expect(service.launchDetailCalls, 1);
  });

  test('cold-start antes do Auth cria um único pending', () async {
    final service = _BootstrapNotificationService()
      ..launchDetails = const NotificationAppLaunchDetails(
        true,
        notificationResponse: actionResponse,
      );
    final coordinator = _PendingCoordinator();
    final bootstrap = CycleReminderActionBootstrap(service, coordinator);

    await Future.wait([bootstrap.start(), bootstrap.start()]);
    expect(coordinator.received, 1);
    expect(coordinator.processed, 0);

    await coordinator.onSessionPrepared('user-a');
    expect(coordinator.processed, 1);
    expect(coordinator.pending, isNull);
  });

  test('retry não duplica response já entregue ao coordinator', () async {
    final service = _BootstrapNotificationService()
      ..launchDetails = const NotificationAppLaunchDetails(
        true,
        notificationResponse: actionResponse,
      );
    final coordinator = _RecordingCoordinator()
      ..handleCallback = (_) async {
        throw StateError('coordinator failed after dispatch');
      };
    final retryScheduler = _ManualRetryScheduler();
    final bootstrap = CycleReminderActionBootstrap(
      service,
      coordinator,
      retryScheduler: retryScheduler.schedule,
    );

    await bootstrap.start();
    expect(coordinator.responses, [actionResponse]);
    expect(retryScheduler.pendingCount, 1);

    coordinator.handleCallback = null;
    await retryScheduler.runNext();
    await bootstrap.start();

    expect(coordinator.responses, [actionResponse]);
    expect(service.launchDetailCalls, 2);
    expect(retryScheduler.pendingCount, 0);
  });

  test(
    'retry pendente e start manual compartilham uma operação real',
    () async {
      final retryLaunchGate = Completer<NotificationAppLaunchDetails?>();
      final retryLaunchStarted = Completer<void>();
      final service = _BootstrapNotificationService()
        ..initHandler = (call) async {
          if (call == 1) throw StateError('init failed');
        }
        ..launchDetailsHandler = (_) {
          retryLaunchStarted.complete();
          return retryLaunchGate.future;
        };
      final coordinator = _RecordingCoordinator();
      final retryScheduler = _ManualRetryScheduler();
      final bootstrap = CycleReminderActionBootstrap(
        service,
        coordinator,
        retryScheduler: retryScheduler.schedule,
      );

      await bootstrap.start();
      expect(retryScheduler.pendingCount, 1);
      final manualRetry = bootstrap.start();
      await retryLaunchStarted.future;
      final scheduledRetry = retryScheduler.runNext();

      expect(service.initCalls, 2);
      expect(service.launchDetailCalls, 1);
      retryLaunchGate.complete(const NotificationAppLaunchDetails(false));
      await Future.wait([manualRetry, scheduledRetry]);
      expect(service.initCalls, 2);
    },
  );

  test('dispose antes do retry impede segunda tentativa', () async {
    final service = _BootstrapNotificationService()
      ..initHandler = (_) async {
        throw StateError('init failed');
      };
    final retryScheduler = _ManualRetryScheduler();
    final bootstrap = CycleReminderActionBootstrap(
      service,
      _RecordingCoordinator(),
      retryScheduler: retryScheduler.schedule,
    );

    await bootstrap.start();
    expect(retryScheduler.pendingCount, 1);
    bootstrap.dispose();
    await retryScheduler.runNext();

    expect(service.initCalls, 1);
    expect(service.handler, isNull);
  });

  test('dispose durante launch details bloqueia callback futura', () async {
    final launchStarted = Completer<void>();
    final launchGate = Completer<NotificationAppLaunchDetails?>();
    final service = _BootstrapNotificationService()
      ..launchDetailsHandler = (_) {
        launchStarted.complete();
        return launchGate.future;
      };
    final coordinator = _RecordingCoordinator();
    final retryScheduler = _ManualRetryScheduler();
    final bootstrap = CycleReminderActionBootstrap(
      service,
      coordinator,
      retryScheduler: retryScheduler.schedule,
    );

    final operation = bootstrap.start();
    await launchStarted.future;
    bootstrap.dispose();
    launchGate.complete(
      const NotificationAppLaunchDetails(
        true,
        notificationResponse: actionResponse,
      ),
    );
    await operation;

    expect(coordinator.responses, isEmpty);
    expect(retryScheduler.pendingCount, 0);
    expect(service.handler, isNull);
  });

  test(
    'dispose do provider remove handler e bloqueia callback morto',
    () async {
      final service = _BootstrapNotificationService();
      final coordinator = _RecordingCoordinator();
      final container = ProviderContainer(
        overrides: [
          notificationServiceProvider.overrideWithValue(service),
          cycleReminderActionCoordinatorProvider.overrideWithValue(coordinator),
        ],
      );
      final bootstrap = container.read(cycleReminderActionBootstrapProvider);
      await bootstrap.start();
      expect(service.handler, isNotNull);

      container.dispose();
      await service.emit(actionResponse);
      await bootstrap.start();

      expect(service.handler, isNull);
      expect(service.handlerClears, 1);
      expect(coordinator.responses, isEmpty);
      expect(service.initCalls, 1);
    },
  );
}
