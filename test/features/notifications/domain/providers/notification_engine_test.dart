import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/database_provider.dart';
import 'package:life_os/core/services/notification_preferences.dart';
import 'package:life_os/features/notifications/data/repositories/notifications_repository.dart';
import 'package:life_os/features/notifications/domain/models/notification_model.dart';
import 'package:life_os/features/notifications/domain/providers/notification_engine.dart';

class _FakeFirebaseFirestore extends Fake implements FirebaseFirestore {}

class _FakeUser extends Fake implements User {
  _FakeUser(this.uid);

  @override
  final String uid;
}

class _FakeFirebaseAuth extends Fake implements FirebaseAuth {
  _FakeFirebaseAuth([this.user]);

  User? user;

  @override
  User? get currentUser => user;
}

class _FakeNotificationPreferencesStore extends NotificationPreferencesStore {
  const _FakeNotificationPreferencesStore();

  @override
  Future<NotificationPreferences> load() async {
    return const NotificationPreferences.enabled();
  }
}

class _TrackingNotificationsRepository extends NotificationsRepository {
  _TrackingNotificationsRepository(
    AppDatabase db, {
    FirebaseAuth? auth,
    super.remoteDelete,
  }) : super(
         firestore: _FakeFirebaseFirestore(),
         auth: auth ?? _FakeFirebaseAuth(),
         localDao: db.notificationDao,
       );

  final savedIds = <String>[];
  final deletedIds = <String>[];
  int syncCalls = 0;
  int watchCalls = 0;

  @override
  Stream<List<NotificationModel>> watchLocalNotifications() {
    watchCalls += 1;
    return super.watchLocalNotifications();
  }

  @override
  Future<void> syncNotificationsFromFirebaseToLocal() async {
    syncCalls += 1;
  }

  @override
  Future<void> saveLocalNotification(NotificationModel notification) async {
    savedIds.add(notification.id);
    await super.saveLocalNotification(notification);
  }

  @override
  Future<void> deleteNotification(String id) async {
    deletedIds.add(id);
    await super.deleteNotification(id);
  }
}

void main() {
  const reconciler = NotificationModuleReconciler();
  final today = DateTime(2026, 8, 25, 10, 30);
  final todayStart = DateTime(2026, 8, 25);
  final yesterday = DateTime(2026, 8, 24);
  final tomorrow = DateTime(2026, 8, 26);

  late AppDatabase db;
  late _TrackingNotificationsRepository repository;

  group('NotificationBootstrapCoordinator', () {
    test('compartilha bootstrap concorrente do mesmo UID e dia', () async {
      final coordinator = NotificationBootstrapCoordinator();
      final release = Completer<void>();
      var calls = 0;

      Future<void> bootstrap() async {
        calls += 1;
        await release.future;
      }

      final first = coordinator.ensureBootstrapped(
        uid: 'user-a',
        now: DateTime(2026, 9, 13, 8),
        bootstrap: bootstrap,
      );
      final second = coordinator.ensureBootstrapped(
        uid: 'user-a',
        now: DateTime(2026, 9, 13, 18),
        bootstrap: bootstrap,
      );

      expect(identical(first, second), isTrue);
      expect(calls, 1);

      release.complete();
      await Future.wait([first, second]);

      await coordinator.ensureBootstrapped(
        uid: 'user-a',
        now: DateTime(2026, 9, 13, 23),
        bootstrap: bootstrap,
      );
      expect(calls, 1);
    });

    test('bootstrap de UID diferente aguarda o job em voo', () async {
      final coordinator = NotificationBootstrapCoordinator();
      final releaseA = Completer<void>();
      var callsA = 0;
      var callsB = 0;
      var running = 0;
      var maxRunning = 0;

      Future<void> track(Future<void> Function() operation) async {
        running += 1;
        if (running > maxRunning) maxRunning = running;
        try {
          await operation();
        } finally {
          running -= 1;
        }
      }

      final bootstrapA = coordinator.ensureBootstrapped(
        uid: 'user-a',
        now: DateTime(2026, 9, 13),
        bootstrap: () => track(() async {
          callsA += 1;
          await releaseA.future;
        }),
      );
      final bootstrapB = coordinator.ensureBootstrapped(
        uid: 'user-b',
        now: DateTime(2026, 9, 13),
        bootstrap: () => track(() async {
          callsB += 1;
        }),
      );

      expect(callsA, 1);
      expect(callsB, 0);

      releaseA.complete();
      await Future.wait([bootstrapA, bootstrapB]);

      expect(callsB, 1);
      expect(maxRunning, 1);
    });

    test('novo UID e novo dia executam seus próprios bootstraps', () async {
      final coordinator = NotificationBootstrapCoordinator();
      var calls = 0;

      Future<void> bootstrap() async {
        calls += 1;
      }

      await coordinator.ensureBootstrapped(
        uid: 'user-a',
        now: DateTime(2026, 9, 13),
        bootstrap: bootstrap,
      );
      await coordinator.ensureBootstrapped(
        uid: 'user-b',
        now: DateTime(2026, 9, 13),
        bootstrap: bootstrap,
      );
      await coordinator.ensureBootstrapped(
        uid: 'user-b',
        now: DateTime(2026, 9, 14),
        bootstrap: bootstrap,
      );

      expect(calls, 3);
    });

    test('falha não conclui gate e permite nova tentativa', () async {
      final coordinator = NotificationBootstrapCoordinator();
      var calls = 0;

      Future<void> bootstrap() async {
        calls += 1;
        if (calls == 1) throw StateError('bootstrap failed');
      }

      await expectLater(
        coordinator.ensureBootstrapped(
          uid: 'user-a',
          now: DateTime(2026, 9, 13),
          bootstrap: bootstrap,
        ),
        throwsStateError,
      );
      await coordinator.ensureBootstrapped(
        uid: 'user-a',
        now: DateTime(2026, 9, 13),
        bootstrap: bootstrap,
      );

      expect(calls, 2);
    });

    test(
      'reset durante bootstrap enfileira nova execução sem sobrepor',
      () async {
        final coordinator = NotificationBootstrapCoordinator();
        final release = Completer<void>();
        var calls = 0;
        var running = 0;
        var maxRunning = 0;

        Future<void> bootstrap() async {
          calls += 1;
          running += 1;
          if (running > maxRunning) maxRunning = running;
          if (calls == 1) await release.future;
          running -= 1;
        }

        final first = coordinator.ensureBootstrapped(
          uid: 'user-a',
          now: DateTime(2026, 9, 13),
          bootstrap: bootstrap,
        );
        coordinator.reset();
        final afterReset = coordinator.ensureBootstrapped(
          uid: 'user-a',
          now: DateTime(2026, 9, 13),
          bootstrap: bootstrap,
        );

        expect(calls, 1);
        release.complete();
        await Future.wait([first, afterReset]);

        expect(calls, 2);
        expect(maxRunning, 1);
      },
    );

    test('resetAndDrain aguarda e não conclui o gate antigo', () async {
      final coordinator = NotificationBootstrapCoordinator();
      final release = Completer<void>();
      var calls = 0;
      var drainCompleted = false;

      final bootstrap = coordinator.ensureBootstrapped(
        uid: 'user-a',
        now: DateTime(2026, 9, 13),
        bootstrap: () async {
          calls += 1;
          await release.future;
        },
      );
      final drain = coordinator.resetAndDrain().then((_) {
        drainCompleted = true;
      });

      await Future<void>.value();
      expect(drainCompleted, isFalse);

      release.complete();
      await Future.wait([bootstrap, drain]);
      expect(drainCompleted, isTrue);

      await coordinator.ensureBootstrapped(
        uid: 'user-a',
        now: DateTime(2026, 9, 13),
        bootstrap: () async {
          calls += 1;
        },
      );
      expect(calls, 2);
    });

    test('reset comum não reabre admissões durante resetAndDrain', () async {
      final coordinator = NotificationBootstrapCoordinator();
      final releaseA = Completer<void>();
      var callsA = 0;
      var callsB = 0;
      var running = 0;
      var maxRunning = 0;

      Future<void> track(Future<void> Function() operation) async {
        running += 1;
        if (running > maxRunning) maxRunning = running;
        try {
          await operation();
        } finally {
          running -= 1;
        }
      }

      final bootstrapA = coordinator.ensureBootstrapped(
        uid: 'user-a',
        now: DateTime(2026, 9, 13),
        bootstrap: () => track(() async {
          callsA += 1;
          await releaseA.future;
        }),
      );
      final drain = coordinator.resetAndDrain();

      coordinator.reset();
      final blockedB = coordinator.ensureBootstrapped(
        uid: 'user-b',
        now: DateTime(2026, 9, 13),
        bootstrap: () => track(() async {
          callsB += 1;
        }),
      );

      expect(callsA, 1);
      expect(callsB, 0);

      releaseA.complete();
      await Future.wait([bootstrapA, drain, blockedB]);

      expect(callsB, 0);
      expect(maxRunning, 1);

      await coordinator.ensureBootstrapped(
        uid: 'user-b',
        now: DateTime(2026, 9, 13),
        bootstrap: () => track(() async {
          callsB += 1;
        }),
      );

      expect(callsB, 1);
      expect(maxRunning, 1);
    });

    test('resetAndDrain absorve falha operacional do job antigo', () async {
      final coordinator = NotificationBootstrapCoordinator();
      final bootstrap = coordinator.ensureBootstrapped(
        uid: 'user-a',
        now: DateTime(2026, 9, 13),
        bootstrap: () async => throw StateError('bootstrap failed'),
      );

      final drain = coordinator.resetAndDrain();

      await expectLater(bootstrap, throwsStateError);
      await expectLater(drain, completes);
    });

    test(
      'gate sobrevive ao autoDispose do engine e reset força novo bootstrap',
      () async {
        final auth = _FakeFirebaseAuth(_FakeUser('user-a'));
        repository = _TrackingNotificationsRepository(db, auth: auth);
        final container = ProviderContainer(
          overrides: [
            databaseProvider.overrideWithValue(db),
            notificationsRepositoryProvider.overrideWithValue(repository),
            notificationPreferencesStoreProvider.overrideWithValue(
              const _FakeNotificationPreferencesStore(),
            ),
          ],
        );

        try {
          final first = container.listen(
            notificationEngineProvider,
            (_, _) {},
            fireImmediately: true,
          );
          await container.pump();
          await container
              .read(notificationBootstrapCoordinatorProvider)
              .ensureBootstrapped(
                uid: 'user-a',
                now: DateTime.now(),
                bootstrap: () async => fail('bootstrap duplicado'),
              );
          expect(repository.syncCalls, 1);

          first.close();
          await container.pump();

          final second = container.listen(
            notificationEngineProvider,
            (_, _) {},
            fireImmediately: true,
          );
          await container.pump();
          expect(repository.watchCalls, 2);
          expect(repository.syncCalls, 1);

          second.close();
          await container.pump();
          container.read(notificationBootstrapCoordinatorProvider).reset();

          final third = container.listen(
            notificationEngineProvider,
            (_, _) {},
            fireImmediately: true,
          );
          await container.pump();
          await container
              .read(notificationBootstrapCoordinatorProvider)
              .ensureBootstrapped(
                uid: 'user-a',
                now: DateTime.now(),
                bootstrap: () async => fail('bootstrap duplicado'),
              );

          expect(repository.syncCalls, 2);
          third.close();
        } finally {
          container.dispose();
        }
      },
    );
  });

  setUp(() {
    db = AppDatabase(executor: NativeDatabase.memory());
    repository = _TrackingNotificationsRepository(db);
  });

  tearDown(() async {
    await db.closeDatabase();
  });

  Future<void> sync({
    NotificationPreferences preferences =
        const NotificationPreferences.enabled(),
  }) => reconciler.sync(
    repository: repository,
    db: db,
    preferences: preferences,
    today: today,
  );

  Future<NotificationModel?> notification(String id) =>
      repository.getLocalNotification(id);

  Future<void> insertSubject({
    required String id,
    bool hasExam = true,
    DateTime? examDate,
  }) async {
    await db
        .into(db.subjects)
        .insert(
          SubjectsCompanion.insert(
            id: id,
            title: 'Disciplina $id',
            cardsToReview: 0,
            streakDays: 0,
            progress: 0,
            hasExam: hasExam,
            examDate: Value(examDate?.millisecondsSinceEpoch),
          ),
        );
  }

  Future<void> insertMedication({
    required String id,
    required DateTime startDate,
    DateTime? endDate,
  }) async {
    await db
        .into(db.medications)
        .insert(
          MedicationsCompanion.insert(
            firestoreId: id,
            name: 'Medicamento de teste',
            startDate: startDate,
            endDate: Value(endDate),
          ),
        );
  }

  Future<void> insertHabit({
    required String id,
    List<String> completedDates = const [],
  }) async {
    await db
        .into(db.habits)
        .insert(
          HabitsCompanion.insert(
            id: id,
            title: 'Hábito $id',
            completedDates: jsonEncode(completedDates),
          ),
        );
  }

  Future<void> seedNotification({
    required String id,
    required DateTime dueDate,
    String priority = 'today',
    String moduleType = 'studies',
    bool isRead = false,
    bool isCompleted = false,
  }) async {
    await repository.saveLocalNotification(
      NotificationModel(
        id: id,
        title: 'Notificação de teste',
        description: 'Descrição de teste',
        priority: priority,
        moduleType: moduleType,
        route: '/test',
        isRead: isRead,
        isCompleted: isCompleted,
        dueDate: dueDate,
        createdAt: today,
      ),
    );
    repository.savedIds.clear();
  }

  test('prova hoje às 00:00 permanece válida durante todo o dia', () async {
    await insertSubject(id: 'today', examDate: todayStart);

    await sync();

    final result = await notification('exam_today');
    expect(result, isNotNull);
    expect(result!.dueDate, todayStart);
    expect(result.description, 'Sua prova é hoje. Prepare-se!');
  });

  test('prova amanhã gera notificação', () async {
    await insertSubject(id: 'tomorrow', examDate: tomorrow);

    await sync();

    final result = await notification('exam_tomorrow');
    expect(result, isNotNull);
    expect(result!.dueDate, tomorrow);
  });

  test('prova de ontem é removida local e remotamente', () async {
    final remoteDeletes = <String>[];
    repository = _TrackingNotificationsRepository(
      db,
      remoteDelete: (id) async => remoteDeletes.add(id),
    );
    await insertSubject(id: 'past', examDate: yesterday);
    await seedNotification(id: 'exam_past', dueDate: yesterday);

    await sync();

    expect(await notification('exam_past'), isNull);
    expect(repository.deletedIds, contains('exam_past'));
    expect(remoteDeletes, contains('exam_past'));
  });

  test('disciplina hasExam=false remove notificação órfã', () async {
    await insertSubject(id: 'disabled', hasExam: false);
    await seedNotification(id: 'exam_disabled', dueDate: tomorrow);

    await sync();

    expect(await notification('exam_disabled'), isNull);
  });

  test('disciplina com examDate nula remove notificação órfã', () async {
    await insertSubject(id: 'without-date');
    await seedNotification(id: 'exam_without-date', dueDate: tomorrow);

    await sync();

    expect(await notification('exam_without-date'), isNull);
  });

  test('mudança de data mantém ID e reseta leitura e conclusão', () async {
    await insertSubject(id: 'changed', examDate: tomorrow);
    await seedNotification(
      id: 'exam_changed',
      dueDate: todayStart,
      priority: 'completed',
      isRead: true,
      isCompleted: true,
    );

    await sync();

    final result = await notification('exam_changed');
    expect(result, isNotNull);
    expect(result!.id, 'exam_changed');
    expect(result.dueDate, tomorrow);
    expect(result.isRead, isFalse);
    expect(result.isCompleted, isFalse);
  });

  test('disciplina removida elimina exam órfão', () async {
    await seedNotification(id: 'exam_removed', dueDate: tomorrow);

    await sync();

    expect(await notification('exam_removed'), isNull);
  });

  test('medicamento iniciado e ativo gera notificação', () async {
    await insertMedication(id: 'active', startDate: yesterday);

    await sync();

    expect(await notification('health_med_active'), isNotNull);
  });

  test('medicamento com endDate hoje continua válido', () async {
    await insertMedication(
      id: 'ends-today',
      startDate: yesterday,
      endDate: todayStart,
    );

    await sync();

    final result = await notification('health_med_ends-today');
    expect(result, isNotNull);
    expect(result!.description, 'O tratamento termina hoje.');
  });

  test('medicamento encerrado ontem é removido', () async {
    await insertMedication(
      id: 'ended',
      startDate: DateTime(2026, 8, 20),
      endDate: yesterday,
    );
    await seedNotification(
      id: 'health_med_ended',
      dueDate: yesterday,
      moduleType: 'health',
    );

    await sync();

    expect(await notification('health_med_ended'), isNull);
  });

  test('medicamento removido elimina health_med órfã', () async {
    await seedNotification(
      id: 'health_med_removed',
      dueDate: tomorrow,
      moduleType: 'health',
    );

    await sync();

    expect(await notification('health_med_removed'), isNull);
  });

  test('hábito pendente usa priority today e isCompleted false', () async {
    await insertHabit(id: 'pending');

    await sync();

    final result = await notification('habit_pending');
    expect(result, isNotNull);
    expect(result!.priority, 'today');
    expect(result.isCompleted, isFalse);
  });

  test('hábito concluído hoje fica concluído e lido', () async {
    await insertHabit(id: 'done', completedDates: ['2026-08-25']);

    await sync();

    final result = await notification('habit_done');
    expect(result, isNotNull);
    expect(result!.priority, 'completed');
    expect(result.isCompleted, isTrue);
    expect(result.isRead, isTrue);
  });

  test('não produz priority completed com isCompleted false', () async {
    await insertHabit(id: 'coherent', completedDates: ['2026-08-25']);

    await sync();

    final notifications = await repository.getLocalNotifications();
    expect(
      notifications.where(
        (item) => item.priority == 'completed' && !item.isCompleted,
      ),
      isEmpty,
    );
  });

  test('virada de dia reutiliza ID e reseta a ocorrência diária', () async {
    await insertHabit(id: 'daily');
    await seedNotification(
      id: 'habit_daily',
      dueDate: yesterday,
      priority: 'completed',
      moduleType: 'habits',
      isRead: true,
      isCompleted: true,
    );

    await sync();

    final result = await notification('habit_daily');
    expect(result, isNotNull);
    expect(result!.dueDate, todayStart);
    expect(result.priority, 'today');
    expect(result.isRead, isFalse);
    expect(result.isCompleted, isFalse);
  });

  test('hábito removido elimina habit órfão', () async {
    await seedNotification(
      id: 'habit_removed',
      dueDate: todayStart,
      moduleType: 'habits',
    );

    await sync();

    expect(await notification('habit_removed'), isNull);
  });

  test('markAsRead persiste isRead true', () async {
    await seedNotification(id: 'exam_read', dueDate: tomorrow);

    await repository.markAsReadLocal('exam_read');

    expect((await notification('exam_read'))!.isRead, isTrue);
  });

  test('rebootstrap da mesma prova preserva isRead true', () async {
    await insertSubject(id: 'same', examDate: tomorrow);
    await sync();
    await repository.markAsReadLocal('exam_same');

    await sync();

    expect((await notification('exam_same'))!.isRead, isTrue);
  });

  test('markAsCompleted conclui somente a notificação', () async {
    await insertHabit(id: 'manual');
    await sync();

    await repository.markAsCompletedLocal('habit_manual');

    final result = await notification('habit_manual');
    final habit = await db.select(db.habits).getSingle();
    expect(result!.isRead, isTrue);
    expect(result.isCompleted, isTrue);
    expect(result.priority, 'today');
    expect(habit.completedDates, '[]');
  });

  test('conclusão manual de hábito sobrevive ao mesmo dia', () async {
    await insertHabit(id: 'manual-stable');
    await sync();
    await repository.markAsCompletedLocal('habit_manual-stable');

    await sync();

    final result = await notification('habit_manual-stable');
    expect(result!.priority, 'today');
    expect(result.isCompleted, isTrue);
  });

  test('desmarcar hábito real no mesmo dia restaura pendência', () async {
    await insertHabit(id: 'toggle', completedDates: ['2026-08-25']);
    await sync();
    await (db.update(db.habits)..where((table) => table.id.equals('toggle')))
        .write(HabitsCompanion(completedDates: Value(jsonEncode(<String>[]))));

    await sync();

    final result = await notification('habit_toggle');
    expect(result!.priority, 'today');
    expect(result.isRead, isFalse);
    expect(result.isCompleted, isFalse);
  });

  test('prefixo desconhecido não é apagado', () async {
    await seedNotification(
      id: 'custom_notification',
      dueDate: yesterday,
      moduleType: 'general',
    );

    await sync();

    expect(await notification('custom_notification'), isNotNull);
    expect(repository.deletedIds, isNot(contains('custom_notification')));
  });

  test('notificação futura de outro módulo não é apagada', () async {
    await seedNotification(
      id: 'focus_future',
      dueDate: DateTime(2026, 9),
      moduleType: 'focus',
    );

    await sync();

    expect(await notification('focus_future'), isNotNull);
  });

  test('chave geral desativada não gera nenhum módulo suportado', () async {
    await insertSubject(id: 'blocked', examDate: tomorrow);
    await insertMedication(id: 'blocked', startDate: yesterday);
    await insertHabit(id: 'blocked');

    await sync(
      preferences: const NotificationPreferences(
        allNotifications: false,
        studyReminders: true,
        habitReminders: true,
        medicationReminders: true,
      ),
    );

    expect(repository.savedIds, isEmpty);
    expect(await repository.getLocalNotifications(), isEmpty);
  });

  test(
    'chave geral remove derivados e preserva prefixo desconhecido',
    () async {
      await seedNotification(id: 'exam_existing', dueDate: tomorrow);
      await seedNotification(
        id: 'health_med_existing',
        dueDate: tomorrow,
        moduleType: 'health',
      );
      await seedNotification(
        id: 'habit_existing',
        dueDate: todayStart,
        moduleType: 'habits',
      );
      await seedNotification(
        id: 'custom_existing',
        dueDate: tomorrow,
        moduleType: 'general',
      );

      await sync(
        preferences: const NotificationPreferences(
          allNotifications: false,
          studyReminders: true,
          habitReminders: true,
          medicationReminders: true,
        ),
      );

      expect(await notification('exam_existing'), isNull);
      expect(await notification('health_med_existing'), isNull);
      expect(await notification('habit_existing'), isNull);
      expect(await notification('custom_existing'), isNotNull);
    },
  );

  test('estudos desativados removem somente exam', () async {
    await insertMedication(id: 'kept', startDate: yesterday);
    await insertHabit(id: 'kept');
    await seedNotification(id: 'exam_existing', dueDate: tomorrow);

    await sync(
      preferences: const NotificationPreferences(
        allNotifications: true,
        studyReminders: false,
        habitReminders: true,
        medicationReminders: true,
      ),
    );

    expect(await notification('exam_existing'), isNull);
    expect(await notification('health_med_kept'), isNotNull);
    expect(await notification('habit_kept'), isNotNull);
  });

  test('hábitos desativados removem somente habit', () async {
    await insertSubject(id: 'kept', examDate: tomorrow);
    await insertMedication(id: 'kept', startDate: yesterday);
    await seedNotification(
      id: 'habit_existing',
      dueDate: todayStart,
      moduleType: 'habits',
    );

    await sync(
      preferences: const NotificationPreferences(
        allNotifications: true,
        studyReminders: true,
        habitReminders: false,
        medicationReminders: true,
      ),
    );

    expect(await notification('habit_existing'), isNull);
    expect(await notification('exam_kept'), isNotNull);
    expect(await notification('health_med_kept'), isNotNull);
  });

  test('medicamentos desativados removem somente health_med', () async {
    await insertSubject(id: 'kept', examDate: tomorrow);
    await insertHabit(id: 'kept');
    await seedNotification(
      id: 'health_med_existing',
      dueDate: tomorrow,
      moduleType: 'health',
    );

    await sync(
      preferences: const NotificationPreferences(
        allNotifications: true,
        studyReminders: true,
        habitReminders: true,
        medicationReminders: false,
      ),
    );

    expect(await notification('health_med_existing'), isNull);
    expect(await notification('exam_kept'), isNotNull);
    expect(await notification('habit_kept'), isNotNull);
  });

  test('reabilitar categoria recria somente o evento ainda válido', () async {
    await insertSubject(id: 'current', examDate: tomorrow);
    const disabled = NotificationPreferences(
      allNotifications: true,
      studyReminders: false,
      habitReminders: true,
      medicationReminders: true,
    );

    await sync(preferences: disabled);
    expect(await notification('exam_current'), isNull);

    await sync();
    expect(await notification('exam_current'), isNotNull);
  });

  test(
    'preferências não reintroduzem ghost badge de hábito concluído',
    () async {
      await insertHabit(id: 'done-again', completedDates: ['2026-08-25']);
      const disabled = NotificationPreferences(
        allNotifications: true,
        studyReminders: true,
        habitReminders: false,
        medicationReminders: true,
      );

      await sync(preferences: disabled);
      await sync();

      final result = await notification('habit_done-again');
      expect(result, isNotNull);
      expect(result!.priority, 'completed');
      expect(result.isCompleted, isTrue);
      expect(result.isRead, isTrue);
    },
  );
}
