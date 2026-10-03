import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:life_os/core/router/router.dart';
import 'package:life_os/core/security/biometric_app_gate.dart';
import 'package:life_os/core/services/biometric_service.dart';
import 'package:life_os/core/services/sync_manager.dart';
import 'package:life_os/core/services/sync_manager_provider.dart';
import 'package:life_os/core/services/sync_ui_event.dart';
import 'package:life_os/features/auth/domain/entities/user_entity.dart';
import 'package:life_os/features/auth/presentation/providers/auth_provider.dart';
import 'package:life_os/features/auth/presentation/providers/auth_state.dart';
import 'package:life_os/features/onboarding/presentation/splash_screen.dart';
import 'package:life_os/features/settings/presentation/providers/biometric_provider.dart';
import 'package:life_os/features/settings/presentation/screens/privacy_policy_screen.dart';
import 'package:life_os/features/tasks/data/models/task_model.dart';
import 'package:life_os/features/tasks/presentation/providers/tasks_provider.dart';
import 'package:life_os/features/tasks/presentation/tasks_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _user = UserEntity(
  uid: 'user-a',
  email: 'user@example.invalid',
  displayName: 'User',
  isPremium: false,
  xp: 0,
  level: 1,
  streak: 0,
);

class _AuthNotifier extends AuthNotifier {
  _AuthNotifier(this.initial);

  final AuthState initial;

  @override
  AuthState build() => initial;

  void emit(AuthState next) => state = next;
}

class _FirebaseUser extends Fake implements User {
  @override
  String get uid => _user.uid;
}

class _FirebaseAuth extends Fake implements FirebaseAuth {
  _FirebaseAuth({required this.hasUser});

  final bool hasUser;

  @override
  User? get currentUser => hasUser ? _FirebaseUser() : null;
}

class _SyncManager extends Fake implements SyncManager {
  int calls = 0;

  @override
  Future<bool> processPendingItems() async {
    calls++;
    return false;
  }
}

class _BiometricService extends BiometricService {
  final result = Completer<bool>();
  int calls = 0;

  @override
  Future<bool> authenticate({String reason = ''}) {
    calls++;
    return result.future;
  }
}

class _Harness {
  _Harness(this.container, this.router, this.sync, this.biometrics);

  final ProviderContainer container;
  final GoRouter router;
  final _SyncManager sync;
  final _BiometricService biometrics;
  int taskSubscriptions = 0;

  Widget app({bool withGate = true}) => UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(
      routerConfig: router,
      builder: withGate
          ? (context, child) => BiometricAppGate(child: child!)
          : null,
    ),
  );

  static _Harness create({
    required AuthState authState,
    required bool hasFirebaseUser,
    required BiometricPreferencesLoader loadPreferences,
  }) {
    final sync = _SyncManager();
    final biometrics = _BiometricService();
    late final _Harness harness;
    final container = ProviderContainer(
      overrides: [
        authNotifierProvider.overrideWith(() => _AuthNotifier(authState)),
        firebaseAuthProvider.overrideWithValue(
          _FirebaseAuth(hasUser: hasFirebaseUser),
        ),
        biometricPreferencesLoaderProvider.overrideWithValue(loadPreferences),
        biometricServiceProvider.overrideWithValue(biometrics),
        syncManagerProvider.overrideWithValue(sync),
        syncUiEventsProvider.overrideWith(
          (_) => const Stream<SyncUiEvent>.empty(),
        ),
        tasksStreamProvider.overrideWith((_) {
          harness.taskSubscriptions++;
          return Stream.value(<TaskModel>[]);
        }),
      ],
    );
    harness = _Harness(
      container,
      container.read(routerProvider),
      sync,
      biometrics,
    );
    return harness;
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> flush(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
  }

  void registerCleanup(WidgetTester tester, _Harness harness) {
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      harness.router.dispose();
      harness.container.dispose();
    });
  }

  for (final authState in [const AuthInitial(), const AuthLoading()]) {
    testWidgets(
      'platform /tasks stays private during ${authState.runtimeType}',
      (tester) async {
        tester.binding.platformDispatcher.defaultRouteNameTestValue = '/tasks';
        addTearDown(
          tester.binding.platformDispatcher.clearDefaultRouteNameTestValue,
        );
        final preferences = Completer<SharedPreferences>();
        final harness = _Harness.create(
          authState: authState,
          hasFirebaseUser: true,
          loadPreferences: () => preferences.future,
        );
        registerCleanup(tester, harness);
        expect(
          harness.router.routeInformationProvider.value.uri.path,
          '/tasks',
        );

        // Exercise router admission independently of the AppLock defense.
        await tester.pumpWidget(harness.app(withGate: false));
        await flush(tester);
        expect(harness.router.state.uri.path, '/splash');
        expect(find.byType(SplashScreen), findsOneWidget);
        expect(find.byType(TasksScreen), findsNothing);
        expect(harness.taskSubscriptions, 0);
        expect(harness.sync.calls, 0);

        await tester.pumpWidget(harness.app());
        await flush(tester);
        expect(find.byType(TasksScreen), findsNothing);
        expect(find.text('Protegendo sua sessão...'), findsOneWidget);

        final auth =
            harness.container.read(authNotifierProvider.notifier)
                as _AuthNotifier;
        auth.emit(const AuthAuthenticated(_user));
        harness.router.go('/tasks');
        await flush(tester);
        expect(find.byType(TasksScreen), findsNothing);
        expect(harness.taskSubscriptions, 0);
        expect(harness.biometrics.calls, 0);

        SharedPreferences.setMockInitialValues({
          BiometricNotifier.storageKey: true,
        });
        preferences.complete(await SharedPreferences.getInstance());
        await flush(tester);
        expect(find.text('Life OS bloqueado'), findsOneWidget);
        expect(find.byType(TasksScreen), findsNothing);
        expect(harness.taskSubscriptions, 0);
        expect(harness.biometrics.calls, 1);

        harness.biometrics.result.complete(true);
        await tester.pumpAndSettle();
        expect(harness.router.state.uri.path, '/tasks');
        expect(find.byType(TasksScreen), findsOneWidget);
        expect(harness.taskSubscriptions, 1);
        expect(harness.sync.calls, 1);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('platform public policy survives ${authState.runtimeType}', (
      tester,
    ) async {
      tester.binding.platformDispatcher.defaultRouteNameTestValue =
          '/privacy-policy';
      addTearDown(
        tester.binding.platformDispatcher.clearDefaultRouteNameTestValue,
      );
      final harness = _Harness.create(
        authState: authState,
        hasFirebaseUser: false,
        loadPreferences: SharedPreferences.getInstance,
      );
      registerCleanup(tester, harness);
      await tester.pumpWidget(harness.app());
      await tester.pumpAndSettle();
      expect(harness.router.state.uri.path, '/privacy-policy');
      expect(find.byType(PrivacyPolicyScreen), findsOneWidget);
      expect(find.byType(TasksScreen), findsNothing);
      expect(harness.biometrics.calls, 0);
      expect(harness.sync.calls, 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('authorized platform /tasks is preserved behind AppLock', (
    tester,
  ) async {
    tester.binding.platformDispatcher.defaultRouteNameTestValue = '/tasks';
    addTearDown(
      tester.binding.platformDispatcher.clearDefaultRouteNameTestValue,
    );
    SharedPreferences.setMockInitialValues({
      BiometricNotifier.storageKey: true,
    });
    final harness = _Harness.create(
      authState: const AuthAuthenticated(_user),
      hasFirebaseUser: true,
      loadPreferences: SharedPreferences.getInstance,
    );
    registerCleanup(tester, harness);
    await tester.pumpWidget(harness.app());
    await flush(tester);
    expect(find.byType(TasksScreen), findsNothing);
    expect(harness.taskSubscriptions, 0);
    expect(harness.biometrics.calls, 1);
    harness.biometrics.result.complete(true);
    await tester.pumpAndSettle();
    expect(harness.router.state.uri.path, '/tasks');
    expect(find.byType(TasksScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
