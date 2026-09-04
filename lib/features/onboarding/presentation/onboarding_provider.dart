import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:life_os/features/settings/presentation/providers/analytics_provider.dart';
import 'package:life_os/features/onboarding/domain/entities/onboarding_prefs.dart';

final onboardingCurrentUserProvider = Provider<User?>((ref) {
  return FirebaseAuth.instance.currentUser;
});

final onboardingFirestoreProvider = Provider<FirebaseFirestore>((ref) {
  return FirebaseFirestore.instance;
});

// Mudamos de StateNotifier para Notifier
class OnboardingNotifier extends Notifier<OnboardingPrefs> {
  bool _completionInProgress = false;
  bool _completionRecorded = false;

  @override
  OnboardingPrefs build() {
    _completionInProgress = false;
    _completionRecorded = false;
    // Estado inicial movido para o build()
    return const OnboardingPrefs(
      selectedFocusAreas: [],
      hasCompletedOnboarding: false,
    );
  }

  void toggleArea(String area) {
    final currentAreas = List<String>.from(state.selectedFocusAreas);
    if (currentAreas.contains(area)) {
      currentAreas.remove(area);
    } else {
      currentAreas.add(area);
    }
    // A variável 'state' já está disponível na classe Notifier
    state = OnboardingPrefs(
      selectedFocusAreas: currentAreas,
      hasCompletedOnboarding: state.hasCompletedOnboarding,
    );
  }

  Future<void> completeOnboarding() async {
    if (_completionInProgress || _completionRecorded) return;
    _completionInProgress = true;
    final user = ref.read(onboardingCurrentUserProvider);
    final analytics = ref.read(analyticsServiceProvider);

    try {
      // Atualiza o estado local
      state = OnboardingPrefs(
        selectedFocusAreas: state.selectedFocusAreas,
        hasCompletedOnboarding: true,
      );

      // Salva no Firestore se o usuário estiver logado
      if (user != null) {
        await ref
            .read(onboardingFirestoreProvider)
            .collection('users')
            .doc(user.uid)
            .set({
              'selectedFocusAreas': state.selectedFocusAreas,
              'hasCompletedOnboarding': true,
            }, SetOptions(merge: true));
      }

      unawaited(analytics.logOnboardingCompleted());
      _completionRecorded = true;
    } finally {
      _completionInProgress = false;
    }
  }
}

// Atualizado para NotifierProvider
final onboardingProvider =
    NotifierProvider<OnboardingNotifier, OnboardingPrefs>(
      OnboardingNotifier.new,
    );
