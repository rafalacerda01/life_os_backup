import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/app_database.dart' as local_db;
import 'package:life_os/features/dashboard/presentation/providers/dashboard_provider.dart';
import 'package:life_os/features/finance/presentation/providers/finance_provider.dart';
import 'package:life_os/features/health/data/models/health_model.dart';
import 'package:life_os/features/health/presentation/providers/health_provider.dart';
import 'package:life_os/features/study/data/models/study_model.dart';
import 'package:life_os/features/study/presentation/providers/study_provider.dart';
import 'package:life_os/features/tasks/data/models/task_model.dart';
import 'package:life_os/features/tasks/presentation/providers/tasks_provider.dart';

class _ReplayStreamController<T> {
  late final StreamController<T> _controller;
  T? _latest;
  bool _hasValue = false;

  _ReplayStreamController() {
    _controller = StreamController<T>.broadcast(
      sync: true,
      onListen: () {
        if (_hasValue) _controller.add(_latest as T);
      },
    );
  }

  Stream<T> get stream => _controller.stream;

  void add(T value) {
    _latest = value;
    _hasValue = true;
    _controller.add(value);
  }

  void addError(Object error) => _controller.addError(error);

  Future<void> close() => _controller.close();
}

class _DashboardHarness {
  final finance = _ReplayStreamController<List<local_db.Transaction>>();
  final study = _ReplayStreamController<StudyModel>();
  final health = _ReplayStreamController<HealthModel>();
  final tasks = _ReplayStreamController<List<TaskModel>>();
  late final ProviderContainer container;

  _DashboardHarness() {
    container = ProviderContainer(
      overrides: [
        financeStreamProvider.overrideWith((ref) => finance.stream),
        studyStreamProvider.overrideWith((ref) => study.stream),
        healthStreamProvider.overrideWith((ref) => health.stream),
        tasksStreamProvider.overrideWith((ref) => tasks.stream),
        medicationsStreamProvider.overrideWith((ref) => Stream.value([])),
      ],
    );
    container.listen(dashboardLoadStateProvider, (_, _) {});
    container.listen(dashboardStateProvider, (_, _) {});
  }

  Future<void> emitReady({
    List<local_db.Transaction> transactions = const [],
    StudyModel? studyData,
    HealthModel? healthData,
    List<TaskModel> taskList = const [],
    bool emitFinance = true,
    bool emitStudy = true,
    bool emitHealth = true,
    bool emitTasks = true,
  }) async {
    await settle();
    if (emitFinance) finance.add(transactions);
    if (emitStudy) {
      study.add(
        studyData ?? StudyModel(streak: 0, reviewQueue: 0, progress: 0),
      );
    }
    if (emitHealth) health.add(healthData ?? _health());
    if (emitTasks) tasks.add(taskList);
    await settle();
  }

  Future<void> settle() async {
    for (var index = 0; index < 6; index++) {
      await container.pump();
    }
  }

  Future<void> dispose() async {
    container.dispose();
    await Future.wait([
      finance.close(),
      study.close(),
      health.close(),
      tasks.close(),
    ]);
  }
}

HealthModel _health({String mood = '—', int water = 0}) => HealthModel(
  mood: mood,
  waterIntakeMl: water,
  hasTakenPillToday: false,
  date: DateTime(2026, 9, 5),
);

local_db.Transaction _transaction() => local_db.Transaction(
  id: 1,
  title: 'Receita',
  amount: 250,
  type: 'income',
  category: 'Teste',
  date: DateTime(2026, 9, 5),
  isDeleted: false,
);

TaskModel _task() => TaskModel(
  id: 'task-1',
  title: 'Tarefa',
  priority: 'medium',
  isCompleted: true,
  date: DateTime(2026, 9, 5),
);

void main() {
  group('dashboardLoadStateProvider', () {
    test('erro sem valor tem prioridade sobre loading sem valor', () {
      final error = AsyncError<int>(
        StateError('indisponível'),
        StackTrace.empty,
      );

      expect(
        classifyDashboardLoadState([const AsyncLoading<int>(), error]),
        DashboardLoadState.unavailable,
      );
    });

    test('todas as fontes carregadas ficam ready', () async {
      final harness = _DashboardHarness();
      addTearDown(harness.dispose);

      await harness.emitReady();

      expect(harness.container.read(financeStreamProvider).hasValue, isTrue);
      expect(harness.container.read(studyStreamProvider).hasValue, isTrue);
      expect(harness.container.read(healthStreamProvider).hasValue, isTrue);
      expect(harness.container.read(tasksStreamProvider).hasValue, isTrue);
      expect(
        harness.container.read(medicationsStreamProvider).hasValue,
        isTrue,
      );
      expect(
        harness.container.read(dashboardLoadStateProvider),
        DashboardLoadState.ready,
      );
    });

    for (final source in ['finance', 'tasks', 'health']) {
      test('$source em carregamento inicial mantém loading', () async {
        final harness = _DashboardHarness();
        addTearDown(harness.dispose);

        await harness.emitReady(
          emitFinance: source != 'finance',
          emitTasks: source != 'tasks',
          emitHealth: source != 'health',
        );

        expect(
          harness.container.read(dashboardLoadStateProvider),
          DashboardLoadState.loading,
        );
      });
    }

    test('finance com erro sem valor fica unavailable', () async {
      final harness = _DashboardHarness();
      addTearDown(harness.dispose);
      await harness.emitReady(emitFinance: false);

      harness.finance.addError(StateError('indisponível'));
      await harness.settle();

      expect(
        harness.container.read(dashboardLoadStateProvider),
        DashboardLoadState.unavailable,
      );
      expect(
        harness.container.read(dashboardStateProvider).transactionsCount,
        0,
      );
    });

    test('health com erro sem valor fica unavailable', () async {
      final harness = _DashboardHarness();
      addTearDown(harness.dispose);
      await harness.emitReady(emitHealth: false);

      harness.health.addError(StateError('indisponível'));
      await harness.settle();

      expect(
        harness.container.read(dashboardLoadStateProvider),
        DashboardLoadState.unavailable,
      );
    });

    test('refresh com valor anterior não volta para loading', () async {
      final harness = _DashboardHarness();
      addTearDown(harness.dispose);
      await harness.emitReady(transactions: [_transaction()]);

      harness.container.invalidate(financeStreamProvider);

      expect(harness.container.read(financeStreamProvider).hasValue, isTrue);
      expect(
        harness.container.read(dashboardLoadStateProvider),
        DashboardLoadState.ready,
      );
    });

    test('erro com valor anterior não fica unavailable', () async {
      final harness = _DashboardHarness();
      addTearDown(harness.dispose);
      await harness.emitReady(healthData: _health(mood: 'Focado'));

      harness.health.addError(StateError('falha de refresh'));
      await harness.settle();

      expect(harness.container.read(healthStreamProvider).hasValue, isTrue);
      expect(
        harness.container.read(dashboardLoadStateProvider),
        DashboardLoadState.ready,
      );
    });
  });

  group('dashboardStateProvider cache', () {
    test('preserva finanças durante refresh', () async {
      final harness = _DashboardHarness();
      addTearDown(harness.dispose);
      await harness.emitReady(transactions: [_transaction()]);
      expect(
        harness.container.read(dashboardStateProvider).financeBalance,
        250,
      );

      harness.container.invalidate(financeStreamProvider);

      expect(
        harness.container.read(dashboardStateProvider).financeBalance,
        250,
      );
      expect(
        harness.container.read(dashboardStateProvider).transactionsCount,
        1,
      );
    });

    test('preserva tarefas durante refresh', () async {
      final harness = _DashboardHarness();
      addTearDown(harness.dispose);
      await harness.emitReady(taskList: [_task()]);
      expect(
        harness.container.read(dashboardStateProvider).productivityScore,
        100,
      );

      harness.container.invalidate(tasksStreamProvider);

      expect(
        harness.container.read(dashboardStateProvider).productivityScore,
        100,
      );
      expect(
        harness.container.read(dashboardStateProvider).hasProductivityData,
        isTrue,
      );
    });

    test('preserva saúde durante refresh', () async {
      final harness = _DashboardHarness();
      addTearDown(harness.dispose);
      await harness.emitReady(healthData: _health(mood: 'Focado'));
      expect(harness.container.read(dashboardStateProvider).mood, 'Focado');

      harness.container.invalidate(healthStreamProvider);

      expect(harness.container.read(dashboardStateProvider).mood, 'Focado');
      expect(harness.container.read(dashboardStateProvider).healthScore, 80);
    });
  });
}
