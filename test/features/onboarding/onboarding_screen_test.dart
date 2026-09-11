import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:life_os/core/services/analytics_service.dart';
import 'package:life_os/features/onboarding/presentation/onboarding_provider.dart';
import 'package:life_os/features/onboarding/presentation/onboarding_screen.dart';
import 'package:life_os/features/settings/presentation/providers/analytics_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/recording_analytics_platform.dart';

class _RecordingOnboardingStore implements OnboardingCompletionStore {
  bool completed = false;
  int writeCalls = 0;

  @override
  Future<bool> hasCompleted() async => completed;

  @override
  Future<void> markCompleted() async {
    writeCalls++;
    completed = true;
  }
}

void main() {
  Future<({GoRouter router, _RecordingOnboardingStore store})> pumpOnboarding(
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final store = _RecordingOnboardingStore();
    final container = ProviderContainer(
      overrides: [
        onboardingCompletionStoreProvider.overrideWithValue(store),
        analyticsServiceProvider.overrideWithValue(
          AnalyticsService(platform: RecordingAnalyticsPlatform()),
        ),
      ],
    );
    final router = GoRouter(
      initialLocation: '/onboarding',
      routes: [
        GoRoute(
          path: '/onboarding',
          builder: (_, _) => const OnboardingScreen(),
        ),
        GoRoute(path: '/login', builder: (_, _) => const Text('Login')),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(router.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    return (router: router, store: store);
  }

  testWidgets('Continuar não exige áreas, persiste e segue para login', (
    tester,
  ) async {
    final harness = await pumpOnboarding(tester);

    expect(find.byType(GridView), findsNothing);
    expect(find.text('Seu Life OS começa aqui'), findsOneWidget);
    expect(find.text('Vamos te conhecer melhor'), findsNothing);
    expect(
      find.text('Selecione as áreas que você quer melhorar na sua vida'),
      findsNothing,
    );
    expect(find.text('Ajude a melhorar o Life OS'), findsOneWidget);
    expect(find.byType(Switch), findsOneWidget);
    expect(
      tester
          .widget<ElevatedButton>(
            find.widgetWithText(ElevatedButton, 'Continuar'),
          )
          .onPressed,
      isNotNull,
    );

    await tester.tap(find.text('Continuar'));
    await tester.pumpAndSettle();

    expect(harness.store.writeCalls, 1);
    expect(harness.store.completed, isTrue);
    expect(harness.router.state.uri.path, '/login');
  });

  testWidgets('Pular também persiste e segue para login', (tester) async {
    final harness = await pumpOnboarding(tester);

    await tester.tap(find.text('Pular'));
    await tester.pumpAndSettle();

    expect(harness.store.writeCalls, 1);
    expect(harness.store.completed, isTrue);
    expect(harness.router.state.uri.path, '/login');
  });
}
