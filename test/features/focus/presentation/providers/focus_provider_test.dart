import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/features/focus/data/repositories/focus_repository.dart';
import 'package:life_os/features/focus/presentation/providers/providers/focus_provider.dart';
import 'package:life_os/features/study/data/study_repository.dart';
import 'package:life_os/features/study/presentation/providers/study_provider.dart';
import 'package:life_os/features/tasks/presentation/providers/tasks_provider.dart';

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
  late ProviderContainer container;
  late _ControlledPeriodicTimer timer;

  setUp(() {
    focusRepository = _FakeFocusRepository();
    tasksRepository = _FakeTasksRepository();
    studyRepository = _FakeStudyRepository();

    container = ProviderContainer(
      overrides: [
        focusRepositoryProvider.overrideWithValue(focusRepository),
        tasksRepositoryProvider.overrideWithValue(tasksRepository),
        studyRepositoryProvider.overrideWithValue(studyRepository),
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

  test('selecionar tarefa define targetType TASK', () {
    container
        .read(focusProvider.notifier)
        .selectTarget('task-1', 'Tarefa', FocusTargetType.task);

    final state = container.read(focusProvider);

    expect(state.activeTargetId, 'task-1');
    expect(state.activeTargetType, FocusTargetType.task);
    expect(state.activeTargetType?.value, 'TASK');
  });

  test('selecionar materia define targetType SUBJECT', () {
    container
        .read(focusProvider.notifier)
        .selectTarget('subject-1', 'Materia', FocusTargetType.subject);

    final state = container.read(focusProvider);

    expect(state.activeTargetId, 'subject-1');
    expect(state.activeTargetType, FocusTargetType.subject);
    expect(state.activeTargetType?.value, 'SUBJECT');
  });

  test('validateActiveTarget limpa target invalido', () {
    final notifier = container.read(focusProvider.notifier);

    notifier.selectTarget('task-1', 'Tarefa', FocusTargetType.task);
    notifier.validateActiveTarget(const ['task-2']);

    final state = container.read(focusProvider);

    expect(state.activeTargetId, isNull);
    expect(state.activeTargetTitle, isNull);
    expect(state.activeTargetType, isNull);
  });

  test('target nao pode ser trocado enquanto timer esta rodando', () {
    final notifier = container.read(focusProvider.notifier);

    notifier.selectTarget('task-1', 'Tarefa', FocusTargetType.task);
    notifier.startTimer();
    notifier.selectTarget('subject-1', 'Materia', FocusTargetType.subject);

    final state = container.read(focusProvider);

    expect(state.activeTargetId, 'task-1');
    expect(state.activeTargetTitle, 'Tarefa');
    expect(state.activeTargetType, FocusTargetType.task);
  });

  test(
    'conclusao simultanea processa efeitos pessoais uma unica vez',
    () async {
      final saveCompleter = Completer<void>();
      focusRepository.saveOperation = () => saveCompleter.future;

      final notifier = container.read(focusProvider.notifier);

      notifier.selectTarget('task-1', 'Tarefa', FocusTargetType.task);
      notifier.setCustomDuration(1);
      notifier.startTimer();

      for (var second = 0; second < 60; second++) {
        timer.fire();
      }

      timer.fire(force: true);

      expect(focusRepository.saveCalls, 1);
      expect(focusRepository.lastTargetId, 'task-1');
      expect(focusRepository.lastTargetType, 'TASK');
      expect(focusRepository.lastDurationSeconds, 60);

      saveCompleter.complete();
      await pumpEventQueue();

      expect(tasksRepository.toggleCalls, 1);
      expect(tasksRepository.lastTaskId, 'task-1');
      expect(tasksRepository.lastCurrentStatus, isFalse);
      expect(studyRepository.addStudyTimeCalls, 0);
      expect(container.read(focusProvider).isBreak, isTrue);
    },
  );

  test('conclusao SUBJECT adiciona tempo de estudo uma unica vez', () async {
    final notifier = container.read(focusProvider.notifier);

    notifier.selectTarget('subject-1', 'Materia', FocusTargetType.subject);
    notifier.setCustomDuration(1);
    notifier.startTimer();

    for (var second = 0; second < 60; second++) {
      timer.fire();
    }

    await pumpEventQueue();

    expect(focusRepository.saveCalls, 1);
    expect(focusRepository.lastTargetId, 'subject-1');
    expect(focusRepository.lastTargetType, 'SUBJECT');
    expect(focusRepository.lastDurationSeconds, 60);
    expect(studyRepository.addStudyTimeCalls, 1);
    expect(studyRepository.lastSubjectId, 'subject-1');
    expect(studyRepository.lastElapsedSeconds, 60);
    expect(tasksRepository.toggleCalls, 0);
    expect(container.read(focusProvider).isBreak, isTrue);
  });
}
