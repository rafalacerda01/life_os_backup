import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/services/analytics_service.dart';
import 'package:life_os/features/auth/presentation/providers/auth_provider.dart';
import 'package:life_os/features/auth/presentation/providers/auth_state.dart';
import 'package:life_os/features/onboarding/presentation/onboarding_provider.dart';
import 'package:life_os/features/settings/presentation/providers/analytics_provider.dart';
import 'package:life_os/main.dart';
import 'package:mockito/mockito.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/recording_analytics_platform.dart';

class FakeAuthNotifier extends AuthNotifier {
  @override
  AuthState build() {
    return AuthState.unauthenticated();
  }
}

class _MockFirebaseAuth extends Mock implements FirebaseAuth {}

void main() {
  testWidgets('LifeOSApp smoke test', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    final firebaseAuth = _MockFirebaseAuth();
    when(firebaseAuth.currentUser).thenReturn(null);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          firebaseAuthProvider.overrideWithValue(firebaseAuth),
          authNotifierProvider.overrideWith(FakeAuthNotifier.new),
          onboardingCompletionStoreProvider.overrideWithValue(
            _IncompleteOnboardingStore(),
          ),
          analyticsServiceProvider.overrideWithValue(
            AnalyticsService(platform: RecordingAnalyticsPlatform()),
          ),
        ],
        child: const LifeOSApp(),
      ),
    );

    await tester.pump();
    await tester.pumpAndSettle();

    // O aplicativo completo deve ter sido construído.
    expect(find.byType(MaterialApp), findsOneWidget);

    // Pode haver mais de um Scaffold durante a composição/navegação.
    expect(find.byType(Scaffold), findsWidgets);

    // Neste cenário o usuário está desautenticado e o onboarding
    // ainda não foi concluído, portanto o destino correto é /onboarding.
    expect(find.text('Seu Life OS começa aqui'), findsOneWidget);
  });
}

class _IncompleteOnboardingStore implements OnboardingCompletionStore {
  @override
  Future<bool> hasCompleted() async => false;

  @override
  Future<void> markCompleted() async {}
}
