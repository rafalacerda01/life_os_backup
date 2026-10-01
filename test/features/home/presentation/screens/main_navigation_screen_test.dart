import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:life_os/core/services/sync_manager_provider.dart';
import 'package:life_os/core/services/sync_ui_event.dart';
import 'package:life_os/features/auth/presentation/providers/auth_provider.dart';
import 'package:life_os/features/home/presentation/screens/main_navigation_screen.dart';

class _FirebaseUser extends Fake implements User {
  _FirebaseUser(this.uid);

  @override
  final String uid;
}

class _FirebaseAuth extends Fake implements FirebaseAuth {
  User? user = _FirebaseUser('user-a');

  @override
  User? get currentUser => user;
}

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

Future<GoRouter> _pumpNavigation(
  WidgetTester tester, {
  Stream<SyncUiEvent> events = const Stream<SyncUiEvent>.empty(),
  FirebaseAuth? auth,
}) async {
  final router = _router();
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        syncUiEventsProvider.overrideWith((_) => events),
        if (auth != null) firebaseAuthProvider.overrideWithValue(auth),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

void main() {
  for (final testCase in {
    SyncUiEventType.resumed:
        'Sincronização retomada — enviando suas alterações…',
    SyncUiEventType.recoveryCompleted: 'Sincronização retomada concluída.',
  }.entries) {
    testWidgets('mostra ${testCase.key.name} para o UID autenticado', (
      tester,
    ) async {
      final controller = StreamController<SyncUiEvent>.broadcast();
      addTearDown(controller.close);
      await _pumpNavigation(
        tester,
        events: controller.stream,
        auth: _FirebaseAuth(),
      );

      expect(find.byType(SnackBar), findsNothing);
      controller.add(SyncUiEvent(type: testCase.key, ownerUid: 'user-a'));
      await tester.pumpAndSettle();

      expect(find.text(testCase.value), findsOneWidget);
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.textContaining('Conexão restaurada'), findsNothing);
      expect(find.textContaining('Tudo sincronizado'), findsNothing);
      expect(find.textContaining('user-a'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('retomada e conclusão imediatas aparecem em sequência', (
    tester,
  ) async {
    final controller = StreamController<SyncUiEvent>.broadcast();
    addTearDown(controller.close);
    await _pumpNavigation(
      tester,
      events: controller.stream,
      auth: _FirebaseAuth(),
    );

    controller
      ..add(
        const SyncUiEvent(type: SyncUiEventType.resumed, ownerUid: 'user-a'),
      )
      ..add(
        const SyncUiEvent(
          type: SyncUiEventType.recoveryCompleted,
          ownerUid: 'user-a',
        ),
      );
    await tester.pumpAndSettle();

    const resumed = 'Sincronização retomada — enviando suas alterações…';
    const completed = 'Sincronização retomada concluída.';
    expect(find.text(resumed), findsOneWidget);
    expect(find.text(completed), findsNothing);
    expect(find.textContaining('Tudo sincronizado'), findsNothing);
    expect(find.textContaining('user-a'), findsNothing);
    expect(
      tester.widget<SnackBar>(find.byType(SnackBar)).duration,
      const Duration(seconds: 2),
    );

    await tester.pump(const Duration(seconds: 1));
    expect(find.text(resumed), findsOneWidget);
    expect(find.text(completed), findsNothing);

    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text(resumed), findsNothing);
    expect(find.text(completed), findsOneWidget);
    expect(find.textContaining('Tudo sincronizado'), findsNothing);
    expect(find.textContaining('user-a'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final uid in ['user-b', null]) {
    testWidgets('não mostra evento de outro owner com sessão $uid', (
      tester,
    ) async {
      final auth = _FirebaseAuth()
        ..user = uid == null ? null : _FirebaseUser(uid);
      final controller = StreamController<SyncUiEvent>.broadcast();
      addTearDown(controller.close);
      await _pumpNavigation(tester, events: controller.stream, auth: auth);

      controller.add(
        const SyncUiEvent(type: SyncUiEventType.resumed, ownerUid: 'user-a'),
      );
      await tester.pumpAndSettle();
      controller.add(
        const SyncUiEvent(
          type: SyncUiEventType.recoveryCompleted,
          ownerUid: 'user-a',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(SnackBar), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'revalida UID antes de exibir evento adiado para o próximo frame',
    (tester) async {
      final auth = _FirebaseAuth();
      final controller = StreamController<SyncUiEvent>.broadcast();
      addTearDown(controller.close);
      await _pumpNavigation(tester, events: controller.stream, auth: auth);

      controller.add(
        const SyncUiEvent(type: SyncUiEventType.resumed, ownerUid: 'user-a'),
      );
      await Future<void>.value();
      auth.user = _FirebaseUser('user-b');
      await tester.pumpAndSettle();

      expect(find.byType(SnackBar), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('preserva cinco destinos e opções do menu superior', (
    tester,
  ) async {
    await _pumpNavigation(tester);
    expect(find.byType(SnackBar), findsNothing);

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
    final router = await _pumpNavigation(tester);
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
    expect(find.byType(SnackBar), findsNothing);
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
