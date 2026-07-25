import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:life_os/features/onboarding/domain/entities/onboarding_prefs.dart';

// Mudamos de StateNotifier para Notifier
class OnboardingNotifier extends Notifier<OnboardingPrefs> {
  @override
  OnboardingPrefs build() {
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
    final user = FirebaseAuth.instance.currentUser;

    // Atualiza o estado local
    state = OnboardingPrefs(
      selectedFocusAreas: state.selectedFocusAreas,
      hasCompletedOnboarding: true,
    );

    // Salva no Firestore se o usuário estiver logado
    if (user != null) {
      await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
        'selectedFocusAreas': state.selectedFocusAreas,
        'hasCompletedOnboarding': true,
      }, SetOptions(merge: true));
    }
  }
}

// Atualizado para NotifierProvider
final onboardingProvider =
    NotifierProvider<OnboardingNotifier, OnboardingPrefs>(
      OnboardingNotifier.new,
    );
