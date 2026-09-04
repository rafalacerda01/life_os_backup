import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/errors/failure.dart';
import 'package:life_os/core/services/analytics_service.dart';
import 'package:life_os/core/services/sync_manager.dart';
import 'package:life_os/core/services/sync_manager_provider.dart';
import 'package:life_os/features/auth/data/local/auth_cleanup_barrier.dart';
import 'package:life_os/features/auth/domain/entities/user_entity.dart';
import 'package:life_os/features/auth/domain/repositories/auth_repository.dart';
import 'package:life_os/features/auth/presentation/providers/auth_provider.dart';
import 'package:life_os/features/auth/presentation/providers/auth_state.dart';
import 'package:life_os/features/health/services/cycle_reminder_action_coordinator.dart';
import 'package:life_os/features/health/services/cycle_reminder_session_reconciler.dart';
import 'package:life_os/features/settings/presentation/providers/analytics_provider.dart';
import 'package:multiple_result/multiple_result.dart';

import '../../../../helpers/recording_analytics_platform.dart';

const _user = UserEntity(
  uid: 'user-a',
  email: 'user@example.invalid',
  displayName: 'User',
  isPremium: false,
  xp: 0,
  level: 1,
  streak: 0,
);

class _FirebaseUser extends Fake implements User {
  @override
  String get uid => _user.uid;

  @override
  List<UserInfo> get providerData => const <UserInfo>[];

  @override
  Future<String?> getIdToken([bool forceRefresh = false]) async => 'token';
}

class _FirebaseAuth extends Fake implements FirebaseAuth {
  final StreamController<User?> _changes = StreamController<User?>.broadcast();
  User? user;

  @override
  User? get currentUser => user;

  @override
  Stream<User?> authStateChanges() => _changes.stream;

  Future<void> close() => _changes.close();
}

class _AuthRepository extends Fake implements AuthRepository {
  _AuthRepository(this.auth, {this.restoreSession = false});

  final _FirebaseAuth auth;
  final bool restoreSession;
  bool failLogin = false;
  bool failRegistration = false;
  bool failGoogle = false;

  @override
  Future<Result<UserEntity, Failure>> getCurrentUser() {
    if (restoreSession) return Future.value(const Success(_user));
    return Completer<Result<UserEntity, Failure>>().future;
  }

  @override
  Future<Result<UserEntity, Failure>> signInWithEmailAndPassword(
    String email,
    String password,
  ) async {
    if (failLogin) return const Error(AuthFailure('login failed'));
    auth.user = _FirebaseUser();
    return const Success(_user);
  }

  @override
  Future<Result<UserEntity, Failure>> signUpWithEmailAndPassword(
    String email,
    String password,
    String name,
  ) async {
    if (failRegistration) {
      return const Error(AuthFailure('registration failed'));
    }
    auth.user = _FirebaseUser();
    return const Success(_user);
  }

  @override
  Future<Result<UserEntity, Failure>> signInWithGoogle() async {
    if (failGoogle) return const Error(AuthFailure('google failed'));
    auth.user = _FirebaseUser();
    return const Success(_user);
  }
}

class _SecureStorage extends Fake implements FlutterSecureStorage {
  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {}
}

class _CleanupBarrier extends Fake implements AuthCleanupBarrier {
  @override
  Future<PendingAuthCleanup?> readPending() async => null;
}

class _SyncManager extends Fake implements SyncManager {
  @override
  Future<bool> processPendingItems() async => false;
}

class _ActionCoordinator extends Fake
    implements CycleReminderActionSessionCoordinator {
  @override
  Future<void> onSessionPrepared(String userId) async {}
}

class _SessionRestore extends Fake implements CycleReminderSessionRestore {
  @override
  Future<void> restoreForSession(String userId) async {}
}

class _Harness {
  _Harness({
    required this.auth,
    required this.repository,
    required this.analytics,
  }) : container = ProviderContainer(
         overrides: [
           firebaseAuthProvider.overrideWithValue(auth),
           authRepositoryProvider.overrideWithValue(repository),
           secureStorageProvider.overrideWithValue(_SecureStorage()),
           authCleanupBarrierProvider.overrideWithValue(_CleanupBarrier()),
           syncManagerProvider.overrideWithValue(_SyncManager()),
           cycleReminderActionCoordinatorProvider.overrideWithValue(
             _ActionCoordinator(),
           ),
           cycleReminderSessionReconcilerProvider.overrideWithValue(
             _SessionRestore(),
           ),
           analyticsServiceProvider.overrideWithValue(
             AnalyticsService(platform: analytics),
           ),
         ],
       );

  final _FirebaseAuth auth;
  final _AuthRepository repository;
  final RecordingAnalyticsPlatform analytics;
  final ProviderContainer container;

  AuthNotifier get notifier => container.read(authNotifierProvider.notifier);
  AuthState get state => container.read(authNotifierProvider);

  void dispose() {
    container.dispose();
    unawaited(auth.close());
  }
}

_Harness _harness({bool restoreSession = false}) {
  final auth = _FirebaseAuth();
  if (restoreSession) auth.user = _FirebaseUser();
  final analytics = RecordingAnalyticsPlatform();
  final harness = _Harness(
    auth: auth,
    repository: _AuthRepository(auth, restoreSession: restoreSession),
    analytics: analytics,
  );
  addTearDown(harness.dispose);
  return harness;
}

void main() {
  test('explicit email login records exactly one event', () async {
    final harness = _harness();

    await harness.notifier.login('user@example.invalid', 'password');

    expect(harness.state, isA<AuthAuthenticated>());
    expect(harness.analytics.events, <RecordedAnalyticsEvent>[
      const RecordedAnalyticsEvent('login', {'method': 'email'}),
    ]);
  });

  test('explicit Google login records exactly one event', () async {
    final harness = _harness();

    await harness.notifier.signInWithGoogle();

    expect(harness.state, isA<AuthAuthenticated>());
    expect(harness.analytics.events, <RecordedAnalyticsEvent>[
      const RecordedAnalyticsEvent('login', {'method': 'google'}),
    ]);
  });

  test('email registration records exactly one event', () async {
    final harness = _harness();

    await harness.notifier.register('user@example.invalid', 'password', 'User');

    expect(harness.state, isA<AuthAuthenticated>());
    expect(harness.analytics.events, <RecordedAnalyticsEvent>[
      const RecordedAnalyticsEvent('sign_up', {'method': 'email'}),
    ]);
  });

  test('restored session records no login event', () async {
    final harness = _harness(restoreSession: true);

    harness.container.read(authNotifierProvider);
    await pumpEventQueue(times: 20);

    expect(harness.state, isA<AuthAuthenticated>());
    expect(harness.analytics.events, isEmpty);
  });

  test('failed login and registration record no events', () async {
    final harness = _harness();
    harness.repository.failLogin = true;

    await harness.notifier.login('user@example.invalid', 'bad-password');

    expect(harness.state, isA<AuthError>());
    expect(harness.analytics.events, isEmpty);

    harness.repository.failRegistration = true;
    await harness.notifier.register(
      'user@example.invalid',
      'bad-password',
      'User',
    );

    expect(harness.state, isA<AuthError>());
    expect(harness.analytics.events, isEmpty);
  });

  test('failed Google login records no events', () async {
    final harness = _harness();
    harness.repository.failGoogle = true;

    await harness.notifier.signInWithGoogle();

    expect(harness.state, isA<AuthError>());
    expect(harness.analytics.events, isEmpty);
  });

  test('Analytics failure does not break successful login', () async {
    final harness = _harness();
    harness.analytics.throwOnEvent = true;

    await expectLater(
      harness.notifier.login('user@example.invalid', 'password'),
      completes,
    );

    expect(harness.state, isA<AuthAuthenticated>());
  });

  test('Analytics failure does not break successful registration', () async {
    final harness = _harness();
    harness.analytics.throwOnEvent = true;

    await expectLater(
      harness.notifier.register('user@example.invalid', 'password', 'User'),
      completes,
    );

    expect(harness.state, isA<AuthAuthenticated>());
  });
}
