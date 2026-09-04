import 'package:life_os/core/services/analytics_service.dart';

class RecordedAnalyticsEvent {
  const RecordedAnalyticsEvent(this.name, [this.parameters = const {}]);

  final String name;
  final Map<String, Object> parameters;

  @override
  bool operator ==(Object other) {
    if (other is! RecordedAnalyticsEvent ||
        name != other.name ||
        parameters.length != other.parameters.length) {
      return false;
    }
    return parameters.entries.every(
      (entry) => other.parameters[entry.key] == entry.value,
    );
  }

  @override
  int get hashCode => Object.hash(name, Object.hashAll(parameters.entries));

  @override
  String toString() => 'RecordedAnalyticsEvent($name, $parameters)';
}

class RecordingAnalyticsPlatform implements AnalyticsPlatform {
  final List<bool> collectionChanges = <bool>[];
  final List<RecordedAnalyticsEvent> events = <RecordedAnalyticsEvent>[];
  int resetCalls = 0;
  bool throwOnEvent = false;

  Future<void> _record(
    String name, [
    Map<String, Object> parameters = const {},
  ]) async {
    if (throwOnEvent) throw StateError('private analytics failure');
    events.add(RecordedAnalyticsEvent(name, parameters));
  }

  @override
  Future<void> setCollectionEnabled(bool enabled) async {
    collectionChanges.add(enabled);
  }

  @override
  Future<void> resetAnalyticsData() async {
    resetCalls += 1;
  }

  @override
  Future<void> logAnalyticsOptIn() => _record('analytics_opt_in');

  @override
  Future<void> logOnboardingCompleted() => _record('onboarding_completed');

  @override
  Future<void> logLogin(AnalyticsAuthMethod method) {
    return _record('login', <String, Object>{'method': method.name});
  }

  @override
  Future<void> logSignUp(AnalyticsAuthMethod method) {
    return _record('sign_up', <String, Object>{'method': method.name});
  }

  @override
  Future<void> logTaskCompleted() => _record('task_completed');

  @override
  Future<void> logHabitCompleted() => _record('habit_completed');

  @override
  Future<void> logFocusCompleted(int durationMinutes) {
    return _record('focus_completed', <String, Object>{
      'duration_minutes': durationMinutes,
    });
  }

  @override
  Future<void> logSupportOpened() => _record('support_opened');
}
