import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:life_os/core/errors/failure.dart';
import 'package:life_os/core/router/router.dart';
import 'package:life_os/core/security/biometric_app_gate.dart';
import 'package:life_os/core/services/analytics_service.dart';
import 'package:life_os/core/services/biometric_service.dart';
import 'package:life_os/features/auth/domain/entities/user_entity.dart';
import 'package:life_os/features/auth/domain/repositories/auth_repository.dart';
import 'package:life_os/features/auth/presentation/providers/auth_provider.dart';
import 'package:life_os/features/auth/presentation/providers/auth_state.dart';
import 'package:life_os/features/auth/presentation/screens/login_screen.dart';
import 'package:life_os/features/auth/presentation/screens/register_screen.dart';
import 'package:life_os/features/settings/presentation/providers/analytics_provider.dart';
import 'package:life_os/features/settings/presentation/providers/biometric_provider.dart';
import 'package:multiple_result/multiple_result.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../helpers/recording_analytics_platform.dart';

const _message = 'Não foi possível entrar. Tente novamente.';

class _FirebaseAuth extends Fake implements FirebaseAuth {
  @override
  User? get currentUser => null;

  @override
  Stream<User?> authStateChanges() => const Stream<User?>.empty();
}

class _Repository extends Fake implements AuthRepository {
  int loginCalls = 0;
  int registerCalls = 0;
  int googleCalls = 0;
  int resetCalls = 0;
  Completer<Result<UserEntity, Failure>>? pendingLogin;

  @override
  Future<Result<UserEntity, Failure>> getCurrentUser() =>
      Completer<Result<UserEntity, Failure>>().future;

  @override
  Future<Result<UserEntity, Failure>> signInWithEmailAndPassword(
    String email,
    String password,
  ) async {
    loginCalls++;
    return pendingLogin?.future ?? const Error(AuthFailure(_message));
  }

  @override
  Future<Result<UserEntity, Failure>> signUpWithEmailAndPassword(
    String email,
    String password,
    String name,
  ) async {
    registerCalls++;
    return const Error(AuthFailure(_message));
  }

  @override
  Future<Result<UserEntity, Failure>> signInWithGoogle() async {
    googleCalls++;
    return const Error(AuthFailure(_message, code: 'GOOGLE_SIGN_IN_CANCELLED'));
  }

  @override
  Future<Result<void, Failure>> sendPasswordResetEmail(String email) async {
    resetCalls++;
    return const Error(AuthFailure(_message));
  }
}

class _Biometrics extends BiometricService {
  int calls = 0;

  @override
  Future<bool> authenticate({String reason = ''}) async {
    calls++;
    return false;
  }
}

Future<ProviderContainer> _pumpPublicApp(
  WidgetTester tester,
  _Repository repository,
  _Biometrics biometrics, {
  String location = '/login',
}) async {
  final refresh = ChangeNotifier();
  late final ProviderContainer container;
  final router = GoRouter(
    initialLocation: location,
    refreshListenable: refresh,
    redirect: (_, state) => authRedirectFor(
      authState: container.read(authNotifierProvider),
      hasFirebaseUser: false,
      location: state.matchedLocation,
    ),
    routes: [
      GoRoute(path: '/login', builder: (_, _) => const LoginScreen()),
      GoRoute(path: '/register', builder: (_, _) => const RegisterScreen()),
      GoRoute(
        path: '/splash',
        builder: (_, _) => const Scaffold(body: Text('Splash')),
      ),
    ],
  );
  container = ProviderContainer(
    overrides: [
      firebaseAuthProvider.overrideWithValue(_FirebaseAuth()),
      authRepositoryProvider.overrideWithValue(repository),
      analyticsServiceProvider.overrideWithValue(
        AnalyticsService(platform: RecordingAnalyticsPlatform()),
      ),
      biometricServiceProvider.overrideWithValue(biometrics),
      routerProvider.overrideWithValue(router),
    ],
  );
  final subscription = container.listen(
    authNotifierProvider,
    (_, _) => refresh.notifyListeners(),
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    subscription.close();
    container.dispose();
    router.dispose();
    refresh.dispose();
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        builder: (_, child) => BiometricAppGate(child: child!),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void _expectPublicRecovery(
  WidgetTester tester,
  ProviderContainer container,
  _Biometrics biometrics,
) {
  expect(
    (container.read(authNotifierProvider) as AuthError).scope,
    AuthErrorScope.publicEntry,
  );
  expect(find.text('Protegendo sua sessão...'), findsNothing);
  expect(find.text('Life OS bloqueado'), findsNothing);
  expect(find.text(_message), findsOneWidget);
  expect(biometrics.calls, 0);
  expect(tester.takeException(), isNull);
}

void main() {
  setUp(
    () => SharedPreferences.setMockInitialValues({
      BiometricNotifier.storageKey: true,
    }),
  );

  testWidgets(
    'public login failure keeps fields and retry available behind enabled biometrics',
    (tester) async {
      final repository = _Repository();
      final biometrics = _Biometrics();
      final container = await _pumpPublicApp(tester, repository, biometrics);
      await tester.enterText(
        find.byType(TextFormField).at(0),
        'user@example.com',
      );
      await tester.enterText(find.byType(TextFormField).at(1), 'password123');
      await tester.tap(find.text('Acessar Sistema'));
      await tester.pumpAndSettle();

      _expectPublicRecovery(tester, container, biometrics);
      expect(repository.loginCalls, 1);
      expect(find.byType(LoginScreen), findsOneWidget);
      expect(
        tester.widget<TextFormField>(find.byType(TextFormField).at(0)).enabled,
        isTrue,
      );
      expect(
        tester
            .widget<ElevatedButton>(
              find.widgetWithText(ElevatedButton, 'Acessar Sistema'),
            )
            .onPressed,
        isNotNull,
      );

      repository.pendingLogin = Completer<Result<UserEntity, Failure>>();
      await tester.tap(find.text('Acessar Sistema'));
      await tester.pump();
      expect(container.read(authNotifierProvider), isA<AuthLoading>());
      expect(repository.loginCalls, 2);
      expect(find.byType(LoginScreen), findsOneWidget);
      expect(find.text('Protegendo sua sessão...'), findsNothing);
      repository.pendingLogin!.complete(const Error(AuthFailure(_message)));
      await tester.pumpAndSettle();
      expect(
        (container.read(authNotifierProvider) as AuthError).scope,
        AuthErrorScope.publicEntry,
      );
      expect(biometrics.calls, 0);
    },
  );

  testWidgets('public registration failure leaves registration usable', (
    tester,
  ) async {
    final repository = _Repository();
    final biometrics = _Biometrics();
    final container = await _pumpPublicApp(
      tester,
      repository,
      biometrics,
      location: '/register',
    );
    await tester.enterText(find.byType(TextFormField).at(0), 'Test User');
    await tester.enterText(
      find.byType(TextFormField).at(1),
      'user@example.com',
    );
    await tester.enterText(find.byType(TextFormField).at(2), 'password123');
    await tester.tap(find.text('Inicializar Conta'));
    await tester.pumpAndSettle();
    _expectPublicRecovery(tester, container, biometrics);
    expect(find.byType(RegisterScreen), findsOneWidget);
    expect(repository.registerCalls, 1);
    await tester.tap(find.text('Inicializar Conta'));
    await tester.pumpAndSettle();
    expect(repository.registerCalls, 2);
    expect(find.text('Protegendo sua sessão...'), findsNothing);
  });

  testWidgets(
    'public Google cancellation allows another attempt without biometric prompt',
    (tester) async {
      final repository = _Repository();
      final biometrics = _Biometrics();
      final container = await _pumpPublicApp(tester, repository, biometrics);
      await tester.tap(find.text('Continuar com o Google'));
      await tester.pumpAndSettle();
      _expectPublicRecovery(tester, container, biometrics);
      await tester.tap(find.text('Continuar com o Google'));
      await tester.pumpAndSettle();
      expect(repository.googleCalls, 2);
      expect(find.byType(LoginScreen), findsOneWidget);
      expect(biometrics.calls, 0);
    },
  );

  testWidgets('public reset failure preserves dialog and permits retry', (
    tester,
  ) async {
    final repository = _Repository();
    final biometrics = _Biometrics();
    final container = await _pumpPublicApp(tester, repository, biometrics);
    await tester.tap(find.text('Esqueceu a senha?'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.hintText == 'Seu e-mail',
      ),
      'user@example.com',
    );
    await tester.tap(find.text('Enviar'));
    await tester.pumpAndSettle();
    _expectPublicRecovery(tester, container, biometrics);
    expect(find.text('Recuperar senha'), findsOneWidget);
    await tester.tap(find.text('Enviar'));
    await tester.pumpAndSettle();
    expect(repository.resetCalls, 2);
    expect(find.text('Protegendo sua sessão...'), findsNothing);
  });
}
