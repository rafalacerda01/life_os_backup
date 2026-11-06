import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/features/ai_companion/presentation/ai_companion_screen.dart';

void main() {
  testWidgets(
    'release AI entry builds without Auth, Premium, consent or request',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: AICompanionScreen.releaseUnavailable()),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Companion IA indisponível nesta versão.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
