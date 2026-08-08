import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:life_os/features/onboarding/presentation/splash_screen.dart';

void main() {
  testWidgets('Splash renderiza corretamente', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: SplashScreen()));

    // Executa somente o primeiro frame.
    // Não avançamos os 4 segundos do Splash.
    await tester.pump();

    // Estrutura principal.
    expect(find.byType(Scaffold), findsOneWidget);

    // O logo "Life OS" é um RichText composto por dois TextSpan.
    expect(find.byType(RichText), findsOneWidget);

    // O anel neon utiliza exatamente uma RotationTransition.
    expect(find.byType(RotationTransition), findsOneWidget);

    // Slogan.
    expect(find.text('Seu sistema.\nSua vida.\nSeu melhor.'), findsOneWidget);
  });
}
