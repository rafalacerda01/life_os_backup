import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/services/analytics_service.dart';
import 'package:life_os/features/settings/presentation/providers/analytics_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeAnalyticsPlatform implements AnalyticsPlatform {
  final List<String> events = <String>[];
  bool throwOnEnable = false;
  bool throwOnReset = false;

  @override
  Future<void> setCollectionEnabled(bool enabled) async {
    events.add('collection:$enabled');
    if (enabled && throwOnEnable) {
      throw StateError('private analytics error');
    }
  }

  @override
  Future<void> resetAnalyticsData() async {
    events.add('reset');
    if (throwOnReset) throw StateError('private reset error');
  }
}

Future<void> _settle() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

ProviderContainer _container(
  _FakeAnalyticsPlatform platform, {
  AnalyticsPreferenceStore? store,
}) {
  final container = ProviderContainer(
    overrides: [
      analyticsServiceProvider.overrideWithValue(
        AnalyticsService(platform: platform),
      ),
      if (store != null)
        analyticsPreferenceStoreProvider.overrideWithValue(store),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('preference starts loading and absent value becomes disabled', () async {
    final preferences = Completer<SharedPreferences>();
    final platform = _FakeAnalyticsPlatform();
    final container = _container(
      platform,
      store: AnalyticsPreferenceStore(
        preferencesLoader: () => preferences.future,
      ),
    );

    expect(
      container.read(analyticsPreferenceProvider).status,
      AnalyticsPreferenceStatus.loading,
    );
    preferences.complete(await SharedPreferences.getInstance());
    await _settle();

    expect(
      container.read(analyticsPreferenceProvider).status,
      AnalyticsPreferenceStatus.disabled,
    );
    expect(platform.events, <String>['collection:false']);
  });

  test('persisted false becomes disabled', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      analyticsEnabledPreferenceKey: false,
    });
    final platform = _FakeAnalyticsPlatform();
    final container = _container(platform);

    container.read(analyticsPreferenceProvider);
    await _settle();

    expect(
      container.read(analyticsPreferenceProvider).status,
      AnalyticsPreferenceStatus.disabled,
    );
    expect(platform.events, <String>['collection:false']);
  });

  test('persisted true becomes enabled', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      analyticsEnabledPreferenceKey: true,
    });
    final platform = _FakeAnalyticsPlatform();
    final container = _container(platform);

    container.read(analyticsPreferenceProvider);
    await _settle();

    expect(
      container.read(analyticsPreferenceProvider).status,
      AnalyticsPreferenceStatus.enabled,
    );
    expect(platform.events, <String>['collection:true']);
  });

  test('enable persists preference before enabling collection', () async {
    final platform = _FakeAnalyticsPlatform();
    final container = _container(platform);
    container.read(analyticsPreferenceProvider);
    await _settle();
    platform.events.clear();

    final succeeded = await container
        .read(analyticsPreferenceProvider.notifier)
        .setEnabled(true);

    expect(succeeded, isTrue);
    expect(platform.events, <String>['collection:true']);
    expect(
      (await SharedPreferences.getInstance()).getBool(
        analyticsEnabledPreferenceKey,
      ),
      isTrue,
    );
    expect(
      container.read(analyticsPreferenceProvider).status,
      AnalyticsPreferenceStatus.enabled,
    );
  });

  test(
    'disable turns collection off, persists false and resets data',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        analyticsEnabledPreferenceKey: true,
      });
      final platform = _FakeAnalyticsPlatform();
      final container = _container(platform);
      container.read(analyticsPreferenceProvider);
      await _settle();
      platform.events.clear();

      final succeeded = await container
          .read(analyticsPreferenceProvider.notifier)
          .setEnabled(false);

      expect(succeeded, isTrue);
      expect(platform.events, <String>['collection:false', 'reset']);
      expect(
        (await SharedPreferences.getInstance()).getBool(
          analyticsEnabledPreferenceKey,
        ),
        isFalse,
      );
      expect(
        container.read(analyticsPreferenceProvider).status,
        AnalyticsPreferenceStatus.disabled,
      );
    },
  );

  test(
    'loader failure disables collection and resolves conservatively',
    () async {
      final platform = _FakeAnalyticsPlatform();
      final container = _container(
        platform,
        store: AnalyticsPreferenceStore(
          preferencesLoader: () async => throw StateError('private error'),
        ),
      );

      container.read(analyticsPreferenceProvider);
      await _settle();

      expect(platform.events, <String>['collection:false']);
      expect(
        container.read(analyticsPreferenceProvider).status,
        AnalyticsPreferenceStatus.disabled,
      );
    },
  );

  test(
    'Firebase enable failure rolls preference back and stays disabled',
    () async {
      final platform = _FakeAnalyticsPlatform()..throwOnEnable = true;
      final container = _container(platform);
      container.read(analyticsPreferenceProvider);
      await _settle();
      platform.events.clear();

      final succeeded = await container
          .read(analyticsPreferenceProvider.notifier)
          .setEnabled(true);

      expect(succeeded, isFalse);
      expect(platform.events, <String>['collection:true', 'collection:false']);
      expect(
        (await SharedPreferences.getInstance()).getBool(
          analyticsEnabledPreferenceKey,
        ),
        isFalse,
      );
      expect(
        container.read(analyticsPreferenceProvider).status,
        AnalyticsPreferenceStatus.disabled,
      );
    },
  );

  test('Firebase load synchronization failure does not escape', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      analyticsEnabledPreferenceKey: true,
    });
    final platform = _FakeAnalyticsPlatform()..throwOnEnable = true;
    final container = _container(platform);

    container.read(analyticsPreferenceProvider);
    await _settle();

    expect(platform.events, <String>['collection:true', 'collection:false']);
    expect(
      container.read(analyticsPreferenceProvider).status,
      AnalyticsPreferenceStatus.disabled,
    );
  });

  test(
    'reset failure leaves collection disabled without false success',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        analyticsEnabledPreferenceKey: true,
      });
      final platform = _FakeAnalyticsPlatform()..throwOnReset = true;
      final container = _container(platform);
      container.read(analyticsPreferenceProvider);
      await _settle();
      platform.events.clear();

      final succeeded = await container
          .read(analyticsPreferenceProvider.notifier)
          .setEnabled(false);

      expect(succeeded, isFalse);
      expect(platform.events, <String>['collection:false', 'reset']);
      expect(
        container.read(analyticsPreferenceProvider).status,
        AnalyticsPreferenceStatus.disabled,
      );
    },
  );
}
