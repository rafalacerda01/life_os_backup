import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:life_os/features/auth/presentation/providers/auth_provider.dart';
import 'package:life_os/features/auth/presentation/providers/auth_state.dart';
import 'package:life_os/features/onboarding/presentation/onboarding_provider.dart';
import 'package:life_os/features/onboarding/presentation/splash_screen.dart';

class _UnauthenticatedNotifier extends AuthNotifier {
  @override
  AuthState build() => AuthState.unauthenticated();
}

class _IncompleteOnboardingStore implements OnboardingCompletionStore {
  @override
  Future<bool> hasCompleted() async => false;

  @override
  Future<void> markCompleted() async {}
}

void main() {
  testWidgets('Splash renderiza corretamente', (WidgetTester tester) async {
    final router = GoRouter(
      initialLocation: '/splash',
      routes: [
        GoRoute(
          path: '/splash',
          builder: (context, state) => const SplashScreen(),
        ),
        GoRoute(
          path: '/onboarding',
          builder: (context, state) => const SizedBox.shrink(),
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authNotifierProvider.overrideWith(_UnauthenticatedNotifier.new),
          onboardingCompletionStoreProvider.overrideWithValue(
            _IncompleteOnboardingStore(),
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );

    // Executa o primeiro frame sem avançar o timer da Splash.
    await tester.pump();

    // Estrutura principal.
    expect(find.byType(Scaffold), findsOneWidget);

    // Logo "Life OS".
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is RichText && widget.text.toPlainText() == 'Life OS',
      ),
      findsOneWidget,
    );

    // A Splash utiliza duas RotationTransition.
    expect(find.byType(RotationTransition), findsNWidgets(2));

    // Slogan.
    expect(find.text('Seu sistema.\nSua vida.\nSeu melhor.'), findsOneWidget);

    // A decisão ocorre pelo estado, sem aguardar o antigo atraso artificial.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));

    expect(router.state.uri.path, '/onboarding');
    router.dispose();
  });
}
