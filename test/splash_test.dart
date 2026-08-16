import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:life_os/features/onboarding/presentation/splash_screen.dart';

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

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));

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

    // Avança o timer da Splash e permite a navegação para /onboarding.
    await tester.pump(const Duration(seconds: 4));

    expect(router.state.uri.path, '/onboarding');
    router.dispose();
  });
}
