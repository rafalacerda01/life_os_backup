import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:life_os/features/home/presentation/screens/main_navigation_screen.dart';

GoRouter _router() => GoRouter(
  initialLocation: '/home',
  routes: [
    for (final path in [
      '/home',
      '/study',
      '/health',
      '/finance',
      '/ai-companion',
    ])
      GoRoute(
        path: path,
        builder: (context, state) =>
            MainNavigationScreen(child: Center(child: Text(path))),
      ),
  ],
);

void main() {
  testWidgets('preserva cinco destinos e opções do menu superior', (
    tester,
  ) async {
    final router = _router();
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(child: MaterialApp.router(routerConfig: router)),
    );
    await tester.pumpAndSettle();

    for (final label in ['Início', 'Estudos', 'Saúde', 'Finanças', 'IA']) {
      expect(find.text(label), findsOneWidget);
    }

    await tester.tap(find.byTooltip('Abrir menu'));
    await tester.pumpAndSettle();

    for (final option in [
      'Foco',
      'Metas',
      'Círculos',
      'Análises',
      'Ajustes',
      'Sair',
    ]) {
      expect(find.text(option), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });
}
