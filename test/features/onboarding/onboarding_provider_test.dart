import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/services/analytics_service.dart';
import 'package:life_os/features/onboarding/presentation/onboarding_provider.dart';
import 'package:life_os/features/settings/presentation/providers/analytics_provider.dart';

import '../../helpers/recording_analytics_platform.dart';

class _MemoryOnboardingStore implements OnboardingCompletionStore {
  bool completed = false;
  bool throwOnWrite = false;
  int writeCalls = 0;

  @override
  Future<bool> hasCompleted() async => completed;

  @override
  Future<void> markCompleted() async {
    writeCalls++;
    if (throwOnWrite) throw StateError('storage unavailable');
    completed = true;
  }
}

class _FailingReadOnboardingStore implements OnboardingCompletionStore {
  @override
  Future<bool> hasCompleted() => Future<bool>.error(StateError('read failed'));

  @override
  Future<void> markCompleted() async {}
}

void main() {
  test(
    'primeira execução sem flag retorna false e conclusão persiste true',
    () async {
      final store = _MemoryOnboardingStore();

      expect(await store.hasCompleted(), isFalse);

      await store.markCompleted();

      expect(await store.hasCompleted(), isTrue);
    },
  );

  test(
    'falha de leitura inicial é tratada como onboarding incompleto',
    () async {
      final container = ProviderContainer(
        overrides: [
          onboardingCompletionStoreProvider.overrideWithValue(
            _FailingReadOnboardingStore(),
          ),
        ],
      );
      addTearDown(container.dispose);

      final completed = await container.read(
        onboardingCompletionStatusProvider.future,
      );

      expect(completed, isFalse);
    },
  );

  test('store injetável conclui uma vez sem ativar Analytics', () async {
    final store = _MemoryOnboardingStore();
    final analytics = RecordingAnalyticsPlatform();
    final container = ProviderContainer(
      overrides: [
        onboardingCompletionStoreProvider.overrideWithValue(store),
        analyticsServiceProvider.overrideWithValue(
          AnalyticsService(platform: analytics),
        ),
      ],
    );
    addTearDown(container.dispose);

    final notifier = container.read(onboardingProvider.notifier);
    expect(await notifier.completeOnboarding(), isTrue);
    expect(await notifier.completeOnboarding(), isTrue);
    await pumpEventQueue();

    expect(store.completed, isTrue);
    expect(store.writeCalls, 1);
    expect(container.read(onboardingProvider).hasCompletedOnboarding, isTrue);
    expect(container.read(onboardingProvider).operationInProgress, isFalse);
    expect(analytics.collectionChanges, isEmpty);
    expect(analytics.events, <RecordedAnalyticsEvent>[
      const RecordedAnalyticsEvent('onboarding_completed'),
    ]);
  });

  test('falha de escrita não prende o usuário no onboarding', () async {
    final store = _MemoryOnboardingStore()..throwOnWrite = true;
    final container = ProviderContainer(
      overrides: [
        onboardingCompletionStoreProvider.overrideWithValue(store),
        analyticsServiceProvider.overrideWithValue(
          AnalyticsService(platform: RecordingAnalyticsPlatform()),
        ),
      ],
    );
    addTearDown(container.dispose);

    final completed = await container
        .read(onboardingProvider.notifier)
        .completeOnboarding();

    expect(completed, isTrue);
    expect(container.read(onboardingProvider).hasCompletedOnboarding, isTrue);
  });
}
