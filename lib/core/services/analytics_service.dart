import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String analyticsEnabledPreferenceKey = 'analytics_enabled';

typedef AnalyticsPreferencesLoader = Future<SharedPreferences> Function();

enum AnalyticsAuthMethod { email, google }

abstract interface class AnalyticsPlatform {
  Future<void> setCollectionEnabled(bool enabled);

  Future<void> resetAnalyticsData();

  Future<void> logAnalyticsOptIn();

  Future<void> logOnboardingCompleted();

  Future<void> logLogin(AnalyticsAuthMethod method);

  Future<void> logSignUp(AnalyticsAuthMethod method);

  Future<void> logTaskCompleted();

  Future<void> logHabitCompleted();

  Future<void> logFocusCompleted(int durationMinutes);

  Future<void> logSupportOpened();
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

  @override
  Future<void> logAnalyticsOptIn() {
    return _analytics.logEvent(name: 'analytics_opt_in');
  }

  @override
  Future<void> logOnboardingCompleted() {
    return _analytics.logEvent(name: 'onboarding_completed');
  }

  @override
  Future<void> logLogin(AnalyticsAuthMethod method) {
    return _analytics.logLogin(loginMethod: method.name);
  }

  @override
  Future<void> logSignUp(AnalyticsAuthMethod method) {
    return _analytics.logSignUp(signUpMethod: method.name);
  }

  @override
  Future<void> logTaskCompleted() {
    return _analytics.logEvent(name: 'task_completed');
  }

  @override
  Future<void> logHabitCompleted() {
    return _analytics.logEvent(name: 'habit_completed');
  }

  @override
  Future<void> logFocusCompleted(int durationMinutes) {
    return _analytics.logEvent(
      name: 'focus_completed',
      parameters: <String, Object>{'duration_minutes': durationMinutes},
    );
  }

  @override
  Future<void> logSupportOpened() {
    return _analytics.logEvent(name: 'support_opened');
  }
}

class AnalyticsService {
  AnalyticsService({AnalyticsPlatform? platform})
    : _platform = platform ?? FirebaseAnalyticsPlatform();

  final AnalyticsPlatform _platform;

  Future<void> setCollectionEnabled(bool enabled) {
    return _platform.setCollectionEnabled(enabled);
  }

  Future<void> resetAnalyticsData() => _platform.resetAnalyticsData();

  Future<void> logAnalyticsOptIn() {
    return _runBestEffort(_platform.logAnalyticsOptIn);
  }

  Future<void> logOnboardingCompleted() {
    return _runBestEffort(_platform.logOnboardingCompleted);
  }

  Future<void> logLogin({required AnalyticsAuthMethod method}) {
    return _runBestEffort(() => _platform.logLogin(method));
  }

  Future<void> logSignUp({required AnalyticsAuthMethod method}) {
    return _runBestEffort(() => _platform.logSignUp(method));
  }

  Future<void> logTaskCompleted() {
    return _runBestEffort(_platform.logTaskCompleted);
  }

  Future<void> logHabitCompleted() {
    return _runBestEffort(_platform.logHabitCompleted);
  }

  Future<void> logFocusCompleted({required int durationMinutes}) {
    if (durationMinutes <= 0) return Future<void>.value();
    return _runBestEffort(() => _platform.logFocusCompleted(durationMinutes));
  }

  Future<void> logSupportOpened() {
    return _runBestEffort(_platform.logSupportOpened);
  }

  Future<void> _runBestEffort(Future<void> Function() operation) async {
    try {
      await operation();
    } catch (_) {
      // Product Analytics is never allowed to affect a user action.
    }
  }
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
