import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/core/services/analytics_service.dart';
import 'package:life_os/features/settings/presentation/providers/analytics_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:life_os/main.dart';
import 'package:life_os/features/auth/presentation/providers/auth_provider.dart';
import 'package:life_os/features/auth/presentation/providers/auth_state.dart';
import 'package:life_os/features/onboarding/presentation/onboarding_provider.dart';

import 'helpers/recording_analytics_platform.dart';

class FakeAuthNotifier extends AuthNotifier {
  @override
  AuthState build() {
    return AuthState.unauthenticated();
  }
}

void main() {
  testWidgets('LifeOSApp smoke test', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
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
    await tester.pump(const Duration(milliseconds: 1));

    // O aplicativo deve ter sido construído.
    expect(find.byType(MaterialApp), findsOneWidget);

    // Pode haver mais de um Scaffold durante a composição/navegação.
    expect(find.byType(Scaffold), findsWidgets);

    // O fluxo de destino e as corridas de bootstrap possuem testes focados.
    // Aqui basta confirmar que o app completo renderiza sem erro.
    expect(find.text('Seu sistema.\nSua vida.\nSeu melhor.'), findsOneWidget);
  });
}

class _IncompleteOnboardingStore implements OnboardingCompletionStore {
  @override
  Future<bool> hasCompleted() async => false;

  @override
  Future<void> markCompleted() async {}
}
