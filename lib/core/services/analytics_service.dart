import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String analyticsEnabledPreferenceKey = 'analytics_enabled';

typedef AnalyticsPreferencesLoader = Future<SharedPreferences> Function();

abstract interface class AnalyticsPlatform {
  Future<void> setCollectionEnabled(bool enabled);

  Future<void> resetAnalyticsData();
}

class FirebaseAnalyticsPlatform implements AnalyticsPlatform {
  FirebaseAnalyticsPlatform({FirebaseAnalytics? analytics})
    : _analytics = analytics ?? FirebaseAnalytics.instance;

  final FirebaseAnalytics _analytics;

  @override
  Future<void> setCollectionEnabled(bool enabled) {
    return _analytics.setAnalyticsCollectionEnabled(enabled);
  }

  @override
  Future<void> resetAnalyticsData() => _analytics.resetAnalyticsData();
}

class AnalyticsService {
  AnalyticsService({AnalyticsPlatform? platform})
    : _platform = platform ?? FirebaseAnalyticsPlatform();

  final AnalyticsPlatform _platform;

  Future<void> setCollectionEnabled(bool enabled) {
    return _platform.setCollectionEnabled(enabled);
  }

  Future<void> resetAnalyticsData() => _platform.resetAnalyticsData();
}

class AnalyticsPreferenceStore {
  AnalyticsPreferenceStore({AnalyticsPreferencesLoader? preferencesLoader})
    : _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance;

  final AnalyticsPreferencesLoader _preferencesLoader;

  Future<bool> loadEnabled() async {
    final preferences = await _preferencesLoader();
    return preferences.getBool(analyticsEnabledPreferenceKey) ?? false;
  }

  Future<bool> saveEnabled(bool enabled) async {
    final preferences = await _preferencesLoader();
    return preferences.setBool(analyticsEnabledPreferenceKey, enabled);
  }
}

Future<void> initializeAnalyticsCollection({
  AnalyticsService? service,
  AnalyticsPreferenceStore? preferenceStore,
}) async {
  final analyticsService = service ?? AnalyticsService();
  final store = preferenceStore ?? AnalyticsPreferenceStore();

  try {
    await analyticsService.setCollectionEnabled(false);
    if (await store.loadEnabled()) {
      await analyticsService.setCollectionEnabled(true);
    }
  } catch (_) {
    await _disableCollectionBestEffort(analyticsService);
  }
}

Future<void> _disableCollectionBestEffort(AnalyticsService service) async {
  try {
    await service.setCollectionEnabled(false);
  } catch (_) {
    // Native configuration remains the fail-closed baseline.
  }
}
