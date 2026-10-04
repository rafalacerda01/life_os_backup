import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:life_os/core/router/router.dart';
import 'package:life_os/core/security/biometric_app_gate.dart';
import 'package:life_os/core/services/biometric_service.dart';
import 'package:life_os/features/auth/domain/entities/user_entity.dart';
import 'package:life_os/features/auth/presentation/providers/auth_provider.dart';
import 'package:life_os/features/auth/presentation/providers/auth_state.dart';
import 'package:life_os/features/settings/presentation/providers/biometric_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _user = UserEntity(
  uid: 'test-user',
  email: 'test@example.invalid',
  displayName: 'Test',
  isPremium: false,
  xp: 0,
  level: 1,
  streak: 0,
);

class _StaticAuthNotifier extends AuthNotifier {
  _StaticAuthNotifier(this.initialState);

  final AuthState initialState;
  int logoutCalls = 0;

  @override
  AuthState build() => initialState;

  void emit(AuthState next) => state = next;

  @override
  Future<void> logout() async {
    logoutCalls += 1;
    state = AuthState.unauthenticated();
  }
}

class _FirebaseUser extends Fake implements User {
  _FirebaseUser(this.uid);

  @override
  final String uid;
}

class _FirebaseAuth extends Fake implements FirebaseAuth {
  _FirebaseAuth({required this.hasUser});

  bool hasUser;
  String uid = 'test-user';

  @override
  User? get currentUser => hasUser ? _FirebaseUser(uid) : null;
}

class _FakeBiometricService extends BiometricService {
  final List<bool> results = [];
  Completer<bool>? pending;
  int calls = 0;

  @override
  Future<bool> authenticate({String reason = ''}) {
    calls += 1;
    if (pending case final value?) return value.future;
    return Future.value(results.isEmpty ? false : results.removeAt(0));
  }
}

Widget _app({
  required AuthState authState,
  required _FakeBiometricService service,
  BiometricPreferencesLoader? preferencesLoader,
  bool? hasFirebaseUser,
  FirebaseAuth? firebaseAuth,
}) {
  return ProviderScope(
    overrides: [
      authNotifierProvider.overrideWith(() => _StaticAuthNotifier(authState)),
      firebaseAuthProvider.overrideWithValue(
        firebaseAuth ??
            _FirebaseAuth(
              hasUser: hasFirebaseUser ?? authState is AuthAuthenticated,
            ),
      ),
      biometricServiceProvider.overrideWithValue(service),
      if (preferencesLoader != null)
        biometricPreferencesLoaderProvider.overrideWithValue(preferencesLoader),
    ],
    child: const MaterialApp(
      home: BiometricAppGate(
        child: Scaffold(body: Text('Sensitive router content')),
      ),
    ),
  );
}

Future<void> _pumpAsync(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  tearDown(() {
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
  });

  testWidgets('public error metadata cannot unlock Firebase preparation', (
    tester,
  ) async {
    final service = _FakeBiometricService();
    await tester.pumpWidget(
      _app(
        authState: const AuthError(
          'Mensagem segura',
          scope: AuthErrorScope.publicEntry,
        ),
        hasFirebaseUser: true,
        service: service,
      ),
    );
    await _pumpAsync(tester);
    expect(find.text('Sensitive router content'), findsNothing);
    expect(find.text('Protegendo sua sessão...'), findsOneWidget);
    expect(service.calls, 0);
  });

  testWidgets(
    'public error cannot reveal a previously confirmed session after UID loss',
    (tester) async {
      final service = _FakeBiometricService();
      final auth = _FirebaseAuth(hasUser: true);
      await tester.pumpWidget(
        _app(
          authState: const AuthAuthenticated(_user),
          firebaseAuth: auth,
          service: service,
        ),
      );
      await _pumpAsync(tester);
      expect(find.text('Sensitive router content'), findsOneWidget);
      final context = tester.element(find.byType(BiometricAppGate));
      final container = ProviderScope.containerOf(context);
      auth.hasUser = false;
      (container.read(authNotifierProvider.notifier) as _StaticAuthNotifier)
          .emit(
            const AuthError(
              'Mensagem segura',
              scope: AuthErrorScope.publicEntry,
            ),
          );
      await tester.pump();
      expect(find.text('Sensitive router content'), findsNothing);
      expect(find.text('Protegendo sua sessão...'), findsOneWidget);
      expect(service.calls, 0);
    },
  );

  testWidgets(
    'public error stays opaque until stale private route finishes redirecting',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        BiometricNotifier.storageKey: true,
      });
      final service = _FakeBiometricService();
      final notifier = _StaticAuthNotifier(const AuthInitial());
      final redirect = Completer<String?>();
      var holdRedirect = false;
      final router = GoRouter(
        initialLocation: '/home',
        redirect: (_, _) => holdRedirect ? redirect.future : null,
        routes: [
          GoRoute(
            path: '/home',
            builder: (_, _) =>
                const Scaffold(body: Text('Sensitive router content')),
          ),
          GoRoute(
            path: '/login',
            builder: (_, _) => const Scaffold(body: Text('Public login')),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authNotifierProvider.overrideWith(() => notifier),
            firebaseAuthProvider.overrideWithValue(
              _FirebaseAuth(hasUser: false),
            ),
            biometricServiceProvider.overrideWithValue(service),
            routerProvider.overrideWithValue(router),
          ],
          child: MaterialApp.router(
            routerConfig: router,
            builder: (_, child) => BiometricAppGate(child: child!),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(router.routerDelegate.currentConfiguration.uri.path, '/home');
      holdRedirect = true;
      notifier.emit(
        const AuthError('Mensagem segura', scope: AuthErrorScope.publicEntry),
      );
      router.go('/login');
      for (var frame = 0; frame < 3; frame++) {
        await tester.pump();
        expect(find.text('Sensitive router content'), findsNothing);
        expect(find.text('Public login'), findsNothing);
        expect(find.text('Protegendo sua sessão...'), findsOneWidget);
        expect(router.routerDelegate.currentConfiguration.uri.path, '/home');
      }
      holdRedirect = false;
      redirect.complete(null);
      await tester.pumpAndSettle();
      expect(find.text('Public login'), findsOneWidget);
      expect(find.text('Sensitive router content'), findsNothing);
      expect(find.text('Protegendo sua sessão...'), findsNothing);
      expect(service.calls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  for (final authState in [const AuthInitial(), const AuthLoading()]) {
    testWidgets('${authState.runtimeType} with restored UID stays opaque', (
      tester,
    ) async {
      final service = _FakeBiometricService();
      await tester.pumpWidget(
        _app(authState: authState, hasFirebaseUser: true, service: service),
      );
      await _pumpAsync(tester);
      expect(find.text('Sensitive router content'), findsNothing);
      expect(find.text('Protegendo sua sessão...'), findsOneWidget);
      expect(service.calls, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('${authState.runtimeType} without Firebase keeps public flow', (
      tester,
    ) async {
      final service = _FakeBiometricService();
      await tester.pumpWidget(
        _app(authState: authState, hasFirebaseUser: false, service: service),
      );
      await _pumpAsync(tester);
      expect(find.text('Sensitive router content'), findsOneWidget);
      expect(service.calls, 0);
    });
  }

  testWidgets('cold AuthError with restored UID remains opaque', (
    tester,
  ) async {
    final service = _FakeBiometricService();
    await tester.pumpWidget(
      _app(
        authState: const AuthError('technical-preparation-error'),
        hasFirebaseUser: true,
        service: service,
      ),
    );
    await _pumpAsync(tester);
    expect(find.text('Sensitive router content'), findsNothing);
    expect(find.text('Protegendo sua sessão...'), findsOneWidget);
    expect(find.textContaining('technical-preparation-error'), findsNothing);
    expect(find.text('Tentar novamente'), findsNothing);
    expect(find.text('Encerrar sessão'), findsOneWidget);
    expect(service.calls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unauthenticated flow is visible and never prompts biometrics', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      BiometricNotifier.storageKey: true,
    });
    final service = _FakeBiometricService();
    await tester.pumpWidget(
      _app(authState: AuthState.unauthenticated(), service: service),
    );
    await _pumpAsync(tester);

    expect(find.text('Sensitive router content'), findsOneWidget);
    expect(service.calls, 0);
  });

  testWidgets('AuthError sem sessão Firebase mantém conteúdo privado opaco', (
    tester,
  ) async {
    final service = _FakeBiometricService();
    await tester.pumpWidget(
      _app(
        authState: AuthState.error('technical-isolation-marker'),
        hasFirebaseUser: false,
        service: service,
      ),
    );
    await _pumpAsync(tester);

    expect(find.text('Protegendo sua sessão...'), findsOneWidget);
    expect(find.text('Sensitive router content'), findsNothing);
    expect(find.text('Encerrar sessão'), findsOneWidget);
    expect(find.textContaining('technical-isolation-marker'), findsNothing);
    expect(service.calls, 0);
  });

  testWidgets('AuthError com sessão Firebase preserva conteúdo autenticado', (
    tester,
  ) async {
    final service = _FakeBiometricService();
    await tester.pumpWidget(
      _app(
        authState: AuthState.authenticated(_user),
        hasFirebaseUser: true,
        service: service,
      ),
    );
    await _pumpAsync(tester);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(BiometricAppGate)),
    );
    (container.read(authNotifierProvider.notifier) as _StaticAuthNotifier).emit(
      const AuthError('recoverable-operation-error'),
    );
    await _pumpAsync(tester);

    expect(find.text('Sensitive router content'), findsOneWidget);
    expect(service.calls, 0);
  });

  testWidgets('post-auth error cannot retain a different Firebase UID', (
    tester,
  ) async {
    final auth = _FirebaseAuth(hasUser: true);
    final service = _FakeBiometricService();
    await tester.pumpWidget(
      _app(
        authState: const AuthAuthenticated(_user),
        firebaseAuth: auth,
        service: service,
      ),
    );
    await _pumpAsync(tester);
    expect(find.text('Sensitive router content'), findsOneWidget);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(BiometricAppGate)),
    );
    auth.uid = 'other-user';
    (container.read(authNotifierProvider.notifier) as _StaticAuthNotifier).emit(
      const AuthError('recoverable-operation-error'),
    );
    await _pumpAsync(tester);
    expect(find.text('Sensitive router content'), findsNothing);
    expect(service.calls, 0);
  });

  testWidgets('loading after authenticated stays opaque until resolved', (
    tester,
  ) async {
    final service = _FakeBiometricService();
    await tester.pumpWidget(
      _app(authState: const AuthAuthenticated(_user), service: service),
    );
    await _pumpAsync(tester);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(BiometricAppGate)),
    );
    final notifier =
        container.read(authNotifierProvider.notifier) as _StaticAuthNotifier;
    notifier.emit(const AuthLoading());
    await _pumpAsync(tester);
    expect(find.text('Sensitive router content'), findsNothing);
    notifier.emit(const AuthUnauthenticated());
    await _pumpAsync(tester);
    expect(find.text('Sensitive router content'), findsOneWidget);
    expect(service.calls, 0);
  });

  testWidgets('recoverable same-UID error still locks on background', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      BiometricNotifier.storageKey: true,
    });
    final service = _FakeBiometricService()..results.add(true);
    await tester.pumpWidget(
      _app(authState: const AuthAuthenticated(_user), service: service),
    );
    await _pumpAsync(tester);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(BiometricAppGate)),
    );
    (container.read(authNotifierProvider.notifier) as _StaticAuthNotifier).emit(
      const AuthError('recoverable-operation-error'),
    );
    await _pumpAsync(tester);
    expect(find.text('Sensitive router content'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await _pumpAsync(tester);
    expect(find.text('Sensitive router content'), findsNothing);
    expect(container.read(biometricProvider).isLocked, isTrue);
    service.results.add(true);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _pumpAsync(tester);
    expect(service.calls, 2);
    expect(find.text('Sensitive router content'), findsOneWidget);
  });

  for (final resolvedState in [
    const AuthError('recoverable-operation-error'),
    const AuthAuthenticated(_user),
  ]) {
    testWidgets(
      'background during AuthLoading requires new unlock before $resolvedState',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          BiometricNotifier.storageKey: true,
        });
        final service = _FakeBiometricService()..results.add(true);
        await tester.pumpWidget(
          _app(authState: const AuthAuthenticated(_user), service: service),
        );
        await _pumpAsync(tester);
        final container = ProviderScope.containerOf(
          tester.element(find.byType(BiometricAppGate)),
        );
        final notifier =
            container.read(authNotifierProvider.notifier)
                as _StaticAuthNotifier;
        expect(service.calls, 1);
        expect(find.text('Sensitive router content'), findsOneWidget);

        notifier.emit(const AuthLoading());
        await _pumpAsync(tester);
        expect(find.text('Sensitive router content'), findsNothing);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await _pumpAsync(tester);
        expect(container.read(biometricProvider).isLocked, isTrue);

        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await _pumpAsync(tester);
        expect(find.text('Sensitive router content'), findsNothing);
        expect(service.calls, 1);

        final pending = Completer<bool>();
        service.pending = pending;
        notifier.emit(resolvedState);
        await _pumpAsync(tester);
        expect(service.calls, 2);
        expect(container.read(biometricProvider).isLocked, isTrue);
        expect(find.text('Sensitive router content'), findsNothing);
        await tester.pump();
        expect(service.calls, 2);

        pending.complete(true);
        await _pumpAsync(tester);
        expect(find.text('Sensitive router content'), findsOneWidget);
        expect(service.calls, 2);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('failed unlock after AuthLoading does not loop prompts', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      BiometricNotifier.storageKey: true,
    });
    final service = _FakeBiometricService()
      ..results.addAll([true, false, true]);
    await tester.pumpWidget(
      _app(authState: const AuthAuthenticated(_user), service: service),
    );
    await _pumpAsync(tester);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(BiometricAppGate)),
    );
    final notifier =
        container.read(authNotifierProvider.notifier) as _StaticAuthNotifier;
    notifier.emit(const AuthLoading());
    await _pumpAsync(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _pumpAsync(tester);
    notifier.emit(const AuthAuthenticated(_user));
    await _pumpAsync(tester);
    expect(service.calls, 2);
    expect(container.read(biometricProvider).isLocked, isTrue);
    expect(find.text('Sensitive router content'), findsNothing);
    await _pumpAsync(tester);
    await _pumpAsync(tester);
    expect(service.calls, 2);
    await tester.tap(find.text('Tentar novamente'));
    await _pumpAsync(tester);
    expect(service.calls, 3);
    expect(find.text('Sensitive router content'), findsOneWidget);
  });

  for (final nextUid in ['other-user', null]) {
    testWidgets('AuthLoading does not retain confirmed session for $nextUid', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        BiometricNotifier.storageKey: true,
      });
      final auth = _FirebaseAuth(hasUser: true);
      final service = _FakeBiometricService()..results.add(true);
      await tester.pumpWidget(
        _app(
          authState: const AuthAuthenticated(_user),
          firebaseAuth: auth,
          service: service,
        ),
      );
      await _pumpAsync(tester);
      expect(find.text('Sensitive router content'), findsOneWidget);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(BiometricAppGate)),
      );
      final notifier =
          container.read(authNotifierProvider.notifier) as _StaticAuthNotifier;
      auth.hasUser = nextUid != null;
      if (nextUid != null) auth.uid = nextUid;
      notifier.emit(const AuthLoading());
      await _pumpAsync(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await _pumpAsync(tester);
      expect(
        container.read(biometricProvider).status,
        BiometricLockStatus.unlocked,
      );
      expect(find.text('Sensitive router content'), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      notifier.emit(const AuthError('recoverable-operation-error'));
      await _pumpAsync(tester);
      expect(find.text('Sensitive router content'), findsNothing);
      expect(service.calls, 1);
    });
  }

  testWidgets('authenticated preference loading is opaque and fail-closed', (
    tester,
  ) async {
    final preferences = Completer<SharedPreferences>();
    final service = _FakeBiometricService();
    await tester.pumpWidget(
      _app(
        authState: AuthState.authenticated(_user),
        service: service,
        preferencesLoader: () => preferences.future,
      ),
    );

    expect(find.text('Protegendo sua sessão...'), findsOneWidget);
    expect(find.text('Sensitive router content'), findsNothing);
    expect(service.calls, 0);
  });

  testWidgets(
    'preference load failure stays opaque but allows confirmed sign out',
    (tester) async {
      final service = _FakeBiometricService();
      await tester.pumpWidget(
        _app(
          authState: AuthState.authenticated(_user),
          service: service,
          preferencesLoader: () async =>
              throw StateError('private preference failure'),
        ),
      );
      await _pumpAsync(tester);

      expect(find.text('Protegendo sua sessão...'), findsOneWidget);
      expect(find.text('Sensitive router content'), findsNothing);
      expect(find.text('Tentar novamente'), findsNothing);
      expect(find.text('Encerrar sessão'), findsOneWidget);
      expect(find.textContaining('private preference failure'), findsNothing);
      expect(service.calls, 0);

      final container = ProviderScope.containerOf(
        tester.element(find.byType(BiometricAppGate)),
      );
      final authNotifier =
          container.read(authNotifierProvider.notifier) as _StaticAuthNotifier;

      await tester.tap(find.text('Encerrar sessão'));
      await _pumpAsync(tester);

      expect(authNotifier.logoutCalls, 1);
      expect(container.read(authNotifierProvider), isA<AuthUnauthenticated>());
      expect(find.text('Sensitive router content'), findsOneWidget);
      expect(find.textContaining('private preference failure'), findsNothing);
      expect(service.calls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'locked session stays opaque after failure and retry can unlock',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        BiometricNotifier.storageKey: true,
      });
      final service = _FakeBiometricService()..results.addAll([false, true]);
      await tester.pumpWidget(
        _app(authState: AuthState.authenticated(_user), service: service),
      );
      await _pumpAsync(tester);

      expect(service.calls, 1);
      expect(find.text('Life OS bloqueado'), findsOneWidget);
      expect(find.text('Sensitive router content'), findsNothing);

      await tester.tap(find.text('Tentar novamente'));
      await _pumpAsync(tester);
      expect(service.calls, 2);
      expect(find.text('Sensitive router content'), findsOneWidget);
    },
  );

  testWidgets('background locks and resume authenticates again', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      BiometricNotifier.storageKey: true,
    });
    final service = _FakeBiometricService()..results.addAll([true, true]);
    await tester.pumpWidget(
      _app(authState: AuthState.authenticated(_user), service: service),
    );
    await _pumpAsync(tester);
    expect(find.text('Sensitive router content'), findsOneWidget);
    expect(service.calls, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await _pumpAsync(tester);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(BiometricAppGate)),
    );
    expect(
      container.read(biometricProvider).status,
      BiometricLockStatus.locked,
    );
    expect(find.text('Life OS bloqueado'), findsOneWidget);
    expect(find.text('Sensitive router content'), findsNothing);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _pumpAsync(tester);
    expect(service.calls, 2);
    expect(find.text('Sensitive router content'), findsOneWidget);
  });

  testWidgets('rebuilds and resumes cannot start duplicate prompts', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      BiometricNotifier.storageKey: true,
    });
    final pending = Completer<bool>();
    final service = _FakeBiometricService()..pending = pending;
    await tester.pumpWidget(
      _app(authState: AuthState.authenticated(_user), service: service),
    );
    await _pumpAsync(tester);
    expect(service.calls, 1);

    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(service.calls, 1);
    expect(find.text('Sensitive router content'), findsNothing);

    pending.complete(true);
    await _pumpAsync(tester);
    expect(find.text('Sensitive router content'), findsOneWidget);
  });
}
