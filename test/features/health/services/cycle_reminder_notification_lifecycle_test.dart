import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/services/notification_service.dart';
import 'package:life_os/features/health/presentation/cycle/cycle_reminder_preferences.dart';
import 'package:life_os/features/health/services/cycle_reminder_notification_lifecycle.dart';

class _ScheduledCycleReminder {
  const _ScheduledCycleReminder({
    required this.id,
    required this.title,
    required this.body,
    required this.date,
    required this.components,
  });

  final int id;
  final String title;
  final String body;
  final DateTime date;
  final DateTimeComponents components;
}

class _RecordingNotificationService extends NotificationService {
  final List<int> cancellationAttempts = <int>[];
  final List<String> events = <String>[];
  final List<_ScheduledCycleReminder> schedules = <_ScheduledCycleReminder>[];
  final Set<int> failedCancellations = <int>{};
  final Set<int> failedSchedules = <int>{};

  @override
  Future<bool> cancelCycleReminderNotification(int id) async {
    cancellationAttempts.add(id);
    events.add('cancel:$id');
    return !failedCancellations.contains(id);
  }

  @override
  Future<bool> scheduleCycleReminderNotification({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledDate,
    required DateTimeComponents matchDateTimeComponents,
  }) async {
    events.add('schedule:$id');
    schedules.add(
      _ScheduledCycleReminder(
        id: id,
        title: title,
        body: body,
        date: scheduledDate,
        components: matchDateTimeComponents,
      ),
    );
    return !failedSchedules.contains(id);
  }
}

CycleReminderPreferences _preferences({
  bool enabled = true,
  CycleReminderType type = CycleReminderType.personal,
  CycleReminderFrequency frequency = CycleReminderFrequency.daily,
  Set<int> weekdays = const <int>{},
  CycleReminderPrivacyMode privacyMode = CycleReminderPrivacyMode.discreet,
  String customTitle = '',
  String customBody = '',
}) {
  return CycleReminderPreferences(
    enabled: enabled,
    type: type,
    hour: 9,
    minute: 30,
    frequency: frequency,
    weekdays: weekdays,
    privacyMode: privacyMode,
    customTitle: customTitle,
    customBody: customBody,
  );
}

void main() {
  const userId = 'user-a';
  final now = DateTime(2026, 8, 25, 8);

  test('IDs são estáveis, positivos e distintos por slot e UID', () {
    final first = cycleReminderNotificationIds(userId);
    final second = cycleReminderNotificationIds(userId);

    expect(first, second);
    expect(first, hasLength(8));
    expect(first.toSet(), hasLength(8));
    expect(first.every((id) => id > 0), isTrue);
    expect(
      cycleReminderNotificationId(userId, 0),
      isNot(cycleReminderNotificationId('user-b', 0)),
    );
  });

  test('cancelamento tenta todos os oito slots', () async {
    final service = _RecordingNotificationService();
    final lifecycle = CycleReminderNotificationLifecycleService(service);

    final failed = await lifecycle.cancelAllCycleReminders(userId);

    expect(failed, 0);
    expect(service.cancellationAttempts, cycleReminderNotificationIds(userId));
  });

  test('falha em um cancelamento não interrompe os demais', () async {
    final service = _RecordingNotificationService();
    service.failedCancellations.add(cycleReminderNotificationId(userId, 3));
    final lifecycle = CycleReminderNotificationLifecycleService(service);

    final failed = await lifecycle.cancelAllCycleReminders(userId);

    expect(failed, 1);
    expect(service.cancellationAttempts, hasLength(8));
  });

  test(
    'daily agenda uma recorrência hoje quando horário ainda não passou',
    () async {
      final service = _RecordingNotificationService();
      final lifecycle = CycleReminderNotificationLifecycleService(
        service,
        clock: () => now,
      );

      final result = await lifecycle.rebuildCycleReminders(
        userId,
        _preferences(),
      );

      expect(result.eligible, 1);
      expect(result.scheduled, 1);
      expect(service.schedules, hasLength(1));
      expect(
        service.schedules.single.id,
        cycleReminderNotificationId(userId, 0),
      );
      expect(service.schedules.single.date, DateTime(2026, 8, 25, 9, 30));
      expect(service.schedules.single.components, DateTimeComponents.time);
    },
  );

  test('daily usa amanhã quando horário já passou', () async {
    final service = _RecordingNotificationService();
    final lifecycle = CycleReminderNotificationLifecycleService(
      service,
      clock: () => DateTime(2026, 8, 25, 10),
    );

    await lifecycle.rebuildCycleReminders(userId, _preferences());

    expect(service.schedules.single.date, DateTime(2026, 8, 26, 9, 30));
  });

  test('specific weekdays agenda somente dias selecionados', () async {
    final service = _RecordingNotificationService();
    final lifecycle = CycleReminderNotificationLifecycleService(
      service,
      clock: () => now,
    );

    final result = await lifecycle.rebuildCycleReminders(
      userId,
      _preferences(
        frequency: CycleReminderFrequency.specificWeekdays,
        weekdays: const {DateTime.tuesday, DateTime.thursday},
      ),
    );

    expect(result.eligible, 2);
    expect(result.scheduled, 2);
    expect(service.schedules.map((entry) => entry.id), [
      cycleReminderNotificationId(userId, DateTime.tuesday),
      cycleReminderNotificationId(userId, DateTime.thursday),
    ]);
    expect(
      service.schedules.every(
        (entry) => entry.components == DateTimeComponents.dayOfWeekAndTime,
      ),
      isTrue,
    );
    expect(service.schedules.first.date, DateTime(2026, 8, 25, 9, 30));
    expect(service.schedules.last.date, DateTime(2026, 8, 27, 9, 30));
  });

  test(
    'rebuild cancela todos os slots antes de agendar nova frequência',
    () async {
      final service = _RecordingNotificationService();
      final lifecycle = CycleReminderNotificationLifecycleService(
        service,
        clock: () => now,
      );

      await lifecycle.rebuildCycleReminders(
        userId,
        _preferences(
          frequency: CycleReminderFrequency.specificWeekdays,
          weekdays: const {DateTime.monday, DateTime.friday},
        ),
      );
      service.events.clear();
      await lifecycle.rebuildCycleReminders(userId, _preferences());

      expect(
        service.events.take(8).every((event) => event.startsWith('cancel:')),
        isTrue,
      );
      expect(service.events.skip(8), hasLength(1));
      expect(service.events.last, startsWith('schedule:'));
    },
  );

  test(
    'daily para specific também remove o slot diário antes do rebuild',
    () async {
      final service = _RecordingNotificationService();
      final lifecycle = CycleReminderNotificationLifecycleService(
        service,
        clock: () => now,
      );

      await lifecycle.rebuildCycleReminders(userId, _preferences());
      service.events.clear();
      await lifecycle.rebuildCycleReminders(
        userId,
        _preferences(
          frequency: CycleReminderFrequency.specificWeekdays,
          weekdays: const {DateTime.wednesday},
        ),
      );

      expect(
        service.events.first,
        'cancel:${cycleReminderNotificationId(userId, 0)}',
      );
      expect(
        service.events.take(8).every((event) => event.startsWith('cancel:')),
        isTrue,
      );
    },
  );

  test('falha parcial em weekday não impede os seguintes', () async {
    final service = _RecordingNotificationService();
    service.failedSchedules.add(
      cycleReminderNotificationId(userId, DateTime.tuesday),
    );
    final lifecycle = CycleReminderNotificationLifecycleService(
      service,
      clock: () => now,
    );

    final result = await lifecycle.rebuildCycleReminders(
      userId,
      _preferences(
        frequency: CycleReminderFrequency.specificWeekdays,
        weekdays: const {DateTime.tuesday, DateTime.thursday, DateTime.friday},
      ),
    );

    expect(result.scheduled, 2);
    expect(result.failed, 1);
    expect(service.schedules, hasLength(3));
  });

  test('payload discreto nunca expõe tipo ou texto customizado', () {
    final payload = cycleReminderNotificationPayload(
      _preferences(
        type: CycleReminderType.pill,
        privacyMode: CycleReminderPrivacyMode.discreet,
      ),
    );

    expect(payload.title, 'Lembrete pessoal');
    expect(payload.body, 'Você tem um lembrete programado.');
    expect(
      '${payload.title} ${payload.body}'.toLowerCase(),
      isNot(contains('pílula')),
    );
    expect(
      '${payload.title} ${payload.body}'.toLowerCase(),
      isNot(contains('contraceptivo')),
    );
  });

  test('payload informativo usa tipo e corpo neutro aprovados', () {
    final pill = cycleReminderNotificationPayload(
      _preferences(
        type: CycleReminderType.pill,
        privacyMode: CycleReminderPrivacyMode.informative,
      ),
    );
    final contraceptive = cycleReminderNotificationPayload(
      _preferences(
        type: CycleReminderType.otherContraceptive,
        privacyMode: CycleReminderPrivacyMode.informative,
      ),
    );

    expect(pill.title, 'Lembrete de pílula');
    expect(contraceptive.title, 'Lembrete de contraceptivo');
    expect(pill.body, 'Horário do seu lembrete.');
  });

  test('payload personalizado usa exatamente os textos sanitizados', () {
    final preferences = _preferences(
      privacyMode: CycleReminderPrivacyMode.custom,
      customTitle: '  Meu\n lembrete  ',
      customBody: '  Conteúdo\t privado  ',
    );

    final payload = cycleReminderNotificationPayload(preferences);

    expect(payload.title, preferences.customTitle);
    expect(payload.body, preferences.customBody);
    expect(payload.title, 'Meu lembrete');
    expect(payload.body, 'Conteúdo privado');
  });
}
