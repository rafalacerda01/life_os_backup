import 'dart:async';
import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/services/notification_service.dart';
import 'package:life_os/features/health/presentation/cycle/cycle_reminder_preferences.dart';
import 'package:life_os/features/health/services/cycle_reminder_action_coordinator.dart';
import 'package:life_os/features/health/services/cycle_reminder_action_security.dart';
import 'package:life_os/features/health/services/cycle_reminder_notification_lifecycle.dart';
import 'package:life_os/features/health/services/cycle_reminder_mutation_gate.dart';
import 'package:life_os/features/health/services/cycle_reminder_operation_epoch.dart';
import 'package:life_os/features/health/services/cycle_reminder_session_authority.dart';

class _TokenStore implements CycleReminderActionTokenReader {
  _TokenStore(this.token);

  final String token;
  void Function()? onLoad;
  bool throwOnLoad = false;

  @override
  Future<String> getOrCreate(String userId) async => token;

  @override
  Future<String?> load(String userId) async {
    onLoad?.call();
    if (throwOnLoad) {
      throw StateError('private-$userId-$token');
    }
    return token;
  }
}

class _ScheduledSnooze {
  const _ScheduledSnooze({
    required this.id,
    required this.title,
    required this.body,
    required this.date,
    required this.payload,
  });

  final int id;
  final String title;
  final String body;
  final DateTime date;
  final String payload;
}

class _RecordingGateway implements CycleReminderActionNotificationGateway {
  final List<int> cancelledIds = <int>[];
  final List<_ScheduledSnooze> schedules = <_ScheduledSnooze>[];
  void Function()? onSchedule;
  Completer<void>? scheduleStarted;
  Future<void>? scheduleGate;

  @override
  Future<bool> cancel(int id) async {
    cancelledIds.add(id);
    return true;
  }

  @override
  Future<bool> scheduleSnooze({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledDate,
    required String payload,
  }) async {
    scheduleStarted?.complete();
    final gate = scheduleGate;
    if (gate != null) await gate;
    schedules.add(
      _ScheduledSnooze(
        id: id,
        title: title,
        body: body,
        date: scheduledDate,
        payload: payload,
      ),
    );
    onSchedule?.call();
    return true;
  }
}

class _RecordingLifecycle implements CycleReminderNotificationLifecycle {
  final List<String> cancelledUsers = <String>[];

  @override
  Future<int> cancelAllCycleReminders(String userId) async {
    cancelledUsers.add(userId);
    return 0;
  }

  @override
  Future<CycleReminderRebuildResult> rebuildCycleReminders(
    String userId,
    CycleReminderPreferences preferences, {
    CycleReminderRebuildGuard? shouldContinue,
  }) {
    throw UnimplementedError();
  }
}

CycleReminderPreferences _preferences({
  bool enabled = true,
  CycleReminderPrivacyMode privacyMode = CycleReminderPrivacyMode.discreet,
  String customTitle = '',
  String customBody = '',
}) {
  return CycleReminderPreferences(
    enabled: enabled,
    type: CycleReminderType.personal,
    hour: 9,
    minute: 30,
    frequency: CycleReminderFrequency.daily,
    privacyMode: privacyMode,
    customTitle: customTitle,
    customBody: customBody,
  );
}

void main() {
  const userA = 'user-a';
  const userB = 'user-b';
  final tokenA = base64Url.encode(List<int>.filled(32, 1)).replaceAll('=', '');
  final tokenB = base64Url.encode(List<int>.filled(32, 2)).replaceAll('=', '');
  const codec = CycleReminderActionPayloadCodec();
  final now = DateTime(2026, 8, 26, 10);

  late String? currentUserId;
  late _TokenStore tokenStore;
  late _RecordingGateway gateway;
  late _RecordingLifecycle lifecycle;
  late CycleReminderOperationEpoch operationEpoch;
  late CycleReminderMutationGate mutationGate;
  late CycleReminderSessionAuthority sessionAuthority;
  late CycleReminderPreferences? preferences;
  late bool globalEnabled;
  late void Function()? onPreferencesLoad;
  late Completer<void>? preferencesLoadStarted;
  late Future<void>? preferencesLoadGate;
  late List<String> warnings;

  NotificationResponse responseFor({
    String? token,
    int? id,
    String actionId = cycleReminderSnoozeActionId,
    String? payload,
  }) {
    return NotificationResponse(
      notificationResponseType:
          NotificationResponseType.selectedNotificationAction,
      id: id ?? cycleReminderNotificationId(userA, 0),
      actionId: actionId,
      payload:
          payload ?? codec.encode(CycleReminderActionPayload(token ?? tokenA)),
    );
  }

  CycleReminderActionCoordinator coordinator() {
    return CycleReminderActionCoordinator(
      currentUserId: () => currentUserId,
      tokenStore: tokenStore,
      loadPreferences: (_) async {
        onPreferencesLoad?.call();
        preferencesLoadStarted?.complete();
        final gate = preferencesLoadGate;
        if (gate != null) await gate;
        return preferences;
      },
      loadGlobalNotifications: () async => globalEnabled,
      operationEpoch: operationEpoch,
      sessionAuthority: sessionAuthority,
      mutationGate: mutationGate,
      lifecycle: lifecycle,
      notificationGateway: gateway,
      clock: () => now,
      warningLogger: warnings.add,
    );
  }

  setUp(() {
    currentUserId = userA;
    tokenStore = _TokenStore(tokenA);
    gateway = _RecordingGateway();
    lifecycle = _RecordingLifecycle();
    operationEpoch = CycleReminderOperationEpoch();
    mutationGate = CycleReminderMutationGate();
    sessionAuthority = CycleReminderSessionAuthority();
    preferences = _preferences();
    globalEnabled = true;
    onPreferencesLoad = null;
    preferencesLoadStarted = null;
    preferencesLoadGate = null;
    warnings = <String>[];
  });

  test('snooze válido substitui slot 8 e agenda para 15 minutos', () async {
    final actionCoordinator = coordinator();
    await actionCoordinator.onSessionPrepared(userA);

    await actionCoordinator.handle(responseFor());

    final snoozeId = cycleReminderNotificationId(
      userA,
      cycleReminderSnoozeSlot,
    );
    expect(gateway.cancelledIds, [snoozeId]);
    expect(gateway.schedules, hasLength(1));
    expect(gateway.schedules.single.id, snoozeId);
    expect(gateway.schedules.single.date, now.add(const Duration(minutes: 15)));
  });

  test('action desconhecida não produz operação', () async {
    final actionCoordinator = coordinator();
    await actionCoordinator.onSessionPrepared(userA);

    await actionCoordinator.handle(responseFor(actionId: 'unknown'));

    expect(gateway.schedules, isEmpty);
    expect(gateway.cancelledIds, isEmpty);
  });

  test('payload, token e notification ID inválidos falham fechado', () async {
    final actionCoordinator = coordinator();
    await actionCoordinator.onSessionPrepared(userA);

    await actionCoordinator.handle(responseFor(payload: '{'));
    await actionCoordinator.handle(responseFor(token: tokenB));
    await actionCoordinator.handle(responseFor(id: 999999));

    expect(gateway.schedules, isEmpty);
    expect(gateway.cancelledIds, isEmpty);
  });

  test('global OFF cancela Cycle conhecido e não cria snooze', () async {
    globalEnabled = false;
    final actionCoordinator = coordinator();
    await actionCoordinator.onSessionPrepared(userA);

    await actionCoordinator.handle(responseFor());

    expect(gateway.schedules, isEmpty);
    expect(lifecycle.cancelledUsers, [userA]);
  });

  test('Cycle OFF cancela Cycle conhecido e não cria snooze', () async {
    preferences = _preferences(enabled: false);
    final actionCoordinator = coordinator();
    await actionCoordinator.onSessionPrepared(userA);

    await actionCoordinator.handle(responseFor());

    expect(gateway.schedules, isEmpty);
    expect(lifecycle.cancelledUsers, [userA]);
  });

  test('configuração ausente falha fechado e cancela artefatos', () async {
    preferences = null;
    final actionCoordinator = coordinator();
    await actionCoordinator.onSessionPrepared(userA);

    await actionCoordinator.handle(responseFor());

    expect(gateway.schedules, isEmpty);
    expect(lifecycle.cancelledUsers, [userA]);
  });

  test('UID diferente antes ou durante load impede snooze', () async {
    final before = coordinator();
    await before.onSessionPrepared(userA);
    currentUserId = userB;
    await before.handle(responseFor());
    expect(gateway.schedules, isEmpty);

    currentUserId = userA;
    onPreferencesLoad = () => currentUserId = userB;
    final during = coordinator();
    await during.onSessionPrepared(userA);
    await during.handle(responseFor());
    expect(gateway.schedules, isEmpty);
  });

  test('troca durante scheduling remove artefatos do UID antigo', () async {
    gateway.onSchedule = () => currentUserId = userB;
    final actionCoordinator = coordinator();
    await actionCoordinator.onSessionPrepared(userA);

    await actionCoordinator.handle(responseFor());

    expect(gateway.schedules, hasLength(1));
    expect(lifecycle.cancelledUsers, [userA]);
  });

  test('action antiga de A nunca agenda para sessão B', () async {
    currentUserId = userB;
    tokenStore = _TokenStore(tokenB);
    final actionCoordinator = coordinator();
    await actionCoordinator.onSessionPrepared(userB);

    await actionCoordinator.handle(responseFor(token: tokenA));

    expect(gateway.schedules, isEmpty);
    expect(gateway.cancelledIds, isEmpty);
  });

  test('dois snoozes e snooze do slot 8 substituem o mesmo ID', () async {
    final actionCoordinator = coordinator();
    await actionCoordinator.onSessionPrepared(userA);
    final snoozeId = cycleReminderNotificationId(
      userA,
      cycleReminderSnoozeSlot,
    );

    final first = actionCoordinator.handle(responseFor());
    final second = actionCoordinator.handle(responseFor(id: snoozeId));
    await Future.wait([first, second]);

    expect(gateway.cancelledIds, [snoozeId, snoozeId]);
    expect(gateway.schedules.map((entry) => entry.id), [snoozeId, snoozeId]);
  });

  test('conteúdo vem das preferences atuais e não do payload', () async {
    preferences = _preferences(
      privacyMode: CycleReminderPrivacyMode.custom,
      customTitle: 'Título atual',
      customBody: 'Corpo atual',
    );
    final actionCoordinator = coordinator();
    await actionCoordinator.onSessionPrepared(userA);

    await actionCoordinator.handle(responseFor());

    expect(gateway.schedules.single.title, 'Título atual');
    expect(gateway.schedules.single.body, 'Corpo atual');
    expect(gateway.schedules.single.payload, isNot(contains('Título atual')));
    expect(gateway.schedules.single.payload, isNot(contains('Corpo atual')));
  });

  test(
    'action recebida antes do Auth fica somente pending em memória',
    () async {
      final actionCoordinator = coordinator();

      await actionCoordinator.handle(responseFor());
      expect(gateway.schedules, isEmpty);

      await actionCoordinator.onSessionPrepared(userA);
      expect(gateway.schedules, hasLength(1));
    },
  );

  test('falha interna produz somente warning fixo sanitizado', () async {
    tokenStore.throwOnLoad = true;
    final actionCoordinator = coordinator();
    await actionCoordinator.onSessionPrepared(userA);

    await actionCoordinator.handle(responseFor());

    expect(warnings, [
      '[CycleReminderAction] Ação local ignorada com segurança.',
    ]);
    final log = warnings.single;
    expect(log, isNot(contains(userA)));
    expect(log, isNot(contains(tokenA)));
    expect(log, isNot(contains(responseFor().payload!)));
  });

  test('session clear impede action para UID antes preparado', () async {
    final actionCoordinator = coordinator();
    await actionCoordinator.onSessionPrepared(userA);

    actionCoordinator.onSessionCleared();
    await actionCoordinator.handle(responseFor());

    expect(gateway.schedules, isEmpty);
    expect(gateway.cancelledIds, isEmpty);
  });

  test('session clear descarta pending anterior ao prepare', () async {
    final actionCoordinator = coordinator();
    await actionCoordinator.handle(responseFor());

    actionCoordinator.onSessionCleared();
    await actionCoordinator.onSessionPrepared(userA);

    expect(gateway.schedules, isEmpty);
    expect(gateway.cancelledIds, isEmpty);
  });

  test('session clear invalida action em voo antes do scheduling', () async {
    final loadStarted = Completer<void>();
    final releaseLoad = Completer<void>();
    preferencesLoadStarted = loadStarted;
    preferencesLoadGate = releaseLoad.future;
    final actionCoordinator = coordinator();
    await actionCoordinator.onSessionPrepared(userA);

    final action = actionCoordinator.handle(responseFor());
    await loadStarted.future;
    actionCoordinator.onSessionCleared();
    releaseLoad.complete();
    await action;

    expect(gateway.schedules, isEmpty);
    expect(gateway.cancelledIds, isEmpty);
    expect(lifecycle.cancelledUsers, isEmpty);
  });

  test('session clear durante schedule remove somente slot 8', () async {
    final scheduleStarted = Completer<void>();
    final releaseSchedule = Completer<void>();
    gateway.scheduleStarted = scheduleStarted;
    gateway.scheduleGate = releaseSchedule.future;
    final actionCoordinator = coordinator();
    await actionCoordinator.onSessionPrepared(userA);
    final snoozeId = cycleReminderNotificationId(
      userA,
      cycleReminderSnoozeSlot,
    );

    final action = actionCoordinator.handle(responseFor());
    await scheduleStarted.future;
    actionCoordinator.onSessionCleared();
    releaseSchedule.complete();
    await action;

    expect(gateway.schedules, hasLength(1));
    expect(gateway.cancelledIds, [snoozeId, snoozeId]);
    expect(lifecycle.cancelledUsers, isEmpty);
  });

  test('logout e novo prepare de A permitem somente action nova', () async {
    final actionCoordinator = coordinator();
    await actionCoordinator.onSessionPrepared(userA);
    actionCoordinator.onSessionCleared();

    await actionCoordinator.onSessionPrepared(userA);
    await actionCoordinator.handle(responseFor());

    expect(gateway.schedules, hasLength(1));
  });

  test('lease antiga de A continua stale após novo prepare de A', () async {
    final scheduleStarted = Completer<void>();
    final releaseSchedule = Completer<void>();
    gateway.scheduleStarted = scheduleStarted;
    gateway.scheduleGate = releaseSchedule.future;
    final actionCoordinator = coordinator();
    await actionCoordinator.onSessionPrepared(userA);
    final snoozeId = cycleReminderNotificationId(
      userA,
      cycleReminderSnoozeSlot,
    );

    final oldAction = actionCoordinator.handle(responseFor());
    await scheduleStarted.future;
    actionCoordinator.onSessionCleared();
    await actionCoordinator.onSessionPrepared(userA);
    releaseSchedule.complete();
    await oldAction;

    expect(gateway.schedules, hasLength(1));
    expect(gateway.cancelledIds, [snoozeId, snoozeId]);
    expect(lifecycle.cancelledUsers, isEmpty);
  });

  test('clear de A seguido de prepare B não executa action A', () async {
    final actionCoordinator = coordinator();
    await actionCoordinator.onSessionPrepared(userA);
    actionCoordinator.onSessionCleared();
    currentUserId = userB;
    tokenStore = _TokenStore(tokenB);

    await actionCoordinator.onSessionPrepared(userB);
    await actionCoordinator.handle(responseFor(token: tokenA));

    expect(gateway.schedules, isEmpty);
    expect(gateway.cancelledIds, isEmpty);
    expect(lifecycle.cancelledUsers, isEmpty);
  });

  test('Firebase A após clear não reativa sessão local preparada', () async {
    final actionCoordinator = coordinator();
    await actionCoordinator.onSessionPrepared(userA);
    actionCoordinator.onSessionCleared();
    expect(currentUserId, userA);

    await actionCoordinator.handle(responseFor());
    await actionCoordinator.onSessionPrepared(userA);

    expect(gateway.schedules, isEmpty);
    expect(gateway.cancelledIds, isEmpty);
  });

  test('falha posterior de sign-out mantém coordinator cleared', () async {
    final actionCoordinator = coordinator();
    await actionCoordinator.onSessionPrepared(userA);
    actionCoordinator.onSessionCleared();

    try {
      throw StateError('sign-out failed');
    } on StateError {
      // Firebase ainda expõe A, mas a sessão local permanece invalidada.
    }
    await actionCoordinator.handle(responseFor());

    expect(currentUserId, userA);
    expect(gateway.schedules, isEmpty);
    expect(gateway.cancelledIds, isEmpty);
  });

  test('session clear sem sessão preparada é idempotente', () async {
    final actionCoordinator = coordinator();

    actionCoordinator.onSessionCleared();
    actionCoordinator.onSessionCleared();
    await actionCoordinator.handle(responseFor());

    expect(gateway.schedules, isEmpty);
    expect(gateway.cancelledIds, isEmpty);
    expect(lifecycle.cancelledUsers, isEmpty);
  });
}
