import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:life_os/core/utils/app_logger.dart';
import 'package:life_os/features/settings/presentation/providers/analytics_provider.dart';
import 'package:life_os/features/onboarding/domain/entities/onboarding_prefs.dart';

const onboardingCompletedPreferenceKey = 'life_os_onboarding_completed_v1';

abstract interface class OnboardingCompletionStore {
  Future<bool> hasCompleted();

  Future<void> markCompleted();
}

class SharedPreferencesOnboardingCompletionStore
    implements OnboardingCompletionStore {
  SharedPreferencesOnboardingCompletionStore({SharedPreferencesAsync? prefs})
    : _prefs = prefs ?? SharedPreferencesAsync();

  final SharedPreferencesAsync _prefs;

  @override
  Future<bool> hasCompleted() async {
    return await _prefs.getBool(onboardingCompletedPreferenceKey) ?? false;
  }

  @override
  Future<void> markCompleted() {
    return _prefs.setBool(onboardingCompletedPreferenceKey, true);
  }
}

final onboardingCompletionStoreProvider = Provider<OnboardingCompletionStore>(
  (ref) => SharedPreferencesOnboardingCompletionStore(),
);

final onboardingCompletionStatusProvider = FutureProvider<bool>((ref) async {
  try {
    return await ref.read(onboardingCompletionStoreProvider).hasCompleted();
  } catch (_) {
    AppLogger.w('Não foi possível ler o estado local do onboarding.');
    return false;
  }
});

class OnboardingNotifier extends Notifier<OnboardingPrefs> {
  bool _completionInProgress = false;
  bool _completionRecorded = false;

  @override
  OnboardingPrefs build() {
    _completionInProgress = false;
    _completionRecorded = false;
    return const OnboardingPrefs(hasCompletedOnboarding: false);
  }

  Future<bool> completeOnboarding() async {
    if (_completionInProgress) return false;
    if (state.hasCompletedOnboarding) return true;

    _completionInProgress = true;
    state = const OnboardingPrefs(
      hasCompletedOnboarding: false,
      operationInProgress: true,
    );

    try {
      try {
        await ref.read(onboardingCompletionStoreProvider).markCompleted();
      } catch (_) {
        AppLogger.w('Não foi possível salvar o estado local do onboarding.');
      }

      state = const OnboardingPrefs(hasCompletedOnboarding: true);
      if (!_completionRecorded) {
        _completionRecorded = true;
        unawaited(ref.read(analyticsServiceProvider).logOnboardingCompleted());
      }
      return true;
    } finally {
      _completionInProgress = false;
      if (state.operationInProgress) {
        state = OnboardingPrefs(
          hasCompletedOnboarding: state.hasCompletedOnboarding,
        );
      }
    }
  }
}

final onboardingProvider =
    NotifierProvider<OnboardingNotifier, OnboardingPrefs>(
      OnboardingNotifier.new,
    );
