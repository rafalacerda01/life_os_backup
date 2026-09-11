import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:life_os/features/auth/domain/entities/user_entity.dart';
import 'package:life_os/features/auth/presentation/providers/auth_provider.dart';
import 'package:life_os/features/auth/presentation/providers/auth_state.dart';
import 'package:life_os/features/onboarding/presentation/onboarding_provider.dart';
import 'package:life_os/features/onboarding/presentation/splash_screen.dart';

class _TestAuthNotifier extends AuthNotifier {
  _TestAuthNotifier(this.initialState, {this.checkCurrentUserOperation});

  final AuthState initialState;
  final Future<void> Function()? checkCurrentUserOperation;
  int checkCurrentUserCalls = 0;

  @override
  AuthState build() => initialState;

  void emit(AuthState next) => state = next;

  @override
  Future<void> checkCurrentUser() async {
    checkCurrentUserCalls++;
    await checkCurrentUserOperation?.call();
  }
}

class _TestOnboardingStore implements OnboardingCompletionStore {
  _TestOnboardingStore({this.completed = false, this.readOperation});

  bool completed;
  final Future<bool> Function()? readOperation;

  @override
  Future<bool> hasCompleted() {
    return readOperation?.call() ?? Future<bool>.value(completed);
  }

  @override
  Future<void> markCompleted() async {
    completed = true;
  }
}

const _user = UserEntity(
  uid: 'user-a',
  email: 'user@example.com',
  displayName: 'User',
  isPremium: false,
  xp: 0,
  level: 1,
  streak: 0,
);

void main() {
  Future<({ProviderContainer container, GoRouter router})> pumpSplash(
    WidgetTester tester, {
    required AuthState authState,
    required OnboardingCompletionStore store,
    Future<void> Function()? checkCurrentUserOperation,
    void Function()? onHomeBuild,
    void Function()? onOnboardingBuild,
  }) async {
    final container = ProviderContainer(
      overrides: [
        authNotifierProvider.overrideWith(
          () => _TestAuthNotifier(
            authState,
            checkCurrentUserOperation: checkCurrentUserOperation,
          ),
        ),
        onboardingCompletionStoreProvider.overrideWithValue(store),
      ],
    );
    final router = GoRouter(
      initialLocation: '/splash',
      routes: [
        GoRoute(path: '/splash', builder: (_, _) => const SplashScreen()),
        GoRoute(
          path: '/home',
          builder: (_, _) {
            onHomeBuild?.call();
            return const Text('Home');
          },
        ),
        GoRoute(
          path: '/onboarding',
          builder: (_, _) {
            onOnboardingBuild?.call();
            return const Text('Onboarding');
          },
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
    return (container: container, router: router);
  }

  Future<void> flushBootstrap(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
  }

  testWidgets('usuário autenticado segue para home sem aguardar flag local', (
    tester,
  ) async {
    final pendingRead = Completer<bool>();
    final harness = await pumpSplash(
      tester,
      authState: AuthState.authenticated(_user),
      store: _TestOnboardingStore(readOperation: () => pendingRead.future),
    );

    await flushBootstrap(tester);

    expect(harness.router.state.uri.path, '/home');
  });

  testWidgets('primeira execução deslogada segue para onboarding sem delay', (
    tester,
  ) async {
    final harness = await pumpSplash(
      tester,
      authState: AuthState.unauthenticated(),
      store: _TestOnboardingStore(),
    );

    await flushBootstrap(tester);

    expect(harness.router.state.uri.path, '/onboarding');
  });

  testWidgets('execução posterior deslogada segue para login', (tester) async {
    final harness = await pumpSplash(
      tester,
      authState: AuthState.unauthenticated(),
      store: _TestOnboardingStore(completed: true),
    );

    await flushBootstrap(tester);

    expect(harness.router.state.uri.path, '/login');
  });

  testWidgets('corrida entre flag e Auth navega uma vez para home', (
    tester,
  ) async {
    final readCompleter = Completer<bool>();
    var homeBuilds = 0;
    var onboardingBuilds = 0;
    final harness = await pumpSplash(
      tester,
      authState: AuthState.unauthenticated(),
      store: _TestOnboardingStore(readOperation: () => readCompleter.future),
      onHomeBuild: () => homeBuilds++,
      onOnboardingBuild: () => onboardingBuilds++,
    );

    readCompleter.complete(false);
    final notifier = harness.container.read(authNotifierProvider.notifier);
    (notifier as _TestAuthNotifier).emit(AuthState.authenticated(_user));
    await flushBootstrap(tester);
    await tester.pump(const Duration(milliseconds: 1));

    expect(harness.router.state.uri.path, '/home');
    expect(homeBuilds, 1);
    expect(onboardingBuilds, 0);
  });

  testWidgets('AuthError permanece opaco e retry não executa em paralelo', (
    tester,
  ) async {
    final retryCompleter = Completer<void>();
    const technicalMessage = 'technical-auth-session-isolation-error';
    final harness = await pumpSplash(
      tester,
      authState: AuthState.error(technicalMessage),
      store: _TestOnboardingStore(),
      checkCurrentUserOperation: () => retryCompleter.future,
    );

    await flushBootstrap(tester);

    expect(harness.router.state.uri.path, '/splash');
    expect(find.text('Home'), findsNothing);
    expect(find.text('Login'), findsNothing);
    expect(find.text('Onboarding'), findsNothing);
    expect(find.text('Não foi possível iniciar sua sessão.'), findsOneWidget);
    expect(find.text(technicalMessage), findsNothing);
    expect(find.text('Tentar novamente'), findsOneWidget);

    await tester.tap(find.text('Tentar novamente'));
    await tester.tap(find.byType(FilledButton));
    await tester.pump();

    final notifier = harness.container.read(authNotifierProvider.notifier);
    expect((notifier as _TestAuthNotifier).checkCurrentUserCalls, 1);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    retryCompleter.complete();
    await tester.pump();
  });
}
