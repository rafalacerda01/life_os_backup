import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/database_provider.dart';
import 'package:life_os/core/database/database_sync_policy.dart';
import 'package:life_os/core/database/local_database_identity.dart';
import 'package:life_os/core/database/local_mutation_gate.dart';
import 'package:life_os/core/runtime/app_runtime_mode.dart';
import 'package:life_os/core/services/firebase_auth_provider.dart';
import 'package:life_os/core/services/sync_manager_provider.dart';
import 'package:life_os/features/focus/data/repositories/focus_repository.dart';
import 'package:life_os/features/focus/presentation/providers/providers/focus_provider.dart';
import 'package:life_os/features/settings/presentation/providers/analytics_provider.dart';
import 'package:life_os/features/study/data/study_repository.dart';
import 'package:life_os/features/tasks/presentation/providers/tasks_provider.dart';

class ControlledTimer implements Timer {
  ControlledTimer(this.callback);

  final void Function(Timer) callback;
  @override
  bool isActive = true;
  @override
  int tick = 0;

  @override
  void cancel() => isActive = false;

  void fire(int value) {
    tick = value;
    callback(this);
  }
}

void main() {
  const uid = 'local-v1-123e4567-e89b-42d3-a456-426614174000';
  late AppDatabase db;
  late FocusRepository repository;
  late ProviderContainer container;
  late List<ControlledTimer> timers;
  late int remoteReads;

  setUp(() {
    db = AppDatabase.forUser(
      identity: LocalDatabaseIdentity(uid),
      executor: NativeDatabase.memory(),
      syncPolicy: DatabaseSyncPolicy.localOnly,
    );
    repository = FocusRepository.local(db);
    timers = [];
    remoteReads = 0;
    Never remote() {
      remoteReads++;
      throw StateError('REMOTE_PROVIDER_ACCESSED');
    }

    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appRuntimeModeProvider.overrideWithValue(AppRuntimeMode.localFirst),
        firebaseFirestoreProvider.overrideWith((ref) => remote()),
        firebaseAuthProvider.overrideWith((ref) => remote()),
        syncManagerProvider.overrideWith((ref) => remote()),
        focusRemoteDataSourceProvider.overrideWith((ref) => remote()),
        focusRemoteSendPermitProvider.overrideWith((ref) => remote()),
        analyticsServiceProvider.overrideWith((ref) => remote()),
        focusPeriodicTimerFactoryProvider.overrideWithValue((period, callback) {
          final timer = ControlledTimer(callback);
          timers.add(timer);
          return timer;
        }),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  Future<String> createTask() async {
    await container
        .read(tasksRepositoryProvider)
        .addTask('Alvo sintético', 'low');
    return (await db.select(db.taskTable).get()).single.id;
  }

  Future<FocusState> observe(bool Function(FocusState) predicate) async {
    final current = container.read(focusProvider);
    if (predicate(current)) return current;
    final result = Completer<FocusState>();
    final sub = container.listen(focusProvider, (_, state) {
      if (!result.isCompleted && predicate(state)) result.complete(state);
    });
    try {
      return await result.future.timeout(const Duration(seconds: 3));
    } finally {
      sub.close();
    }
  }

  test(
    'pause, resume and stale callbacks produce one local task completion',
    () async {
      final taskId = await createTask();
      final timer = container.read(focusProvider.notifier);
      timer.selectTarget(taskId, 'Alvo sintético', FocusTargetType.task);
      timer.setCustomDuration(1);
      timer.startTimer();
      final previous = timers.single;
      previous.fire(17);
      timer.pauseTimer();
      previous.fire(60);
      expect(container.read(focusProvider).durationRemaining, 43);
      timer.startTimer();
      previous.fire(61);
      expect(container.read(focusProvider).isRunning, true);
      expect(container.read(focusProvider).isVerified, false);
      timers.last.fire(43);
      timers.last.fire(44);
      await observe((state) => state.isBreak);
      final log = (await db.select(db.focusLogs).get()).single;
      expect(
        (log.targetId, log.targetType, log.durationSeconds),
        (taskId, 'TASK', 60),
      );
      expect((await db.select(db.taskTable).get()).single.isCompleted, true);
      expect(await db.select(db.syncQueueTable).get(), isEmpty);
      expect(remoteReads, 0);
    },
  );

  test(
    'subject cycle commits log and study progress on the same connection',
    () async {
      await StudyRepository.local(db).createSubject('Disciplina sintética');
      final subject = (await db.select(db.subjects).get()).single;
      await repository.saveFocusSession(subject.id, 'SUBJECT', 60);
      expect((await db.select(db.focusLogs).get()).single.targetId, subject.id);
      expect(
        (await db.select(db.subjects).get()).single.progress,
        closeTo(.05, .000001),
      );
      expect(
        (await db.select(db.studyStats).get()).single.progress,
        closeTo(.05, .000001),
      );
      await repository.syncFocusFromFirebaseToLocal();
      expect(await db.select(db.syncQueueTable).get(), isEmpty);
    },
  );

  test(
    'a deleted target rolls back the log and leaves an explicit retry state',
    () async {
      final taskId = await createTask();
      final timer = container.read(focusProvider.notifier);
      timer.selectTarget(taskId, 'Alvo sintético', FocusTargetType.task);
      timer.setCustomDuration(1);
      timer.startTimer();
      await container.read(tasksRepositoryProvider).deleteTask(taskId);
      timers.single.fire(60);
      await observe((state) => state.saveFailed);
      expect(container.read(focusProvider).isBreak, false);
      expect(await db.select(db.focusLogs).get(), isEmpty);
      timer.startTimer();
      expect(timers, hasLength(1));
      await expectLater(
        repository.saveFocusSession('missing', 'SUBJECT', 60),
        throwsArgumentError,
      );
      expect(await db.select(db.focusLogs).get(), isEmpty);
      expect(await db.select(db.studyStats).get(), isEmpty);
      expect(remoteReads, 0);
    },
  );

  test(
    'a ticket captured before detach cannot write after re-admission',
    () async {
      final taskId = await createTask();
      String? current = uid;
      db.localMutations.bindSessionReader(() => current);
      db.localMutations.openPreparedSession();
      final old = db.localMutations.capture(expectedUid: uid);
      current = null;
      db.localMutations.observeSession(null);
      current = uid;
      db.localMutations.openPreparedSession();
      await expectLater(
        repository.completeLocalFocusSession(
          targetId: taskId,
          targetType: 'TASK',
          durationSeconds: 60,
          admission: old,
        ),
        throwsA(isA<LocalMutationUnavailable>()),
      );
      expect(await db.select(db.focusLogs).get(), isEmpty);
      expect((await db.select(db.taskTable).get()).single.isCompleted, false);
    },
  );

  test(
    'reset rejects a late callback and breaks never create focus logs',
    () async {
      final taskId = await createTask();
      final notifier = container.read(focusProvider.notifier);
      notifier.selectTarget(taskId, 'Alvo sintético', FocusTargetType.task);
      notifier.setCustomDuration(1);
      notifier.startTimer();
      notifier.resetTimer();
      timers.single.fire(60);
      notifier.toggleSessionType();
      notifier.startTimer();
      timers.last.fire(300);
      expect(container.read(focusProvider).isBreak, false);
      expect(await db.select(db.focusLogs).get(), isEmpty);
      expect(remoteReads, 0);
    },
  );
}
