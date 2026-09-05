import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/features/dashboard/data/models/dashboard_model.dart';
import 'package:life_os/features/dashboard/presentation/providers/dashboard_provider.dart';
import 'package:life_os/features/habits/data/models/habit_model.dart';
import 'package:life_os/features/habits/presentation/providers/habits_provider.dart';
import 'package:life_os/features/health/presentation/providers/health_provider.dart';
import 'package:life_os/features/home/presentation/providers/home_provider.dart';
import 'package:life_os/features/study/domain/entities/study_subject_entity.dart';
import 'package:life_os/features/study/presentation/providers/study_provider.dart';

const _dashboard = DashboardModel(
  productivityScore: 85,
  healthScore: 90,
  financialScore: 75,
  studyStreak: 5,
  studyReviewQueue: 2,
  studyProgress: 0.6,
  activeMedications: 1,
  transactionsCount: 10,
  financeBalance: 1500,
);

class _HomeHarness {
  final habits = StreamController<List<HabitModel>>.broadcast(sync: true);
  final medications = StreamController<List<Medication>>.broadcast(sync: true);
  final subjects = StreamController<List<StudySubjectEntity>>.broadcast(
    sync: true,
  );
  late final ProviderContainer container;

  _HomeHarness({
    DashboardLoadState dashboardLoadState = DashboardLoadState.ready,
  }) {
    container = ProviderContainer(
      overrides: [
        dashboardStateProvider.overrideWith((ref) => _dashboard),
        dashboardLoadStateProvider.overrideWith((ref) => dashboardLoadState),
        habitsStreamProvider.overrideWith((ref) => habits.stream),
        medicationsStreamProvider.overrideWith((ref) => medications.stream),
        subjectsStreamProvider.overrideWith((ref) => subjects.stream),
      ],
    );
    container.listen(homeStateProvider, (_, _) {});
  }

  Future<void> emitReady({
    List<HabitModel> habitList = const [],
    List<Medication> medicationList = const [],
    List<StudySubjectEntity> subjectList = const [],
    bool emitHabits = true,
    bool emitMedications = true,
    bool emitSubjects = true,
  }) async {
    await settle();
    if (emitHabits) habits.add(habitList);
    if (emitMedications) medications.add(medicationList);
    if (emitSubjects) subjects.add(subjectList);
    await settle();
  }

  Future<void> settle() async {
    for (var index = 0; index < 4; index++) {
      await container.pump();
    }
  }

  Future<void> dispose() async {
    container.dispose();
    await Future.wait([habits.close(), medications.close(), subjects.close()]);
  }
}

HabitModel _habit(String id) =>
    HabitModel(id: id, title: 'Hábito $id', completedDates: const []);

StudySubjectEntity _subject(String id) => StudySubjectEntity(
  id: id,
  title: 'Matéria $id',
  cardsToReview: 0,
  streakDays: 0,
  progress: 0,
  hasExam: true,
  examDate: DateTime.now().add(const Duration(days: 5)),
);

void main() {
  group('homeStateProvider load state', () {
    test('erro sem valor tem prioridade sobre dashboard loading', () {
      final error = AsyncError<int>(
        StateError('indisponível'),
        StackTrace.empty,
      );

      expect(
        classifyHomeLoadState(DashboardLoadState.loading, [error]),
        HomeLoadState.unavailable,
      );
    });

    test('dashboard loading mantém Home em loading', () async {
      final harness = _HomeHarness(
        dashboardLoadState: DashboardLoadState.loading,
      );
      addTearDown(harness.dispose);
      await harness.emitReady();

      expect(
        harness.container.read(homeStateProvider).loadState,
        HomeLoadState.loading,
      );
    });

    test('hábitos em carregamento inicial mantêm Home em loading', () async {
      final harness = _HomeHarness();
      addTearDown(harness.dispose);
      await harness.emitReady(emitHabits: false);

      expect(
        harness.container.read(homeStateProvider).loadState,
        HomeLoadState.loading,
      );
    });

    test('matérias em carregamento inicial mantêm Home em loading', () async {
      final harness = _HomeHarness();
      addTearDown(harness.dispose);
      await harness.emitReady(emitSubjects: false);

      expect(
        harness.container.read(homeStateProvider).loadState,
        HomeLoadState.loading,
      );
    });

    test('erro sem cache deixa Home unavailable', () async {
      final harness = _HomeHarness();
      addTearDown(harness.dispose);
      await harness.emitReady(emitHabits: false);
      harness.habits.addError(StateError('indisponível'));
      await harness.settle();

      final state = harness.container.read(homeStateProvider);
      expect(state.loadState, HomeLoadState.unavailable);
      expect(state.isUnavailable, isTrue);
    });

    test('refresh com valor anterior mantém Home ready', () async {
      final harness = _HomeHarness();
      addTearDown(harness.dispose);
      await harness.emitReady(habitList: [_habit('habit-1')]);

      harness.container.invalidate(habitsStreamProvider);

      expect(harness.container.read(habitsStreamProvider).hasValue, isTrue);
      expect(
        harness.container.read(homeStateProvider).loadState,
        HomeLoadState.ready,
      );
    });

    test('erro com valor anterior mantém Home ready', () async {
      final harness = _HomeHarness();
      addTearDown(harness.dispose);
      await harness.emitReady(habitList: [_habit('habit-1')]);

      harness.habits.addError(StateError('falha de refresh'));
      await harness.settle();

      expect(harness.container.read(habitsStreamProvider).hasValue, isTrue);
      expect(
        harness.container.read(homeStateProvider).loadState,
        HomeLoadState.ready,
      );
    });

    test('listas vazias reais são ready, não loading', () async {
      final harness = _HomeHarness();
      addTearDown(harness.dispose);

      await harness.emitReady();

      final state = harness.container.read(homeStateProvider);
      expect(state.loadState, HomeLoadState.ready);
      expect(state.totalHabits, 0);
      expect(state.medicationCount, 0);
      expect(state.nextExam, isNull);
    });
  });

  group('homeStateProvider cache', () {
    test('preserva hábitos anteriores durante refresh', () async {
      final harness = _HomeHarness();
      addTearDown(harness.dispose);
      await harness.emitReady(habitList: [_habit('habit-1')]);
      expect(harness.container.read(homeStateProvider).totalHabits, 1);

      harness.container.invalidate(habitsStreamProvider);

      expect(harness.container.read(homeStateProvider).totalHabits, 1);
    });

    test('preserva matérias anteriores durante refresh', () async {
      final harness = _HomeHarness();
      addTearDown(harness.dispose);
      await harness.emitReady(subjectList: [_subject('subject-1')]);
      expect(harness.container.read(homeStateProvider).nextExam, isNotNull);

      harness.container.invalidate(subjectsStreamProvider);

      final nextExam = harness.container.read(homeStateProvider).nextExam;
      expect(nextExam, isA<StudySubjectEntity>());
      expect((nextExam as StudySubjectEntity).id, 'subject-1');
    });

    test('preserva métricas existentes quando dados estão prontos', () async {
      final harness = _HomeHarness();
      addTearDown(harness.dispose);
      await harness.emitReady();

      final state = harness.container.read(homeStateProvider);
      expect(state.completedHabitsToday, 0);
      expect(state.totalHabits, 0);
      expect(state.medicationCount, 0);
      expect(state.dashboard.productivityScore, 85);
      expect(state.dashboard.studyStreak, 5);
    });
  });
}
