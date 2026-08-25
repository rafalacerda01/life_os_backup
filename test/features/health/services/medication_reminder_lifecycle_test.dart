import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/services/notification_service.dart';
import 'package:life_os/features/health/services/medication_reminder_lifecycle.dart';

class _RecordingNotificationService extends NotificationService {
  final List<int> cancelledIds = [];
  final List<Object> cancelResults = [];
  final List<int> scheduledIds = [];
  final List<DateTime> scheduledDates = [];
  final List<Object> scheduleResults = [];

  @override
  Future<void> cancelNotification(int id) async {
    cancelledIds.add(id);
    final result = cancelResults.isEmpty ? true : cancelResults.removeAt(0);
    if (result is Exception) throw result;
  }

  @override
  Future<bool> scheduleMedicationNotification({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledDate,
    String? preferenceKey,
    bool repeatDaily = false,
  }) async {
    scheduledIds.add(id);
    scheduledDates.add(scheduledDate);
    final result = scheduleResults.isEmpty ? true : scheduleResults.removeAt(0);
    if (result is Exception) throw result;
    return result as bool;
  }
}

void main() {
  late AppDatabase db;
  late _RecordingNotificationService notificationService;
  late MedicationReminderLifecycleService lifecycle;

  Future<void> insertMedication({
    required String firestoreId,
    required DateTime startDate,
    int? durationDays,
    DateTime? endDate,
  }) async {
    await db
        .into(db.medications)
        .insert(
          MedicationsCompanion.insert(
            firestoreId: firestoreId,
            name: 'Medicamento de teste',
            startDate: startDate,
            durationDays: Value(durationDays),
            endDate: Value(endDate),
          ),
        );
  }

  setUp(() {
    db = AppDatabase(executor: NativeDatabase.memory());
    notificationService = _RecordingNotificationService();
    lifecycle = MedicationReminderLifecycleService(
      db,
      notificationService,
      now: () => DateTime(2026, 8, 25, 12),
    );
  });

  tearDown(() => db.closeDatabase());

  test(
    'cancelamento usa somente IDs determinísticos de medicamentos',
    () async {
      await insertMedication(
        firestoreId: 'med-active',
        startDate: DateTime(2026, 8, 20, 21),
      );
      await insertMedication(
        firestoreId: 'med-ended',
        startDate: DateTime(2026, 8, 1, 8),
        endDate: DateTime(2026, 8, 10, 8),
      );

      await lifecycle.cancelAllMedicationReminders();

      expect(
        notificationService.cancelledIds,
        containsAll(<int>[
          notificationIdForMedication('med-active'),
          notificationIdForMedication('med-ended'),
        ]),
      );
      expect(notificationService.cancelledIds, hasLength(2));
    },
  );

  test('falha de cancelamento não interrompe medicamentos seguintes', () async {
    for (var index = 0; index < 3; index += 1) {
      await insertMedication(
        firestoreId: 'med-cancel-$index',
        startDate: DateTime(2026, 8, 20, 21),
      );
    }
    notificationService.cancelResults.addAll(<Object>[
      true,
      Exception('private cancellation failure'),
      true,
    ]);

    await expectLater(lifecycle.cancelAllMedicationReminders(), completes);

    expect(notificationService.cancelledIds, <int>[
      notificationIdForMedication('med-cancel-0'),
      notificationIdForMedication('med-cancel-1'),
      notificationIdForMedication('med-cancel-2'),
    ]);
  });

  test('rebuild agenda medicamento ativo com limite inclusivo', () async {
    await insertMedication(
      firestoreId: 'med-active',
      startDate: DateTime(2026, 8, 20, 21),
      endDate: DateTime(2026, 8, 25, 8),
    );

    final result = await lifecycle.rebuildMedicationReminders();

    expect(result.eligible, 1);
    expect(result.scheduled, 1);
    expect(result.failed, 0);
  });

  test('último dia agenda quando a ocorrência ainda é futura hoje', () async {
    await insertMedication(
      firestoreId: 'med-last-day-valid',
      startDate: DateTime(2026, 8, 20, 21),
      endDate: DateTime(2026, 8, 25, 21),
    );

    final result = await lifecycle.rebuildMedicationReminders();

    expect(result.eligible, 1);
    expect(result.scheduled, 1);
    expect(notificationService.scheduledDates, <DateTime>[
      DateTime(2026, 8, 20, 21),
    ]);
  });

  test('último dia não cria ocorrência depois do término', () async {
    lifecycle = MedicationReminderLifecycleService(
      db,
      notificationService,
      now: () => DateTime(2026, 8, 25, 22),
    );
    await insertMedication(
      firestoreId: 'med-last-day-expired',
      startDate: DateTime(2026, 8, 20, 21),
      endDate: DateTime(2026, 8, 25, 21),
    );

    final result = await lifecycle.rebuildMedicationReminders();

    expect(result.eligible, 0);
    expect(notificationService.scheduledIds, isEmpty);
  });

  test('rebuild preserva início futuro e seu horário', () async {
    final startDate = DateTime(2026, 9, 2, 7, 30);
    await insertMedication(
      firestoreId: 'med-future',
      startDate: startDate,
      durationDays: 5,
    );

    final result = await lifecycle.rebuildMedicationReminders();

    expect(result.scheduled, 1);
    expect(notificationService.scheduledDates.single, startDate);
  });

  test('rebuild ignora medicamento encerrado', () async {
    await insertMedication(
      firestoreId: 'med-ended',
      startDate: DateTime(2026, 8, 1, 21),
      endDate: DateTime(2026, 8, 24, 23, 59),
    );

    final result = await lifecycle.rebuildMedicationReminders();

    expect(result.eligible, 0);
    expect(notificationService.scheduledIds, isEmpty);
  });

  test('durationDays deriva término quando endDate está ausente', () async {
    await insertMedication(
      firestoreId: 'med-derived-ended',
      startDate: DateTime(2026, 8, 20, 21),
      durationDays: 4,
    );

    final result = await lifecycle.rebuildMedicationReminders();

    expect(result.eligible, 0);
    expect(notificationService.scheduledIds, isEmpty);
  });

  test('durationDays com término hoje respeita a próxima ocorrência', () async {
    await insertMedication(
      firestoreId: 'med-derived-last-day',
      startDate: DateTime(2026, 8, 20, 21),
      durationDays: 5,
    );

    final result = await lifecycle.rebuildMedicationReminders();

    expect(result.eligible, 1);
    expect(result.scheduled, 1);
  });

  test('sem endDate preserva rebuild diário', () async {
    lifecycle = MedicationReminderLifecycleService(
      db,
      notificationService,
      now: () => DateTime(2026, 8, 25, 22),
    );
    await insertMedication(
      firestoreId: 'med-open-ended',
      startDate: DateTime(2026, 8, 20, 21),
    );

    final result = await lifecycle.rebuildMedicationReminders();

    expect(result.eligible, 1);
    expect(result.scheduled, 1);
  });

  test('falha parcial não interrompe os demais agendamentos', () async {
    for (var index = 0; index < 3; index += 1) {
      await insertMedication(
        firestoreId: 'med-$index',
        startDate: DateTime(2026, 8, 20, 21),
      );
    }
    notificationService.scheduleResults.addAll(<Object>[
      true,
      Exception('private scheduling failure'),
      true,
    ]);

    final result = await lifecycle.rebuildMedicationReminders();

    expect(notificationService.scheduledIds, hasLength(3));
    expect(result.eligible, 3);
    expect(result.scheduled, 2);
    expect(result.failed, 1);
  });

  test('horário legado 00:00 permanece inalterado', () async {
    final legacyStart = DateTime(2026, 8, 20);
    await insertMedication(
      firestoreId: 'med-legacy-midnight',
      startDate: legacyStart,
    );

    await lifecycle.rebuildMedicationReminders();

    expect(notificationService.scheduledDates.single, legacyStart);
  });
}
