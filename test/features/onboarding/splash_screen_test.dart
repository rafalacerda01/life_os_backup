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

  testWidgets(
    'ícone oficial aparece com entrada curta sem loop durante loading',
    (tester) async {
      final harness = await pumpSplash(
        tester,
        authState: AuthState.loading(),
        store: _TestOnboardingStore(),
      );

      expect(find.byType(Image), findsOneWidget);
      final image = tester.widget<Image>(find.byType(Image));
      final assetName = (image.image as AssetImage).assetName;
      expect(assetName, 'assets/branding/life_os_mark.png');
      expect(assetName, isNot(contains('ios/Runner')));
      expect(assetName, isNot(contains('android/app/src/main/res')));
      expect(image.fit, BoxFit.contain);
      expect(image.semanticLabel, 'Life OS');
      expect(
        tester.getCenter(find.byType(Image)).dx,
        closeTo(
          tester.view.physicalSize.width / tester.view.devicePixelRatio / 2,
          0.01,
        ),
      );
      final fade = tester.widget<FadeTransition>(
        find
            .ancestor(
              of: find.byType(Image),
              matching: find.byType(FadeTransition),
            )
            .first,
      );
      final scale = tester.widget<ScaleTransition>(
        find
            .ancestor(
              of: find.byType(Image),
              matching: find.byType(ScaleTransition),
            )
            .first,
      );
      expect(fade.opacity.value, 0);
      expect(scale.scale.value, 0.96);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 649));
      expect(fade.opacity.value, lessThan(1));
      expect(scale.scale.value, lessThan(1));
      await tester.pump(const Duration(milliseconds: 1));
      expect(fade.opacity.value, 1);
      expect(scale.scale.value, 1);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      expect(fade.opacity.value, 1);
      expect(scale.scale.value, 1);
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(find.text('Seu sistema.\nSua vida.\nSeu melhor.'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is RichText && widget.text.toPlainText() == 'Life OS',
        ),
        findsOneWidget,
      );
      expect(harness.router.state.uri.path, '/splash');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('dispose durante entrada não deixa ticker ou frame ativo', (
    tester,
  ) async {
    await pumpSplash(
      tester,
      authState: AuthState.loading(),
      store: _TestOnboardingStore(),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));

    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('splash compacta preserva recuperação de erro sem overflow', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 480);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pumpSplash(
      tester,
      authState: AuthState.error('technical-error'),
      store: _TestOnboardingStore(),
    );

    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Tentar novamente'));
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('Não foi possível iniciar sua sessão.'), findsOneWidget);
    expect(find.text('technical-error'), findsNothing);
    expect(tester.takeException(), isNull);
  });

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
