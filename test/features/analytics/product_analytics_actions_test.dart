import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/services/analytics_service.dart';
import 'package:life_os/features/habits/data/repositories/habits_repository.dart';
import 'package:life_os/features/habits/presentation/providers/habits_provider.dart';
import 'package:life_os/features/onboarding/presentation/onboarding_provider.dart';
import 'package:life_os/features/onboarding/presentation/onboarding_screen.dart';
import 'package:life_os/features/settings/presentation/providers/analytics_provider.dart';
import 'package:life_os/features/settings/presentation/screens/contact_screen.dart';
import 'package:life_os/features/tasks/presentation/providers/tasks_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/recording_analytics_platform.dart';

class _TasksRepository extends Fake implements TasksRepository {
  int calls = 0;
  bool throwOnToggle = false;

  @override
  Future<void> toggleTaskStatus(String taskId, bool currentStatus) async {
    calls += 1;
    if (throwOnToggle) throw StateError('private task failure');
  }
}

class _HabitsRepository extends Fake implements HabitsRepository {
  int calls = 0;
  bool throwOnToggle = false;

  @override
  Future<void> toggleHabitToday(
    String habitId,
    List<String> currentDates,
  ) async {
    calls += 1;
    if (throwOnToggle) throw StateError('private habit failure');
  }
}

class _BlockingAnalyticsPlatform extends RecordingAnalyticsPlatform {
  final Completer<void> enableCompleter = Completer<void>();

  @override
  Future<void> setCollectionEnabled(bool enabled) async {
    collectionChanges.add(enabled);
    if (enabled) await enableCompleter.future;
  }
}

ProviderContainer _actionsContainer({
  required RecordingAnalyticsPlatform analytics,
  _TasksRepository? tasks,
  _HabitsRepository? habits,
  AnalyticsSessionActive? sessionActive,
}) {
  final container = ProviderContainer(
    overrides: [
      analyticsServiceProvider.overrideWithValue(
        AnalyticsService(platform: analytics),
      ),
      analyticsSessionActiveProvider.overrideWithValue(
        sessionActive ?? () => true,
      ),
      if (tasks != null) tasksRepositoryProvider.overrideWithValue(tasks),
      if (habits != null) habitsRepositoryProvider.overrideWithValue(habits),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('manual task completion', () {
    test('incomplete to complete records exactly one event', () async {
      final analytics = RecordingAnalyticsPlatform();
      final tasks = _TasksRepository();
      final container = _actionsContainer(analytics: analytics, tasks: tasks);

      await container.read(manualTaskStatusToggleProvider)('task-1', false);

      expect(tasks.calls, 1);
      expect(analytics.events, <RecordedAnalyticsEvent>[
        const RecordedAnalyticsEvent('task_completed'),
      ]);
    });

    test('complete to incomplete records no event', () async {
      final analytics = RecordingAnalyticsPlatform();
      final tasks = _TasksRepository();
      final container = _actionsContainer(analytics: analytics, tasks: tasks);

      await container.read(manualTaskStatusToggleProvider)('task-1', true);

      expect(tasks.calls, 1);
      expect(analytics.events, isEmpty);
    });

    test('unauthenticated incomplete task records no event', () async {
      final analytics = RecordingAnalyticsPlatform();
      final tasks = _TasksRepository();
      final container = _actionsContainer(
        analytics: analytics,
        tasks: tasks,
        sessionActive: () => false,
      );

      await container.read(manualTaskStatusToggleProvider)('task-1', false);

      expect(tasks.calls, 1);
      expect(analytics.events, isEmpty);
    });

    test('repository failure records no event', () async {
      final analytics = RecordingAnalyticsPlatform();
      final tasks = _TasksRepository()..throwOnToggle = true;
      final container = _actionsContainer(analytics: analytics, tasks: tasks);

      await expectLater(
        container.read(manualTaskStatusToggleProvider)('task-1', false),
        throwsStateError,
      );

      expect(analytics.events, isEmpty);
    });

    test('Analytics failure does not break task completion', () async {
      final analytics = RecordingAnalyticsPlatform()..throwOnEvent = true;
      final tasks = _TasksRepository();
      final container = _actionsContainer(analytics: analytics, tasks: tasks);

      await expectLater(
        container.read(manualTaskStatusToggleProvider)('task-1', false),
        completes,
      );

      expect(tasks.calls, 1);
    });
  });

  group('manual habit completion', () {
    test('incomplete to complete records exactly one event', () async {
      final analytics = RecordingAnalyticsPlatform();
      final habits = _HabitsRepository();
      final container = _actionsContainer(analytics: analytics, habits: habits);

      await container.read(manualHabitTodayToggleProvider)(
        'habit-1',
        const <String>[],
        false,
      );

      expect(habits.calls, 1);
      expect(analytics.events, <RecordedAnalyticsEvent>[
        const RecordedAnalyticsEvent('habit_completed'),
      ]);
    });

    test('complete to incomplete records no event', () async {
      final analytics = RecordingAnalyticsPlatform();
      final habits = _HabitsRepository();
      final container = _actionsContainer(analytics: analytics, habits: habits);

      await container.read(manualHabitTodayToggleProvider)(
        'habit-1',
        const <String>['2026-09-04'],
        true,
      );

      expect(habits.calls, 1);
      expect(analytics.events, isEmpty);
    });

    test('unauthenticated incomplete habit records no event', () async {
      final analytics = RecordingAnalyticsPlatform();
      final habits = _HabitsRepository();
      final container = _actionsContainer(
        analytics: analytics,
        habits: habits,
        sessionActive: () => false,
      );

      await container.read(manualHabitTodayToggleProvider)(
        'habit-1',
        const <String>[],
        false,
      );

      expect(habits.calls, 1);
      expect(analytics.events, isEmpty);
    });

    test('repository failure records no event', () async {
      final analytics = RecordingAnalyticsPlatform();
      final habits = _HabitsRepository()..throwOnToggle = true;
      final container = _actionsContainer(analytics: analytics, habits: habits);

      await expectLater(
        container.read(manualHabitTodayToggleProvider)(
          'habit-1',
          const <String>[],
          false,
        ),
        throwsStateError,
      );

      expect(analytics.events, isEmpty);
    });

    test('Analytics failure does not break habit completion', () async {
      final analytics = RecordingAnalyticsPlatform()..throwOnEvent = true;
      final habits = _HabitsRepository();
      final container = _actionsContainer(analytics: analytics, habits: habits);

      await expectLater(
        container.read(manualHabitTodayToggleProvider)(
          'habit-1',
          const <String>[],
          false,
        ),
        completes,
      );

      expect(habits.calls, 1);
    });
  });

  group('onboarding', () {
    test('completion logs once without forcing Analytics on', () async {
      final analytics = RecordingAnalyticsPlatform();
      final container = ProviderContainer(
        overrides: [
          analyticsServiceProvider.overrideWithValue(
            AnalyticsService(platform: analytics),
          ),
          onboardingCurrentUserProvider.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(onboardingProvider.notifier);
      notifier.toggleArea('Produtividade');
      await notifier.completeOnboarding();
      await notifier.completeOnboarding();

      expect(container.read(onboardingProvider).hasCompletedOnboarding, isTrue);
      expect(analytics.collectionChanges, isEmpty);
      expect(analytics.events, <RecordedAnalyticsEvent>[
        const RecordedAnalyticsEvent('onboarding_completed'),
      ]);
    });

    test('Analytics failure does not break completion', () async {
      final analytics = RecordingAnalyticsPlatform()..throwOnEvent = true;
      final container = ProviderContainer(
        overrides: [
          analyticsServiceProvider.overrideWithValue(
            AnalyticsService(platform: analytics),
          ),
          onboardingCurrentUserProvider.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);

      await container.read(onboardingProvider.notifier).completeOnboarding();

      expect(container.read(onboardingProvider).hasCompletedOnboarding, isTrue);
    });

    testWidgets('optional metrics choice starts off', (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final analytics = RecordingAnalyticsPlatform();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            onboardingCurrentUserProvider.overrideWithValue(null),
            analyticsServiceProvider.overrideWithValue(
              AnalyticsService(platform: analytics),
            ),
          ],
          child: const MaterialApp(home: OnboardingScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Ajude a melhorar o Life OS'), findsOneWidget);
      expect(
        find.textContaining('Nenhum conteúdo de saúde, finanças ou IA'),
        findsOneWidget,
      );
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    });

    testWidgets('consent transition temporarily disables onboarding CTAs', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(800, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final analytics = _BlockingAnalyticsPlatform();
      final container = ProviderContainer(
        overrides: [
          onboardingCurrentUserProvider.overrideWithValue(null),
          analyticsServiceProvider.overrideWithValue(
            AnalyticsService(platform: analytics),
          ),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: OnboardingScreen()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Produtividade'));
      await tester.pump();

      await tester.tap(find.byType(Switch));
      await tester.pump();

      expect(
        tester
            .widget<ElevatedButton>(
              find.widgetWithText(ElevatedButton, 'Continuar'),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Pular'))
            .onPressed,
        isNull,
      );

      await tester.tap(find.text('Continuar'));
      await tester.tap(find.text('Pular'));
      await tester.pump();

      expect(
        container.read(onboardingProvider).hasCompletedOnboarding,
        isFalse,
      );
      expect(tester.takeException(), isNull);

      analytics.enableCompleter.complete();
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<ElevatedButton>(
              find.widgetWithText(ElevatedButton, 'Continuar'),
            )
            .onPressed,
        isNotNull,
      );
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Pular'))
            .onPressed,
        isNotNull,
      );
    });
  });

  testWidgets('support opening logs once per screen instance', (tester) async {
    final analytics = RecordingAnalyticsPlatform();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          analyticsServiceProvider.overrideWithValue(
            AnalyticsService(platform: analytics),
          ),
        ],
        child: const MaterialApp(home: ContactScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(analytics.events, <RecordedAnalyticsEvent>[
      const RecordedAnalyticsEvent('support_opened'),
    ]);
  });
}
