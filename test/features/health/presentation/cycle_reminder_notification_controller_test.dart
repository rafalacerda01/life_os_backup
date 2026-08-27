import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/services/notification_service.dart';
import 'package:life_os/features/health/presentation/cycle/cycle_reminder_notification_controller.dart';
import 'package:life_os/features/health/presentation/cycle/cycle_reminder_preferences.dart';
import 'package:life_os/features/health/services/cycle_reminder_notification_lifecycle.dart';
import 'package:life_os/features/health/services/cycle_reminder_operation_epoch.dart';
import 'package:life_os/features/health/services/cycle_reminder_session_authority.dart';

class _RecordingNotificationService extends NotificationService {
  _RecordingNotificationService(this.events);

  final List<String> events;
  bool permissionGranted = true;
  bool exactGranted = true;
  int permissionRequests = 0;
  int exactRequests = 0;
  void Function()? onPermissionRequested;
  void Function()? onExactRequested;

  @override
  Future<bool> requestPermissions({String? preferenceKey}) async {
    events.add('permission');
    permissionRequests += 1;
    onPermissionRequested?.call();
    return permissionGranted;
  }

  @override
  Future<bool> requestExactAlarmPermission() async {
    events.add('exact');
    exactRequests += 1;
    onExactRequested?.call();
    return exactGranted;
  }

  @override
  Future<void> cancelAllNotifications() async {
    events.add('cancel-all');
  }
}

class _RecordingLifecycle implements CycleReminderNotificationLifecycle {
  _RecordingLifecycle(this.events);

  final List<String> events;
  int cancelCalls = 0;
  int rebuildCalls = 0;
  bool throwOnRebuild = false;
  void Function()? onRebuild;
  final List<String> cancelledUserIds = <String>[];

  @override
  Future<int> cancelAllCycleReminders(String userId) async {
    events.add('cancel-cycle');
    cancelCalls += 1;
    cancelledUserIds.add(userId);
    return 0;
  }

  @override
  Future<CycleReminderRebuildResult> rebuildCycleReminders(
    String userId,
    CycleReminderPreferences preferences, {
    CycleReminderRebuildGuard? shouldContinue,
  }) async {
    events.add('rebuild');
    rebuildCalls += 1;
    onRebuild?.call();
    if (throwOnRebuild) throw StateError('private scheduling failure');
    return const CycleReminderRebuildResult(
      eligible: 1,
      scheduled: 1,
      failed: 0,
      cancellationFailed: 0,
    );
  }
}

CycleReminderPreferences _preferences({bool enabled = true}) {
  return CycleReminderPreferences(
    enabled: enabled,
    type: CycleReminderType.personal,
    hour: 9,
    minute: 30,
    frequency: CycleReminderFrequency.daily,
  );
}

void main() {
  late List<String> events;
  late _RecordingNotificationService service;
  late _RecordingLifecycle lifecycle;
  late CycleReminderOperationEpoch operationEpoch;
  late CycleReminderSessionAuthority sessionAuthority;
  late CycleReminderPreferences? persisted;
  String? currentUserId = 'user-a';
  var persistedOwnerUid = 'user-a';
  var globalEnabled = true;

  CycleReminderNotificationController controller() {
    return CycleReminderNotificationController(
      (preferences) async {
        events.add('persist');
        persisted = preferences;
        return persistedOwnerUid;
      },
      () => sessionAuthority.admittedUserId(currentUserId),
      () async => globalEnabled,
      service,
      lifecycle,
      operationEpoch,
    );
  }

  setUp(() {
    events = <String>[];
    service = _RecordingNotificationService(events);
    lifecycle = _RecordingLifecycle(events);
    operationEpoch = CycleReminderOperationEpoch();
    sessionAuthority = CycleReminderSessionAuthority()..prepare('user-a');
    persisted = null;
    currentUserId = 'user-a';
    persistedOwnerUid = 'user-a';
    globalEnabled = true;
  });

  test(
    'global off persiste enabled, não pede permissão e cancela cycle',
    () async {
      globalEnabled = false;

      await controller().save(_preferences());

      expect(persisted?.enabled, isTrue);
      expect(events, ['persist', 'cancel-cycle']);
      expect(service.permissionRequests, 0);
      expect(lifecycle.rebuildCalls, 0);
    },
  );

  test('toggle off persiste false e cancela somente IDs de cycle', () async {
    await controller().setEnabled(_preferences(), false);

    expect(persisted?.enabled, isFalse);
    expect(events, ['persist', 'cancel-cycle']);
    expect(service.permissionRequests, 0);
    expect(events, isNot(contains('cancel-all')));
  });

  test('toggle on persiste antes de pedir permissões e rebuild', () async {
    await controller().setEnabled(_preferences(enabled: false), true);

    expect(persisted?.enabled, isTrue);
    expect(events, [
      'persist',
      'cancel-cycle',
      'permission',
      'exact',
      'rebuild',
    ]);
  });

  test('permissão normal negada preserva enabled e não agenda', () async {
    service.permissionGranted = false;

    await controller().save(_preferences());

    expect(persisted?.enabled, isTrue);
    expect(events, ['persist', 'cancel-cycle', 'permission']);
    expect(service.exactRequests, 0);
    expect(lifecycle.rebuildCalls, 0);
  });

  test('exact negado ainda permite rebuild para fallback inexact', () async {
    service.exactGranted = false;

    await controller().save(_preferences());

    expect(events, [
      'persist',
      'cancel-cycle',
      'permission',
      'exact',
      'rebuild',
    ]);
    expect(lifecycle.rebuildCalls, 1);
  });

  test(
    'falha pós-persistência preserva configuração e cancela slots',
    () async {
      lifecycle.throwOnRebuild = true;

      await controller().save(_preferences());

      expect(persisted?.enabled, isTrue);
      expect(events, [
        'persist',
        'cancel-cycle',
        'permission',
        'exact',
        'rebuild',
        'cancel-cycle',
      ]);
    },
  );

  test('clear bloqueia save mesmo se Firebase ainda aponta para A', () async {
    final generation = operationEpoch.snapshot('user-a');
    sessionAuthority.clear();

    await expectLater(
      controller().save(_preferences()),
      throwsA(isA<StateError>()),
    );

    expect(events, isEmpty);
    expect(persisted, isNull);
    expect(operationEpoch.snapshot('user-a'), generation);
    expect(service.permissionRequests, 0);
    expect(service.exactRequests, 0);
    expect(lifecycle.rebuildCalls, 0);
    expect(lifecycle.cancelledUserIds, isEmpty);
  });

  test('troca A para B só admite save após prepare de B', () async {
    sessionAuthority.clear();
    currentUserId = 'user-b';
    persistedOwnerUid = 'user-b';

    await expectLater(
      controller().save(_preferences()),
      throwsA(isA<StateError>()),
    );
    expect(events, isEmpty);

    sessionAuthority.prepare('user-b');
    await controller().save(_preferences());

    expect(events, contains('persist'));
    expect(persisted, isNotNull);
  });

  test('logout e retorno a A exigem novo prepare de A', () async {
    sessionAuthority.clear();

    await expectLater(
      controller().save(_preferences()),
      throwsA(isA<StateError>()),
    );
    expect(events, isEmpty);

    sessionAuthority.prepare('user-a');
    await controller().save(_preferences());

    expect(events, contains('persist'));
  });

  test('UID Firebase diferente do UID preparado bloqueia save', () async {
    currentUserId = 'user-b';

    await expectLater(
      controller().save(_preferences()),
      throwsA(isA<StateError>()),
    );

    expect(events, isEmpty);
    expect(persisted, isNull);
  });

  test(
    'sessão muda antes da permission, cancela owner e não continua',
    () async {
      final changingController = CycleReminderNotificationController(
        (preferences) async {
          events.add('persist');
          persisted = preferences;
          currentUserId = 'user-b';
          return 'user-a';
        },
        () => sessionAuthority.admittedUserId(currentUserId),
        () async => true,
        service,
        lifecycle,
        operationEpoch,
      );

      await changingController.save(_preferences());

      expect(events, ['persist', 'cancel-cycle']);
      expect(service.permissionRequests, 0);
      expect(service.exactRequests, 0);
      expect(lifecycle.rebuildCalls, 0);
      expect(lifecycle.cancelledUserIds, ['user-a']);
    },
  );

  test('sessão muda após permission, cancela owner antes de exact', () async {
    service.onPermissionRequested = () {
      currentUserId = 'user-b';
    };

    await controller().save(_preferences());

    expect(events, ['persist', 'cancel-cycle', 'permission', 'cancel-cycle']);
    expect(service.exactRequests, 0);
    expect(lifecycle.rebuildCalls, 0);
    expect(lifecycle.cancelledUserIds, ['user-a', 'user-a']);
  });

  test('sessão muda durante exact, cancela owner e não faz rebuild', () async {
    service.onExactRequested = () {
      currentUserId = 'user-b';
    };

    await controller().save(_preferences());

    expect(events, [
      'persist',
      'cancel-cycle',
      'permission',
      'exact',
      'cancel-cycle',
    ]);
    expect(lifecycle.rebuildCalls, 0);
    expect(lifecycle.cancelledUserIds, ['user-a', 'user-a']);
  });

  test(
    'sessão muda durante rebuild e remove schedules recém-criados',
    () async {
      lifecycle.onRebuild = () {
        currentUserId = 'user-b';
      };

      await controller().save(_preferences());

      expect(events, [
        'persist',
        'cancel-cycle',
        'permission',
        'exact',
        'rebuild',
        'cancel-cycle',
      ]);
      expect(lifecycle.rebuildCalls, 1);
      expect(lifecycle.cancelledUserIds, ['user-a', 'user-a']);
    },
  );

  test('sessão estável remove snooze antes do rebuild recorrente', () async {
    await controller().save(_preferences());

    expect(events, [
      'persist',
      'cancel-cycle',
      'permission',
      'exact',
      'rebuild',
    ]);
    expect(lifecycle.cancelCalls, 1);
  });

  test('controller nunca usa cancelAllNotifications', () async {
    await controller().setEnabled(_preferences(), false);

    expect(events, ['persist', 'cancel-cycle']);
    expect(events, isNot(contains('cancel-all')));
  });
}
