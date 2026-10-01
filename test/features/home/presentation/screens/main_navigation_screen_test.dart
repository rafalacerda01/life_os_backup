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
      '/tasks',
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
    final bottomNavigation = tester.widget<BottomNavigationBar>(
      find.byType(BottomNavigationBar),
    );
    expect(bottomNavigation.items, hasLength(5));
    expect(bottomNavigation.items.map((item) => item.label), [
      'Início',
      'Estudos',
      'Saúde',
      'Finanças',
      'IA',
    ]);

    await tester.tap(find.byTooltip('Abrir menu'));
    await tester.pumpAndSettle();

    for (final option in [
      'Foco',
      'Tarefas',
      'Metas',
      'Círculos',
      'Análises',
      'Ajustes',
      'Sair',
    ]) {
      expect(find.text(option), findsOneWidget);
    }
    expect(
      tester
          .widgetList<ListTile>(find.byType(ListTile))
          .map((tile) => (tile.title! as Text).data),
      ['Foco', 'Tarefas', 'Metas', 'Círculos', 'Análises', 'Ajustes', 'Sair'],
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('selecionar Tarefas no menu navega para /tasks sem criar aba', (
    tester,
  ) async {
    final router = _router();
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(child: MaterialApp.router(routerConfig: router)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Abrir menu'));
    await tester.pumpAndSettle();

    final tasksLabel = find.text('Tarefas');
    expect(tasksLabel, findsOneWidget);
    final tasksItem = find.ancestor(
      of: tasksLabel,
      matching: find.byType(PopupMenuItem<String>),
    );
    expect(tester.widget<PopupMenuItem<String>>(tasksItem).value, '/tasks');
    expect(
      find.descendant(
        of: tasksItem,
        matching: find.byIcon(Icons.task_alt_rounded),
      ),
      findsOneWidget,
    );

    await tester.tap(tasksLabel);
    await tester.pumpAndSettle();

    expect(router.routeInformationProvider.value.uri.path, '/tasks');
    expect(find.text('/tasks'), findsOneWidget);
    expect(find.text('/home'), findsNothing);
    final bottomNavigation = tester.widget<BottomNavigationBar>(
      find.byType(BottomNavigationBar),
    );
    expect(bottomNavigation.items, hasLength(5));
    expect(bottomNavigation.items.map((item) => item.label), [
      'Início',
      'Estudos',
      'Saúde',
      'Finanças',
      'IA',
    ]);
    expect(tester.takeException(), isNull);
  });
}
