import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/services/notification_service.dart';
import 'package:life_os/features/health/presentation/cycle/cycle_reminder_preferences.dart';
import 'package:life_os/features/health/services/cycle_reminder_notification_lifecycle.dart';
import 'package:life_os/features/health/services/cycle_reminder_session_reconciler.dart';

class _RecordingLifecycle implements CycleReminderNotificationLifecycle {
  int cancelCalls = 0;
  int rebuildCalls = 0;
  final List<String> cancelledUserIds = <String>[];
  final List<String> rebuiltUserIds = <String>[];
  void Function(String userId)? onRebuild;
  bool throwOnRebuild = false;
  bool hasActiveReminder = false;

  @override
  Future<int> cancelAllCycleReminders(String userId) async {
    cancelCalls += 1;
    cancelledUserIds.add(userId);
    hasActiveReminder = false;
    return 0;
  }

  @override
  Future<CycleReminderRebuildResult> rebuildCycleReminders(
    String userId,
    CycleReminderPreferences preferences,
  ) async {
    rebuildCalls += 1;
    rebuiltUserIds.add(userId);
    hasActiveReminder = true;
    onRebuild?.call(userId);
    if (throwOnRebuild) throw StateError('private rebuild failure');
    return const CycleReminderRebuildResult(
      eligible: 1,
      scheduled: 1,
      failed: 0,
      cancellationFailed: 0,
    );
  }
}

class _PermissionRecordingService extends NotificationService {
  int permissionRequests = 0;
  int exactRequests = 0;
  int schedules = 0;

  @override
  Future<bool> requestPermissions({String? preferenceKey}) async {
    permissionRequests += 1;
    return true;
  }

  @override
  Future<bool> requestExactAlarmPermission() async {
    exactRequests += 1;
    return true;
  }

  @override
  Future<bool> cancelCycleReminderNotification(int id) async => true;

  @override
  Future<bool> scheduleCycleReminderNotification({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledDate,
    required DateTimeComponents matchDateTimeComponents,
  }) async {
    schedules += 1;
    return true;
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
  const userA = 'user-a';
  const userB = 'user-b';
  late String? currentUserId;
  late CycleReminderPreferences? storedPreferences;
  late bool globalEnabled;
  late _RecordingLifecycle lifecycle;
  late CycleReminderSessionReconciler reconciler;

  setUp(() {
    currentUserId = userA;
    storedPreferences = _preferences();
    globalEnabled = true;
    lifecycle = _RecordingLifecycle();
    reconciler = CycleReminderSessionReconciler(
      loadCyclePreferences: (_) async => storedPreferences,
      loadGlobalNotifications: () async => globalEnabled,
      currentUserId: () => currentUserId,
      lifecycle: lifecycle,
    );
  });

  test('enabled e global true restauram UID autenticado', () async {
    await reconciler.restoreForSession(userA);

    expect(lifecycle.rebuiltUserIds, [userA]);
    expect(lifecycle.cancelCalls, 0);
  });

  test('disabled cancela IDs sem rebuild', () async {
    storedPreferences = _preferences(enabled: false);

    await reconciler.restoreForSession(userA);

    expect(lifecycle.rebuildCalls, 0);
    expect(lifecycle.cancelCalls, 1);
    expect(lifecycle.cancelledUserIds, [userA]);
  });

  test('configuração inexistente cancela possíveis schedules órfãos', () async {
    storedPreferences = null;

    await reconciler.restoreForSession(userA);

    expect(lifecycle.rebuildCalls, 0);
    expect(lifecycle.cancelCalls, 1);
    expect(lifecycle.cancelledUserIds, [userA]);
    expect(storedPreferences, isNull);
    expect(currentUserId, userA);
  });

  test('global false cancela sem alterar enabled', () async {
    globalEnabled = false;
    final original = storedPreferences;

    await reconciler.restoreForSession(userA);

    expect(lifecycle.rebuildCalls, 0);
    expect(lifecycle.cancelledUserIds, [userA]);
    expect(storedPreferences, same(original));
    expect(storedPreferences?.enabled, isTrue);
  });

  test('restore silencioso nunca solicita permissões', () async {
    final service = _PermissionRecordingService();
    final realLifecycle = CycleReminderNotificationLifecycleService(
      service,
      clock: () => DateTime(2026, 8, 25, 8),
    );
    final silentReconciler = CycleReminderSessionReconciler(
      loadCyclePreferences: (_) async => _preferences(),
      loadGlobalNotifications: () async => true,
      currentUserId: () => userA,
      lifecycle: realLifecycle,
    );

    await silentReconciler.restoreForSession(userA);

    expect(service.schedules, 1);
    expect(service.permissionRequests, 0);
    expect(service.exactRequests, 0);
  });

  test('sessão muda durante load e não agenda UID antigo', () async {
    final loadStarted = Completer<void>();
    final releaseLoad = Completer<void>();
    reconciler = CycleReminderSessionReconciler(
      loadCyclePreferences: (_) async {
        loadStarted.complete();
        await releaseLoad.future;
        return _preferences();
      },
      loadGlobalNotifications: () async => true,
      currentUserId: () => currentUserId,
      lifecycle: lifecycle,
    );

    final restore = reconciler.restoreForSession(userA);
    await loadStarted.future;
    currentUserId = userB;
    releaseLoad.complete();
    await restore;

    expect(lifecycle.rebuildCalls, 0);
    expect(lifecycle.cancelledUserIds, [userA]);
  });

  test('sessão muda durante rebuild e cancela UID antigo ao final', () async {
    lifecycle.onRebuild = (_) => currentUserId = userB;

    await reconciler.restoreForSession(userA);

    expect(lifecycle.rebuiltUserIds, [userA]);
    expect(lifecycle.cancelledUserIds, [userA]);
  });

  test('falha de storage é best-effort e não escapa', () async {
    reconciler = CycleReminderSessionReconciler(
      loadCyclePreferences: (_) async =>
          throw StateError('private storage failure'),
      loadGlobalNotifications: () async => true,
      currentUserId: () => currentUserId,
      lifecycle: lifecycle,
    );

    await expectLater(reconciler.restoreForSession(userA), completes);
    expect(lifecycle.rebuildCalls, 0);
    expect(lifecycle.cancelledUserIds, [userA]);
  });

  test('falha de rebuild é best-effort e não escapa', () async {
    lifecycle.throwOnRebuild = true;

    await expectLater(reconciler.restoreForSession(userA), completes);

    expect(lifecycle.rebuildCalls, 1);
    expect(lifecycle.cancelledUserIds, [userA]);
  });

  test(
    'logout e relogin da mesma conta restauram escolha persistida',
    () async {
      lifecycle.hasActiveReminder = false;
      currentUserId = userA;

      await reconciler.restoreForSession(userA);

      expect(storedPreferences?.enabled, isTrue);
      expect(lifecycle.rebuiltUserIds, [userA]);
      expect(lifecycle.hasActiveReminder, isTrue);
    },
  );

  test('troca A para B nunca deixa rebuild final de A', () async {
    final loadStarted = Completer<void>();
    final releaseLoad = Completer<void>();
    reconciler = CycleReminderSessionReconciler(
      loadCyclePreferences: (userId) async {
        if (userId == userA) {
          loadStarted.complete();
          await releaseLoad.future;
          return _preferences();
        }
        return null;
      },
      loadGlobalNotifications: () async => true,
      currentUserId: () => currentUserId,
      lifecycle: lifecycle,
    );

    final restoreA = reconciler.restoreForSession(userA);
    await loadStarted.future;
    currentUserId = userB;
    final restoreB = reconciler.restoreForSession(userB);
    releaseLoad.complete();
    await Future.wait([restoreA, restoreB]);

    expect(lifecycle.rebuiltUserIds, isNot(contains(userA)));
    expect(lifecycle.cancelledUserIds, contains(userA));
  });

  test('startup com sessão existente usa o mesmo restore central', () async {
    currentUserId = userA;

    await reconciler.restoreForSession(userA);

    expect(lifecycle.rebuiltUserIds, [userA]);
  });

  test('chamadas simultâneas do mesmo UID compartilham operação', () async {
    final loadStarted = Completer<void>();
    final releaseLoad = Completer<void>();
    var loads = 0;
    reconciler = CycleReminderSessionReconciler(
      loadCyclePreferences: (_) async {
        loads += 1;
        loadStarted.complete();
        await releaseLoad.future;
        return _preferences();
      },
      loadGlobalNotifications: () async => true,
      currentUserId: () => currentUserId,
      lifecycle: lifecycle,
    );

    final first = reconciler.restoreForSession(userA);
    await loadStarted.future;
    final second = reconciler.restoreForSession(userA);
    releaseLoad.complete();
    await Future.wait([first, second]);

    expect(loads, 1);
    expect(lifecycle.rebuildCalls, 1);
  });
}
