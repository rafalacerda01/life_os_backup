import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/services/analytics_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
}
