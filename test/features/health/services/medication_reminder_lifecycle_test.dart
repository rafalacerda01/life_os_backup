import 'dart:async';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/services/notification_service.dart';
import 'package:life_os/core/services/notification_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:life_os/features/health/services/medication_reminder_lifecycle.dart';

class _RecordingNotificationService extends NotificationService {
  final List<int> cancelledIds = [];
  final List<Object> cancelResults = [];
  final List<int> scheduledIds = [];
  final List<DateTime> scheduledDates = [];
  final List<Object> scheduleResults = [];
  final pending = <PendingNotificationRequest>[];
  final repeats = <bool>[];
  final payloads = <String?>[];
  bool failPending = false;
  Future<void> Function()? beforeSchedule;
  int concurrent = 0;
  int maxConcurrent = 0;

  @override
  Future<List<PendingNotificationRequest>> pendingNotificationRequests() async {
    if (failPending) throw StateError('private-native-query-marker');
    return List.of(pending);
  }

  @override
  Future<void> cancelNotificationOrThrow(int id) async {
    cancelledIds.add(id);
    final result = cancelResults.isEmpty ? true : cancelResults.removeAt(0);
    if (result is Exception) throw result;
    pending.removeWhere((request) => request.id == id);
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
  }) async {
    scheduledIds.add(id);
    scheduledDates.add(scheduledDate);
    repeats.add(repeatDaily);
    payloads.add(payload);
    concurrent += 1;
    if (concurrent > maxConcurrent) maxConcurrent = concurrent;
    try {
      await beforeSchedule?.call();
    } finally {
      concurrent -= 1;
    }
    final result = scheduleResults.isEmpty ? true : scheduleResults.removeAt(0);
    if (result is Exception) throw result;
    if (result == true) {
      pending.removeWhere((request) => request.id == id);
      pending.add(PendingNotificationRequest(id, title, body, payload));
    }
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
    SharedPreferences.setMockInitialValues({});
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
      DateTime(2026, 8, 25, 21),
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
    expect(notificationService.cancelledIds, [
      notificationIdForMedication('med-last-day-expired'),
    ]);
  });

  test('rebuild preserva início futuro e seu horário', () async {
    final startDate = DateTime(2026, 9, 2, 7, 30);
    await insertMedication(
      firestoreId: 'med-future',
      startDate: startDate,
      durationDays: 5,
    );

    final result = await lifecycle.rebuildMedicationReminders();

    expect(result.scheduled, 6);
    expect(notificationService.scheduledDates.first, startDate);
    expect(
      notificationService.scheduledDates.last,
      DateTime(2026, 9, 7, 7, 30),
    );
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
    expect(notificationService.cancelledIds, [
      notificationIdForMedication('med-ended'),
    ]);
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
    expect(notificationService.cancelledIds, [
      notificationIdForMedication('med-derived-ended'),
    ]);
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

  test(
    'rebuild mistura ativo, expirado e aberto sem recriar expirado',
    () async {
      await insertMedication(
        firestoreId: 'active',
        startDate: DateTime(2026, 8, 20, 21),
        endDate: DateTime(2026, 8, 26),
      );
      await insertMedication(
        firestoreId: 'expired',
        startDate: DateTime(2026, 8, 20, 21),
        endDate: DateTime(2026, 8, 24),
      );
      await insertMedication(
        firestoreId: 'open',
        startDate: DateTime(2026, 8, 20, 21),
      );
      final result = await lifecycle.rebuildMedicationReminders();
      expect(notificationService.scheduledIds, [
        notificationIdForMedication('open'),
        notificationIdForMedicationOccurrence(
          'active',
          DateTime(2026, 8, 25, 21),
        ),
        notificationIdForMedicationOccurrence(
          'active',
          DateTime(2026, 8, 26, 21),
        ),
      ]);
      expect(notificationService.cancelledIds, [
        notificationIdForMedication('active'),
        notificationIdForMedication('expired'),
        notificationIdForMedication('open'),
      ]);
      expect(result.eligible, 2);
      expect(result.scheduled, 3);
      expect(result.failed, 0);
    },
  );

  test('falha ao cancelar expirado não impede ativo e aberto', () async {
    await insertMedication(
      firestoreId: 'expired',
      startDate: DateTime(2026, 8, 20, 21),
      durationDays: 1,
    );
    await insertMedication(
      firestoreId: 'active',
      startDate: DateTime(2026, 8, 20, 21),
      durationDays: 10,
    );
    await insertMedication(
      firestoreId: 'open',
      startDate: DateTime(2026, 8, 20, 21),
    );
    notificationService.cancelResults.add(Exception('private-cancel-marker'));
    final result = await lifecycle.rebuildMedicationReminders();
    expect(notificationService.cancelledIds, [
      notificationIdForMedication('expired'),
      notificationIdForMedication('active'),
      notificationIdForMedication('open'),
    ]);
    expect(result.scheduled, 7);
    expect(result.failed, 1);
  });

  test(
    'finite materializa todos os dias inclusivos como one-shots V2',
    () async {
      await insertMedication(
        firestoreId: 'finite',
        startDate: DateTime(2026, 8, 20, 21, 15),
        endDate: DateTime(2026, 8, 27),
      );
      final result = await lifecycle.rebuildMedicationReminders();
      expect(result.scheduled, 3);
      expect(notificationService.scheduledDates, [
        DateTime(2026, 8, 25, 21, 15),
        DateTime(2026, 8, 26, 21, 15),
        DateTime(2026, 8, 27, 21, 15),
      ]);
      expect(notificationService.repeats, everyElement(isFalse));
      expect(
        notificationService.payloads,
        everyElement('${medicationReminderPayloadPrefix}finite'),
      );
      expect(notificationService.scheduledIds.toSet(), hasLength(3));
      expect(
        notificationService.scheduledIds,
        everyElement(allOf(greaterThan(0), lessThanOrEqualTo(0x7fffffff))),
      );
    },
  );

  test(
    'durationDays continua start + duration, com último dia inclusivo',
    () async {
      await insertMedication(
        firestoreId: 'derived',
        startDate: DateTime(2026, 8, 25, 21),
        durationDays: 2,
      );
      await lifecycle.rebuildMedicationReminders();
      expect(notificationService.scheduledDates, [
        DateTime(2026, 8, 25, 21),
        DateTime(2026, 8, 26, 21),
        DateTime(2026, 8, 27, 21),
      ]);
      expect(notificationService.repeats, everyElement(isFalse));
    },
  );

  test(
    'open-ended usa um slot recorrente e payload sem dados médicos',
    () async {
      await insertMedication(
        firestoreId: 'open',
        startDate: DateTime(2026, 8, 20, 21),
      );
      await lifecycle.rebuildMedicationReminders();
      expect(notificationService.repeats, [true]);
      expect(notificationService.payloads, [
        '${medicationReminderPayloadPrefix}open',
      ]);
      expect(notificationService.pending, hasLength(1));
    },
  );

  test(
    'budget global distribui primeira ocorrência antes dos extras',
    () async {
      for (var i = 0; i < 4; i++) {
        await insertMedication(
          firestoreId: 'open-$i',
          startDate: DateTime(2026, 8, 25, 21),
        );
      }
      for (var i = 0; i < 30; i++) {
        await insertMedication(
          firestoreId: 'finite-$i',
          startDate: DateTime(2026, 8, 25, 21),
          durationDays: 3650,
        );
      }
      await lifecycle.rebuildMedicationReminders();
      expect(
        notificationService.pending,
        hasLength(medicationNativePendingBudget),
      );
      expect(notificationService.repeats.where((value) => value), hasLength(4));
      final finiteFirst = notificationService.payloads.skip(4).take(30).toSet();
      expect(finiteFirst, hasLength(30));
      expect(
        notificationService.scheduledDates.skip(4).take(30),
        everyElement(DateTime(2026, 8, 25, 21)),
      );
      expect(
        notificationService.scheduledDates.skip(34),
        everyElement(DateTime(2026, 8, 26, 21)),
      );
      final ids = notificationService.pending
          .map((request) => request.id)
          .toSet();
      await lifecycle.rebuildMedicationReminders();
      expect(notificationService.pending, hasLength(48));
      expect(
        notificationService.pending.map((request) => request.id).toSet(),
        ids,
      );
    },
  );

  for (final finite in [false, true]) {
    test('60 registros legados finite=$finite nunca excedem budget', () async {
      for (var i = 0; i < 60; i++) {
        await insertMedication(
          firestoreId: 'legacy-$i',
          startDate: DateTime(2026, 8, 25, 21),
          durationDays: finite ? 3650 : null,
        );
      }
      await lifecycle.rebuildMedicationReminders();
      expect(notificationService.pending, hasLength(48));
      expect(notificationService.payloads.toSet(), hasLength(48));
    });
  }

  test(
    'migration remove recurrence legacy e órfão V2 sem tocar Cycle',
    () async {
      await insertMedication(
        firestoreId: 'finite',
        startDate: DateTime(2026, 8, 25, 21),
        durationDays: 1,
      );
      final legacyId = notificationIdForMedication('finite');
      notificationService.pending.addAll([
        PendingNotificationRequest(
          legacyId,
          'Hora do medicamento 💊',
          'Está na hora de tomar: Legado',
          null,
        ),
        const PendingNotificationRequest(
          91,
          null,
          null,
          'life_os_medication_v2:deleted',
        ),
        const PendingNotificationRequest(92, 'Cycle', 'Private', 'cycle-v1'),
        const PendingNotificationRequest(93, 'Other', 'Private', null),
      ]);
      await lifecycle.rebuildMedicationReminders();
      expect(notificationService.cancelledIds, containsAll([legacyId, 91]));
      expect(notificationService.cancelledIds, isNot(contains(92)));
      expect(notificationService.cancelledIds, isNot(contains(93)));
      expect(
        notificationService.pending.map((request) => request.id),
        containsAll([92, 93]),
      );
      expect(notificationService.repeats, everyElement(isFalse));
    },
  );

  test(
    'delete remove todas as occurrences, inclusive órfãos sem linha Drift',
    () async {
      await insertMedication(
        firestoreId: 'deleted',
        startDate: DateTime(2026, 8, 25, 21),
        durationDays: 3,
      );
      await lifecycle.rebuildMedicationReminders();
      final ids = notificationService.pending
          .map((request) => request.id)
          .toSet();
      expect(ids, hasLength(4));
      await db.delete(db.medications).go();
      await lifecycle.rebuildMedicationReminders();
      expect(notificationService.pending, isEmpty);
      expect(notificationService.cancelledIds, containsAll(ids));
    },
  );

  test(
    'encurtar endDate remove stale occurrences e preserva último dia',
    () async {
      await insertMedication(
        firestoreId: 'shortened',
        startDate: DateTime(2026, 8, 25, 21),
        durationDays: 5,
      );
      await lifecycle.rebuildMedicationReminders();
      await db
          .update(db.medications)
          .write(MedicationsCompanion(endDate: Value(DateTime(2026, 8, 26))));
      await lifecycle.rebuildMedicationReminders();
      expect(notificationService.pending, hasLength(2));
      expect(notificationService.pending.map((request) => request.id).toSet(), {
        notificationIdForMedicationOccurrence(
          'shortened',
          DateTime(2026, 8, 25),
        ),
        notificationIdForMedicationOccurrence(
          'shortened',
          DateTime(2026, 8, 26),
        ),
      });
    },
  );

  test('collision com outro módulo não o cancela nem sobrescreve', () async {
    await insertMedication(
      firestoreId: 'collision',
      startDate: DateTime(2026, 8, 25, 21),
      durationDays: 1,
    );
    final id = notificationIdForMedicationOccurrence(
      'collision',
      DateTime(2026, 8, 25),
    );
    final base = notificationIdForMedication('collision');
    notificationService.pending.addAll([
      PendingNotificationRequest(id, 'Cycle', null, 'cycle-v1'),
      PendingNotificationRequest(base, 'Other', null, 'other'),
    ]);
    await lifecycle.rebuildMedicationReminders();
    expect(notificationService.scheduledIds, isNot(contains(id)));
    expect(notificationService.cancelledIds, isNot(contains(base)));
    expect(
      notificationService.pending.map((request) => request.id),
      containsAll([id, base]),
    );
  });

  test(
    'colisão real de IDs base não sobrescreve outro medicamento no rebuild',
    () async {
      const first = 'med-1btnkum';
      const second = 'med-1gu0o5a';
      expect(
        notificationIdForMedication(first),
        notificationIdForMedication(second),
      );
      await insertMedication(
        firestoreId: second,
        startDate: DateTime(2026, 8, 25, 21),
      );
      await insertMedication(
        firestoreId: first,
        startDate: DateTime(2026, 8, 25, 21),
      );
      await lifecycle.rebuildMedicationReminders();
      final ids = notificationService.pending
          .map((request) => request.id)
          .toSet();
      expect(ids, hasLength(2));
      expect(
        notificationService.pending.map((request) => request.payload).toSet(),
        {
          '$medicationReminderPayloadPrefix$first',
          '$medicationReminderPayloadPrefix$second',
        },
      );
      await lifecycle.rebuildMedicationReminders();
      expect(
        notificationService.pending.map((request) => request.id).toSet(),
        ids,
      );
    },
  );

  test(
    'cleanup incompleto reserva slot sobrevivente no budget global',
    () async {
      await insertMedication(
        firestoreId: 'finite',
        startDate: DateTime(2026, 8, 25, 21),
        durationDays: 3650,
      );
      notificationService.pending.add(
        const PendingNotificationRequest(
          91,
          null,
          null,
          'life_os_medication_v2:orphan',
        ),
      );
      notificationService.cancelResults.add(
        Exception('private-cleanup-failure'),
      );
      final result = await lifecycle.rebuildMedicationReminders();
      expect(result.failed, 1);
      expect(result.scheduled, 47);
      expect(notificationService.pending, hasLength(48));
      expect(
        notificationService.pending.map((request) => request.id),
        contains(91),
      );
    },
  );

  test('pending query failure não agenda nem finge cleanup', () async {
    await insertMedication(
      firestoreId: 'finite',
      startDate: DateTime(2026, 8, 25, 21),
      durationDays: 2,
    );
    notificationService.failPending = true;
    final result = await lifecycle.rebuildMedicationReminders();
    expect(result.failed, 1);
    expect(result.scheduled, 0);
    expect(notificationService.cancelledIds, isEmpty);
    expect(notificationService.scheduledIds, isEmpty);
  });

  test(
    'legacy cancel failure bloqueia novos schedules do mesmo medicamento',
    () async {
      await insertMedication(
        firestoreId: 'finite',
        startDate: DateTime(2026, 8, 25, 21),
        durationDays: 2,
      );
      final id = notificationIdForMedication('finite');
      notificationService.pending.add(
        PendingNotificationRequest(
          id,
          'Hora do medicamento 💊',
          'Está na hora de tomar: Legado',
          null,
        ),
      );
      notificationService.cancelResults.add(Exception('private-failure'));
      final result = await lifecycle.rebuildMedicationReminders();
      expect(result.failed, 1);
      expect(result.scheduled, 0);
      expect(notificationService.pending.single.id, id);
    },
  );

  test('revogação durante segundo schedule compensa toda geração', () async {
    await insertMedication(
      firestoreId: 'finite',
      startDate: DateTime(2026, 8, 25, 21),
      durationDays: 2,
    );
    var allowed = true;
    final started = Completer<void>();
    final release = Completer<void>();
    notificationService.beforeSchedule = () async {
      if (notificationService.scheduledIds.length == 2) {
        started.complete();
        await release.future;
      }
    };
    final rebuild = lifecycle.rebuildMedicationReminders(
      shouldContinue: () => allowed,
    );
    await started.future;
    expect(notificationService.pending, hasLength(1));
    allowed = false;
    release.complete();
    final result = await rebuild;
    expect(notificationService.scheduledIds, hasLength(2));
    expect(notificationService.pending, isEmpty);
    expect(result.scheduled, 0);
    expect(
      notificationService.cancelledIds,
      containsAll(notificationService.scheduledIds),
    );
  });

  test('dois rebuilds diretos compartilham tail sem sobreposição', () async {
    await insertMedication(
      firestoreId: 'open',
      startDate: DateTime(2026, 8, 25, 21),
    );
    final started = Completer<void>();
    final release = Completer<void>();
    notificationService.beforeSchedule = () async {
      if (!started.isCompleted) started.complete();
      await release.future;
    };
    final first = lifecycle.rebuildMedicationReminders();
    await started.future;
    final second = lifecycle.rebuildMedicationReminders();
    expect(notificationService.scheduledIds, hasLength(1));
    release.complete();
    await Future.wait([first, second]);
    expect(notificationService.maxConcurrent, 1);
    expect(notificationService.pending, hasLength(1));
  });

  for (final preference in [
    NotificationPreferenceKeys.allNotifications,
    NotificationPreferenceKeys.medicationReminders,
  ]) {
    test('$preference OFF cancela V2 sem recriar', () async {
      await insertMedication(
        firestoreId: 'finite',
        startDate: DateTime(2026, 8, 25, 21),
        durationDays: 2,
      );
      await lifecycle.rebuildMedicationReminders();
      SharedPreferences.setMockInitialValues({preference: false});
      final result = await lifecycle.rebuildMedicationReminders();
      expect(result.scheduled, 0);
      expect(notificationService.pending, isEmpty);
      expect(notificationService.scheduledIds, hasLength(3));
    });
  }

  test('endDate explícito tem prioridade sobre durationDays', () {
    expect(
      isMedicationReminderEligible(
        startDate: DateTime(2026, 8, 20, 21),
        durationDays: 1,
        endDate: DateTime(2026, 8, 30),
        now: DateTime(2026, 8, 25, 12),
      ),
      isTrue,
    );
  });
}
