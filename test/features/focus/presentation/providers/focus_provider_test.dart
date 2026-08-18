import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/features/focus/data/remote/focus_remote_data_source.dart';
import 'package:life_os/features/focus/data/repositories/focus_repository.dart';
import 'package:life_os/features/focus/presentation/providers/providers/focus_provider.dart';
import 'package:life_os/features/study/data/study_repository.dart';
import 'package:life_os/features/study/presentation/providers/study_provider.dart';
import 'package:life_os/features/tasks/presentation/providers/tasks_provider.dart';

typedef _StartOperation =
    Future<FocusStartResponse> Function({
      required String targetId,
      required FocusRemoteTargetType targetType,
      required int plannedDurationSeconds,
    });
typedef _SessionOperation =
    Future<Object> Function({required String sessionId});

class _FakeFocusRepository implements FocusRepository {
  int saveCalls = 0;
  String? lastTargetId;
  String? lastTargetType;
  int? lastDurationSeconds;
  Future<void> Function()? saveOperation;

  @override
  Future<void> saveFocusSession(
    String targetId,
    String targetType,
    int durationSeconds,
  ) {
    saveCalls++;
    lastTargetId = targetId;
    lastTargetType = targetType;
    lastDurationSeconds = durationSeconds;
    return saveOperation?.call() ?? Future<void>.value();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeTasksRepository implements TasksRepository {
  int toggleCalls = 0;
  String? lastTaskId;
  bool? lastCurrentStatus;

  @override
  Future<void> toggleTaskStatus(String taskId, bool currentStatus) async {
    toggleCalls++;
    lastTaskId = taskId;
    lastCurrentStatus = currentStatus;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeStudyRepository implements StudyRepository {
  int addStudyTimeCalls = 0;
  String? lastSubjectId;
  int? lastElapsedSeconds;

  @override
  Future<void> addStudyTime(String subjectId, int elapsedSeconds) async {
    addStudyTimeCalls++;
    lastSubjectId = subjectId;
    lastElapsedSeconds = elapsedSeconds;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeFocusRemoteDataSource implements FocusRemoteDataSource {
  int startCalls = 0;
  int finishCalls = 0;
  int cancelCalls = 0;
  int closeCalls = 0;
  String? lastTargetId;
  FocusRemoteTargetType? lastTargetType;
  int? lastPlannedDurationSeconds;
  final List<String> startedSessionIds = [];
  final List<String> finishedSessionIds = [];
  final List<String> cancelledSessionIds = [];
  final Map<String, int> _plannedDurations = {};
  _StartOperation? startOperation;
  _SessionOperation? finishOperation;
  _SessionOperation? cancelOperation;

  @override
  Future<FocusStartResponse> startFocus({
    required String targetId,
    required FocusRemoteTargetType targetType,
    required int plannedDurationSeconds,
  }) async {
    startCalls++;
    lastTargetId = targetId;
    lastTargetType = targetType;
    lastPlannedDurationSeconds = plannedDurationSeconds;

    final operation = startOperation;
    final response = operation == null
        ? FocusStartResponse(
            sessionId: 'verified-$startCalls',
            plannedDurationSeconds: plannedDurationSeconds,
            startedAt: DateTime.utc(2026, 8, 17, 12),
            expiresAt: DateTime.utc(2026, 8, 17, 13),
            reused: false,
          )
        : await operation(
            targetId: targetId,
            targetType: targetType,
            plannedDurationSeconds: plannedDurationSeconds,
          );

    startedSessionIds.add(response.sessionId);
    _plannedDurations[response.sessionId] = plannedDurationSeconds;
    return response;
  }

  @override
  Future<FocusFinishResponse> finishFocus({required String sessionId}) async {
    finishCalls++;
    finishedSessionIds.add(sessionId);

    final operation = finishOperation;
    if (operation != null) {
      return await operation(sessionId: sessionId) as FocusFinishResponse;
    }

    return FocusFinishResponse(
      sessionId: sessionId,
      verifiedDurationSeconds: _plannedDurations[sessionId] ?? 1500,
      completedAt: DateTime.utc(2026, 8, 17, 13),
      replayed: false,
    );
  }

  @override
  Future<FocusCancelResponse> cancelFocus({required String sessionId}) async {
    cancelCalls++;
    cancelledSessionIds.add(sessionId);

    final operation = cancelOperation;
    if (operation != null) {
      return await operation(sessionId: sessionId) as FocusCancelResponse;
    }

    return FocusCancelResponse(
      sessionId: sessionId,
      cancelledAt: DateTime.utc(2026, 8, 17, 12, 30),
      replayed: false,
    );
  }

  @override
  void close() {
    closeCalls++;
  }
}

class _ControlledPeriodicTimer implements Timer {
  _ControlledPeriodicTimer(this._callback);

  final void Function(Timer timer) _callback;

  bool _isActive = true;
  int _tick = 0;

  void fire({bool force = false}) {
    if (!_isActive && !force) return;

    _tick++;
    _callback(this);
  }

  @override
  bool get isActive => _isActive;

  @override
  int get tick => _tick;

  @override
  void cancel() {
    _isActive = false;
  }
}

void main() {
  late _FakeFocusRepository focusRepository;
  late _FakeTasksRepository tasksRepository;
  late _FakeStudyRepository studyRepository;
  late _FakeFocusRemoteDataSource remoteDataSource;
  late ProviderContainer container;
  late _ControlledPeriodicTimer timer;

  setUp(() {
    focusRepository = _FakeFocusRepository();
    tasksRepository = _FakeTasksRepository();
    studyRepository = _FakeStudyRepository();
    remoteDataSource = _FakeFocusRemoteDataSource();

    container = ProviderContainer(
      overrides: [
        focusRepositoryProvider.overrideWithValue(focusRepository),
        tasksRepositoryProvider.overrideWithValue(tasksRepository),
        studyRepositoryProvider.overrideWithValue(studyRepository),
        focusRemoteDataSourceProvider.overrideWithValue(remoteDataSource),
        focusPeriodicTimerFactoryProvider.overrideWithValue((
          duration,
          callback,
        ) {
          timer = _ControlledPeriodicTimer(callback);
          return timer;
        }),
      ],
    );

    addTearDown(container.dispose);
  });

  void configureTarget(
    FocusNotifier notifier,
    FocusTargetType targetType, {
    int minutes = 1,
  }) {
    final id = targetType == FocusTargetType.task ? 'task-1' : 'subject-1';
    notifier.selectTarget(id, 'Target', targetType);
    notifier.setCustomDuration(minutes);
  }

  Future<void> startAndFlush(FocusNotifier notifier) async {
    notifier.startTimer();
    await pumpEventQueue();
  }

  void finishCurrentTimer(int seconds) {
    for (var second = 0; second < seconds; second++) {
      timer.fire();
    }
  }

  test('selecting a task defines TASK target type', () {
    container
        .read(focusProvider.notifier)
        .selectTarget('task-1', 'Task', FocusTargetType.task);

    final state = container.read(focusProvider);

    expect(state.activeTargetId, 'task-1');
    expect(state.activeTargetType, FocusTargetType.task);
    expect(state.activeTargetType?.value, 'TASK');
  });

  test('selecting a subject defines SUBJECT target type', () {
    container
        .read(focusProvider.notifier)
        .selectTarget('subject-1', 'Subject', FocusTargetType.subject);

    final state = container.read(focusProvider);

    expect(state.activeTargetId, 'subject-1');
    expect(state.activeTargetType, FocusTargetType.subject);
    expect(state.activeTargetType?.value, 'SUBJECT');
  });

  test('validateActiveTarget clears an invalid target', () {
    final notifier = container.read(focusProvider.notifier);

    notifier.selectTarget('task-1', 'Task', FocusTargetType.task);
    notifier.validateActiveTarget(const ['task-2']);

    final state = container.read(focusProvider);

    expect(state.activeTargetId, isNull);
    expect(state.activeTargetTitle, isNull);
    expect(state.activeTargetType, isNull);
  });

  test('target cannot change while verified start is pending', () async {
    final startCompleter = Completer<FocusStartResponse>();
    remoteDataSource.startOperation =
        ({
          required targetId,
          required targetType,
          required plannedDurationSeconds,
        }) => startCompleter.future;
    final notifier = container.read(focusProvider.notifier);
    configureTarget(notifier, FocusTargetType.task);

    notifier.startTimer();
    notifier.selectTarget('subject-1', 'Subject', FocusTargetType.subject);

    expect(container.read(focusProvider).activeTargetId, 'task-1');

    startCompleter.complete(
      FocusStartResponse(
        sessionId: 'pending-session',
        plannedDurationSeconds: 60,
        startedAt: DateTime.utc(2026, 8, 17, 12),
        expiresAt: DateTime.utc(2026, 8, 17, 13),
        reused: false,
      ),
    );
    await pumpEventQueue();

    expect(container.read(focusProvider).isRunning, isTrue);
  });

  test('TASK full session starts and finishes verified exactly once', () async {
    final notifier = container.read(focusProvider.notifier);
    configureTarget(notifier, FocusTargetType.task);

    await startAndFlush(notifier);
    finishCurrentTimer(60);
    await pumpEventQueue();

    expect(remoteDataSource.startCalls, 1);
    expect(remoteDataSource.lastTargetId, 'task-1');
    expect(remoteDataSource.lastTargetType, FocusRemoteTargetType.task);
    expect(remoteDataSource.lastPlannedDurationSeconds, 60);
    expect(remoteDataSource.finishCalls, 1);
    expect(remoteDataSource.finishedSessionIds, ['verified-1']);
    expect(focusRepository.saveCalls, 1);
    expect(focusRepository.lastTargetId, 'task-1');
    expect(focusRepository.lastTargetType, 'TASK');
    expect(focusRepository.lastDurationSeconds, 60);
    expect(tasksRepository.toggleCalls, 1);
    expect(studyRepository.addStudyTimeCalls, 0);
    expect(container.read(focusProvider).isBreak, isTrue);
  });

  test('SUBJECT full session finishes verified and adds study time', () async {
    final notifier = container.read(focusProvider.notifier);
    configureTarget(notifier, FocusTargetType.subject);

    await startAndFlush(notifier);
    finishCurrentTimer(60);
    await pumpEventQueue();

    expect(remoteDataSource.startCalls, 1);
    expect(remoteDataSource.lastTargetType, FocusRemoteTargetType.subject);
    expect(remoteDataSource.finishCalls, 1);
    expect(focusRepository.saveCalls, 1);
    expect(focusRepository.lastTargetId, 'subject-1');
    expect(focusRepository.lastTargetType, 'SUBJECT');
    expect(studyRepository.addStudyTimeCalls, 1);
    expect(studyRepository.lastSubjectId, 'subject-1');
    expect(studyRepository.lastElapsedSeconds, 60);
    expect(tasksRepository.toggleCalls, 0);
    expect(container.read(focusProvider).isBreak, isTrue);
  });

  test('start failure keeps the personal session local-only', () async {
    remoteDataSource.startOperation =
        ({
          required targetId,
          required targetType,
          required plannedDurationSeconds,
        }) async => throw StateError('offline');
    final notifier = container.read(focusProvider.notifier);
    configureTarget(notifier, FocusTargetType.task);

    await startAndFlush(notifier);

    expect(container.read(focusProvider).isRunning, isTrue);

    finishCurrentTimer(60);
    await pumpEventQueue();

    expect(remoteDataSource.startCalls, 1);
    expect(remoteDataSource.finishCalls, 0);
    expect(focusRepository.saveCalls, 1);
    expect(tasksRepository.toggleCalls, 1);
    expect(container.read(focusProvider).isBreak, isTrue);
  });

  test('pause cancels a verified session and invalidates it', () async {
    final notifier = container.read(focusProvider.notifier);
    configureTarget(notifier, FocusTargetType.task);
    await startAndFlush(notifier);

    notifier.pauseTimer();
    await pumpEventQueue();

    expect(container.read(focusProvider).isRunning, isFalse);
    expect(remoteDataSource.cancelCalls, 1);
    expect(remoteDataSource.cancelledSessionIds, ['verified-1']);
    expect(remoteDataSource.finishCalls, 0);
  });

  test('resume after pause does not create another verified start', () async {
    final notifier = container.read(focusProvider.notifier);
    configureTarget(notifier, FocusTargetType.task);
    await startAndFlush(notifier);

    timer.fire();
    notifier.pauseTimer();
    await pumpEventQueue();
    notifier.startTimer();

    expect(container.read(focusProvider).isRunning, isTrue);
    expect(remoteDataSource.startCalls, 1);

    finishCurrentTimer(59);
    await pumpEventQueue();

    expect(remoteDataSource.finishCalls, 0);
    expect(focusRepository.saveCalls, 1);
    expect(tasksRepository.toggleCalls, 1);
  });

  test(
    'reset cancels verified session and next full start verifies again',
    () async {
      final notifier = container.read(focusProvider.notifier);
      configureTarget(notifier, FocusTargetType.task);
      await startAndFlush(notifier);

      notifier.resetTimer();
      await pumpEventQueue();

      expect(remoteDataSource.cancelCalls, 1);
      expect(container.read(focusProvider).durationRemaining, 60);
      expect(container.read(focusProvider).isRunning, isFalse);

      await startAndFlush(notifier);

      expect(remoteDataSource.startCalls, 2);
      expect(container.read(focusProvider).isRunning, isTrue);
    },
  );

  test('new start waits for pending reset cancel before starting', () async {
    final notifier = container.read(focusProvider.notifier);
    configureTarget(notifier, FocusTargetType.task);
    await startAndFlush(notifier);

    final cancelCompleter = Completer<FocusCancelResponse>();
    remoteDataSource.cancelOperation = ({required sessionId}) =>
        cancelCompleter.future;

    notifier.resetTimer();
    notifier.startTimer();

    expect(remoteDataSource.cancelCalls, 1);
    expect(remoteDataSource.startCalls, 1);
    expect(container.read(focusProvider).isRunning, isFalse);

    cancelCompleter.complete(
      FocusCancelResponse(
        sessionId: 'verified-1',
        cancelledAt: DateTime.utc(2026, 8, 17, 12, 30),
        replayed: false,
      ),
    );
    await pumpEventQueue();

    expect(remoteDataSource.startCalls, 2);
    expect(remoteDataSource.startedSessionIds, ['verified-1', 'verified-2']);
    expect(container.read(focusProvider).isRunning, isTrue);
  });

  test('failed pending reset cancel makes next cycle local-only', () async {
    final notifier = container.read(focusProvider.notifier);
    configureTarget(notifier, FocusTargetType.task);
    await startAndFlush(notifier);

    final cancelCompleter = Completer<FocusCancelResponse>();
    remoteDataSource.cancelOperation = ({required sessionId}) =>
        cancelCompleter.future;

    notifier.resetTimer();
    notifier.startTimer();

    expect(remoteDataSource.startCalls, 1);
    expect(container.read(focusProvider).isRunning, isFalse);

    cancelCompleter.completeError(StateError('cancel unavailable'));
    await pumpEventQueue();

    expect(remoteDataSource.startCalls, 1);
    expect(remoteDataSource.startedSessionIds, ['verified-1']);
    expect(container.read(focusProvider).isRunning, isTrue);

    finishCurrentTimer(60);
    await pumpEventQueue();

    expect(remoteDataSource.finishCalls, 0);
    expect(remoteDataSource.finishedSessionIds, isEmpty);
    expect(focusRepository.saveCalls, 1);
    expect(tasksRepository.toggleCalls, 1);
    expect(container.read(focusProvider).isBreak, isTrue);
  });

  test(
    'failed cancel remains pending across local cycle until retry succeeds',
    () async {
      final notifier = container.read(focusProvider.notifier);
      configureTarget(notifier, FocusTargetType.task);
      await startAndFlush(notifier);

      final firstCancel = Completer<FocusCancelResponse>();
      remoteDataSource.cancelOperation = ({required sessionId}) =>
          firstCancel.future;

      notifier.resetTimer();
      notifier.startTimer();
      firstCancel.completeError(StateError('cancel unavailable'));
      await pumpEventQueue();

      expect(remoteDataSource.startCalls, 1);
      expect(container.read(focusProvider).isRunning, isTrue);

      finishCurrentTimer(60);
      await pumpEventQueue();
      expect(container.read(focusProvider).isBreak, isTrue);

      notifier.toggleSessionType();
      final retryCancel = Completer<FocusCancelResponse>();
      remoteDataSource.cancelOperation = ({required sessionId}) =>
          retryCancel.future;

      notifier.startTimer();

      expect(remoteDataSource.cancelCalls, 2);
      expect(remoteDataSource.startCalls, 1);
      expect(container.read(focusProvider).isRunning, isFalse);

      retryCancel.complete(
        FocusCancelResponse(
          sessionId: 'verified-1',
          cancelledAt: DateTime.utc(2026, 8, 17, 13),
          replayed: false,
        ),
      );
      await pumpEventQueue();

      expect(remoteDataSource.startCalls, 2);
      expect(remoteDataSource.startedSessionIds, ['verified-1', 'verified-2']);
      expect(container.read(focusProvider).isRunning, isTrue);
    },
  );

  test('FOCUS_SESSION_EXPIRED clears pending invalidation', () async {
    final notifier = container.read(focusProvider.notifier);
    configureTarget(notifier, FocusTargetType.task);
    await startAndFlush(notifier);

    remoteDataSource.cancelOperation = ({required sessionId}) async =>
        throw StateError('cancel unavailable');

    notifier.resetTimer();
    notifier.startTimer();
    await pumpEventQueue();

    expect(remoteDataSource.startCalls, 1);
    expect(container.read(focusProvider).isRunning, isTrue);

    finishCurrentTimer(60);
    await pumpEventQueue();
    notifier.toggleSessionType();

    remoteDataSource.cancelOperation = ({required sessionId}) async =>
        throw const FocusRemoteException(
          statusCode: 409,
          code: 'FOCUS_SESSION_EXPIRED',
          message: 'Session expired.',
          isRetryable: false,
        );

    await startAndFlush(notifier);

    expect(remoteDataSource.cancelCalls, 2);
    expect(remoteDataSource.startCalls, 2);
    expect(remoteDataSource.startedSessionIds, ['verified-1', 'verified-2']);
    expect(container.read(focusProvider).isRunning, isTrue);
  });

  test('BREAK performs no remote Focus operation', () async {
    final notifier = container.read(focusProvider.notifier);
    notifier.toggleSessionType();

    notifier.startTimer();
    finishCurrentTimer(300);
    await pumpEventQueue();

    expect(remoteDataSource.startCalls, 0);
    expect(remoteDataSource.finishCalls, 0);
    expect(remoteDataSource.cancelCalls, 0);
    expect(focusRepository.saveCalls, 0);
    expect(container.read(focusProvider).isBreak, isFalse);
  });

  test('finish failure does not block personal effects or break', () async {
    remoteDataSource.finishOperation = ({required sessionId}) async =>
        throw StateError('backend unavailable');
    final notifier = container.read(focusProvider.notifier);
    configureTarget(notifier, FocusTargetType.task);
    await startAndFlush(notifier);

    finishCurrentTimer(60);
    await pumpEventQueue();

    expect(remoteDataSource.finishCalls, 1);
    expect(focusRepository.saveCalls, 1);
    expect(tasksRepository.toggleCalls, 1);
    expect(container.read(focusProvider).isBreak, isTrue);
  });

  test('duplicate timer callback does not duplicate any effects', () async {
    final saveCompleter = Completer<void>();
    focusRepository.saveOperation = () => saveCompleter.future;
    final notifier = container.read(focusProvider.notifier);
    configureTarget(notifier, FocusTargetType.task);
    await startAndFlush(notifier);

    finishCurrentTimer(60);
    timer.fire(force: true);

    expect(remoteDataSource.finishCalls, 1);
    expect(focusRepository.saveCalls, 1);

    saveCompleter.complete();
    await pumpEventQueue();

    expect(remoteDataSource.startCalls, 1);
    expect(remoteDataSource.finishCalls, 1);
    expect(tasksRepository.toggleCalls, 1);
    expect(studyRepository.addStudyTimeCalls, 0);
  });

  test(
    'failed stale cancel remains pending before a future verified start',
    () async {
      final startCompleter = Completer<FocusStartResponse>();
      remoteDataSource.startOperation =
          ({
            required targetId,
            required targetType,
            required plannedDurationSeconds,
          }) => startCompleter.future;
      remoteDataSource.cancelOperation = ({required sessionId}) async =>
          throw StateError('cancel unavailable');
      final notifier = container.read(focusProvider.notifier);
      configureTarget(notifier, FocusTargetType.task);

      notifier.startTimer();
      notifier.resetTimer();
      startCompleter.complete(
        FocusStartResponse(
          sessionId: 'stale-session',
          plannedDurationSeconds: 60,
          startedAt: DateTime.utc(2026, 8, 17, 12),
          expiresAt: DateTime.utc(2026, 8, 17, 13),
          reused: false,
        ),
      );
      await pumpEventQueue();

      expect(container.read(focusProvider).isRunning, isFalse);
      expect(remoteDataSource.startCalls, 1);
      expect(remoteDataSource.cancelCalls, 1);
      expect(remoteDataSource.cancelledSessionIds, ['stale-session']);

      final retryCancel = Completer<FocusCancelResponse>();
      remoteDataSource.cancelOperation = ({required sessionId}) =>
          retryCancel.future;
      remoteDataSource.startOperation = null;
      notifier.startTimer();

      expect(remoteDataSource.cancelCalls, 2);
      expect(remoteDataSource.startCalls, 1);
      expect(container.read(focusProvider).isRunning, isFalse);

      retryCancel.complete(
        FocusCancelResponse(
          sessionId: 'stale-session',
          cancelledAt: DateTime.utc(2026, 8, 17, 13),
          replayed: false,
        ),
      );
      await pumpEventQueue();

      expect(remoteDataSource.startCalls, 2);
      expect(remoteDataSource.startedSessionIds, [
        'stale-session',
        'verified-2',
      ]);
      expect(container.read(focusProvider).isRunning, isTrue);
    },
  );

  test('double tap while start is pending performs one start only', () async {
    final startCompleter = Completer<FocusStartResponse>();
    remoteDataSource.startOperation =
        ({
          required targetId,
          required targetType,
          required plannedDurationSeconds,
        }) => startCompleter.future;
    final notifier = container.read(focusProvider.notifier);
    configureTarget(notifier, FocusTargetType.task);

    notifier.startTimer();
    notifier.startTimer();

    expect(remoteDataSource.startCalls, 1);

    notifier.resetTimer();
    startCompleter.complete(
      FocusStartResponse(
        sessionId: 'single-flight-session',
        plannedDurationSeconds: 60,
        startedAt: DateTime.utc(2026, 8, 17, 12),
        expiresAt: DateTime.utc(2026, 8, 17, 13),
        reused: false,
      ),
    );
    await pumpEventQueue();
  });

  test('unsupported personal duration runs local-only', () async {
    final notifier = container.read(focusProvider.notifier);
    configureTarget(notifier, FocusTargetType.task, minutes: 2);

    notifier.startTimer();

    expect(container.read(focusProvider).isRunning, isTrue);
    expect(remoteDataSource.startCalls, 0);

    finishCurrentTimer(120);
    await pumpEventQueue();

    expect(remoteDataSource.finishCalls, 0);
    expect(focusRepository.saveCalls, 1);
    expect(tasksRepository.toggleCalls, 1);
  });
}
