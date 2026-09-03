import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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

  @override
  Future<void> logout() async {
    logoutCalls += 1;
    state = AuthState.unauthenticated();
  }
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
}) {
  return ProviderScope(
    overrides: [
      authNotifierProvider.overrideWith(() => _StaticAuthNotifier(authState)),
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
