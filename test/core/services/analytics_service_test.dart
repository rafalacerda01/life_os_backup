import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/services/analytics_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/recording_analytics_platform.dart';

class _FakeAnalyticsPlatform implements AnalyticsPlatform {
  final List<bool> collectionChanges = <bool>[];
  bool throwOnCollectionChange = false;
  int resetCalls = 0;

  @override
  Future<void> setCollectionEnabled(bool enabled) async {
    collectionChanges.add(enabled);
    if (throwOnCollectionChange) throw StateError('private analytics error');
  }

  @override
  Future<void> resetAnalyticsData() async {
    resetCalls += 1;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('startup without preference keeps collection disabled', () async {
    final platform = _FakeAnalyticsPlatform();

    await initializeAnalyticsCollection(
      service: AnalyticsService(platform: platform),
    );

    expect(platform.collectionChanges, <bool>[false]);
  });

  test('startup applies an explicit enabled preference', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      analyticsEnabledPreferenceKey: true,
    });
    final platform = _FakeAnalyticsPlatform();

    await initializeAnalyticsCollection(
      service: AnalyticsService(platform: platform),
    );

    expect(platform.collectionChanges, <bool>[false, true]);
  });

  test('startup preference failure remains fail-closed', () async {
    final platform = _FakeAnalyticsPlatform();
    final store = AnalyticsPreferenceStore(
      preferencesLoader: () async => throw StateError('private storage error'),
    );

    await initializeAnalyticsCollection(
      service: AnalyticsService(platform: platform),
      preferenceStore: store,
    );

    expect(platform.collectionChanges, <bool>[false, false]);
  });

  test('startup Analytics failure never breaks app bootstrap', () async {
    final platform = _FakeAnalyticsPlatform()..throwOnCollectionChange = true;

    await initializeAnalyticsCollection(
      service: AnalyticsService(platform: platform),
    );

    expect(platform.collectionChanges, <bool>[false, false]);
  });

  test('closed API emits only approved names and parameters', () async {
    final platform = RecordingAnalyticsPlatform();
    final service = AnalyticsService(platform: platform);

    await service.logAnalyticsOptIn();
    await service.logOnboardingCompleted();
    await service.logLogin(method: AnalyticsAuthMethod.email);
    await service.logLogin(method: AnalyticsAuthMethod.google);
    await service.logSignUp(method: AnalyticsAuthMethod.email);
    await service.logTaskCompleted();
    await service.logHabitCompleted();
    await service.logFocusCompleted(durationMinutes: 25);
    await service.logSupportOpened();

    expect(platform.events, <RecordedAnalyticsEvent>[
      const RecordedAnalyticsEvent('analytics_opt_in'),
      const RecordedAnalyticsEvent('onboarding_completed'),
      const RecordedAnalyticsEvent('login', {'method': 'email'}),
      const RecordedAnalyticsEvent('login', {'method': 'google'}),
      const RecordedAnalyticsEvent('sign_up', {'method': 'email'}),
      const RecordedAnalyticsEvent('task_completed'),
      const RecordedAnalyticsEvent('habit_completed'),
      const RecordedAnalyticsEvent('focus_completed', {'duration_minutes': 25}),
      const RecordedAnalyticsEvent('support_opened'),
    ]);
  });

  test('event failures are always best-effort', () async {
    final platform = RecordingAnalyticsPlatform()..throwOnEvent = true;
    final service = AnalyticsService(platform: platform);

    await expectLater(service.logTaskCompleted(), completes);
    await expectLater(
      service.logLogin(method: AnalyticsAuthMethod.email),
      completes,
    );

    expect(platform.events, isEmpty);
  });
}
