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

const _userB = UserEntity(
  uid: 'user-b',
  email: 'user-b@example.invalid',
  displayName: 'User B',
  isPremium: false,
  xp: 0,
  level: 1,
  streak: 0,
);

class _FirebaseUser extends Fake implements User {
  _FirebaseUser(this.entity, {this.onGetIdToken});

  final UserEntity entity;
  final Future<void> Function()? onGetIdToken;

  @override
  String get uid => entity.uid;

  @override
  List<UserInfo> get providerData => const <UserInfo>[];

  @override
  Future<String?> getIdToken([bool forceRefresh = false]) async {
    await onGetIdToken?.call();
    return 'token';
  }
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
  UserEntity operationResult = _user;
  _FirebaseUser? operationFirebaseUser;
  Completer<Result<UserEntity, Failure>>? pendingCurrentUserResult;
  Completer<Result<UserEntity, Failure>>? pendingLoginResult;
  Completer<Result<UserEntity, Failure>>? pendingRegistrationResult;
  Completer<Result<UserEntity, Failure>>? pendingGoogleResult;
  final List<Result<UserEntity, Failure>> currentUserResults = [];
  Result<void, Failure> passwordResetResult = const Success(null);
  int passwordResetCalls = 0;

  @override
  Future<Result<UserEntity, Failure>> getCurrentUser() {
    final pendingResult = pendingCurrentUserResult;
    if (pendingResult != null) {
      pendingCurrentUserResult = null;
      return pendingResult.future;
    }
    if (currentUserResults.isNotEmpty) {
      return Future.value(currentUserResults.removeAt(0));
    }
    if (restoreSession) return Future.value(const Success(_user));
    return Completer<Result<UserEntity, Failure>>().future;
  }

  void _setOperationFirebaseUser() {
    auth.user = operationFirebaseUser ?? _FirebaseUser(operationResult);
  }

  @override
  Future<Result<UserEntity, Failure>> signInWithEmailAndPassword(
    String email,
    String password,
  ) async {
    final pendingResult = pendingLoginResult;
    if (pendingResult != null) {
      pendingLoginResult = null;
      return pendingResult.future;
    }
    if (failLogin) return const Error(AuthFailure('login failed'));
    _setOperationFirebaseUser();
    return Success(operationResult);
  }

  @override
  Future<Result<UserEntity, Failure>> signUpWithEmailAndPassword(
    String email,
    String password,
    String name,
  ) async {
    final pendingResult = pendingRegistrationResult;
    if (pendingResult != null) {
      pendingRegistrationResult = null;
      return pendingResult.future;
    }
    if (failRegistration) {
      return const Error(AuthFailure('registration failed'));
    }
    _setOperationFirebaseUser();
    return Success(operationResult);
  }

  @override
  Future<Result<UserEntity, Failure>> signInWithGoogle() async {
    final pendingResult = pendingGoogleResult;
    if (pendingResult != null) {
      pendingGoogleResult = null;
      return pendingResult.future;
    }
    if (failGoogle) return const Error(AuthFailure('google failed'));
    _setOperationFirebaseUser();
    return Success(operationResult);
  }

  @override
  Future<Result<void, Failure>> sendPasswordResetEmail(String email) async {
    passwordResetCalls += 1;
    return passwordResetResult;
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
  _SyncManager(this.auth);

  final _FirebaseAuth auth;
  final List<String?> processedUserIds = [];

  @override
  Future<bool> processPendingItems() async {
    processedUserIds.add(auth.currentUser?.uid);
    return false;
  }
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
    required this.syncManager,
  }) : container = ProviderContainer(
         overrides: [
           firebaseAuthProvider.overrideWithValue(auth),
           authRepositoryProvider.overrideWithValue(repository),
           secureStorageProvider.overrideWithValue(_SecureStorage()),
           authCleanupBarrierProvider.overrideWithValue(_CleanupBarrier()),
           syncManagerProvider.overrideWithValue(syncManager),
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
  final _SyncManager syncManager;
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
  if (restoreSession) auth.user = _FirebaseUser(_user);
  final analytics = RecordingAnalyticsPlatform();
  final syncManager = _SyncManager(auth);
  final harness = _Harness(
    auth: auth,
    repository: _AuthRepository(auth, restoreSession: restoreSession),
    analytics: analytics,
    syncManager: syncManager,
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

  group('binding entre resultado Auth e sessão Firebase', () {
    test('checkCurrentUser nunca publica A quando Firebase já é B', () async {
      final harness = _harness();
      harness.auth.user = _FirebaseUser(_userB);
      harness.repository.currentUserResults.addAll(const [
        Success(_user),
        Success(_userB),
      ]);

      harness.container.read(authNotifierProvider);
      await pumpEventQueue(times: 20);

      final state = harness.state;
      expect(state, isA<AuthAuthenticated>());
      expect((state as AuthAuthenticated).user.uid, 'user-b');
      expect(harness.syncManager.processedUserIds, <String?>['user-b']);
    });

    test('login antigo de A reconcilia B sem hidratar como A', () async {
      final harness = _harness();
      final notifier = harness.notifier;
      harness.repository.operationResult = _user;
      harness.repository.operationFirebaseUser = _FirebaseUser(_userB);
      harness.repository.currentUserResults.add(const Success(_userB));

      await notifier.login('user@example.invalid', 'password');
      await pumpEventQueue();

      final state = harness.state;
      expect(state, isA<AuthAuthenticated>());
      expect((state as AuthAuthenticated).user.uid, 'user-b');
      expect(harness.syncManager.processedUserIds, <String?>['user-b']);
      expect(harness.analytics.events, isEmpty);
    });

    test('cadastro antigo de A reconcilia B sem publicar A', () async {
      final harness = _harness();
      final notifier = harness.notifier;
      harness.repository.operationResult = _user;
      harness.repository.operationFirebaseUser = _FirebaseUser(_userB);
      harness.repository.currentUserResults.add(const Success(_userB));

      await notifier.register('user@example.invalid', 'password', 'User');
      await pumpEventQueue();

      final state = harness.state;
      expect(state, isA<AuthAuthenticated>());
      expect((state as AuthAuthenticated).user.uid, 'user-b');
      expect(harness.syncManager.processedUserIds, <String?>['user-b']);
      expect(harness.analytics.events, isEmpty);
    });

    test('Google Sign-In antigo de A reconcilia B sem publicar A', () async {
      final harness = _harness();
      final notifier = harness.notifier;
      harness.repository.operationResult = _user;
      harness.repository.operationFirebaseUser = _FirebaseUser(_userB);
      harness.repository.currentUserResults.add(const Success(_userB));

      await notifier.signInWithGoogle();
      await pumpEventQueue();

      final state = harness.state;
      expect(state, isA<AuthAuthenticated>());
      expect((state as AuthAuthenticated).user.uid, 'user-b');
      expect(harness.syncManager.processedUserIds, <String?>['user-b']);
      expect(harness.analytics.events, isEmpty);
    });

    test('sessão estável publica e hidrata o mesmo UID A', () async {
      final harness = _harness();

      await harness.notifier.login('user@example.invalid', 'password');
      await pumpEventQueue();

      final state = harness.state;
      expect(state, isA<AuthAuthenticated>());
      expect((state as AuthAuthenticated).user.uid, 'user-a');
      expect(harness.syncManager.processedUserIds, <String?>['user-a']);
    });

    test(
      'troca para B durante preparação impede publicação antiga de A',
      () async {
        final harness = _harness();
        final notifier = harness.notifier;
        harness.repository.operationResult = _user;
        harness.repository.operationFirebaseUser = _FirebaseUser(
          _user,
          onGetIdToken: () async {
            harness.auth.user = _FirebaseUser(_userB);
          },
        );
        harness.repository.currentUserResults.add(const Success(_userB));

        await notifier.login('user@example.invalid', 'password');
        await pumpEventQueue();

        final state = harness.state;
        expect(state, isA<AuthAuthenticated>());
        expect((state as AuthAuthenticated).user.uid, 'user-b');
        expect(harness.syncManager.processedUserIds, <String?>['user-b']);
        expect(harness.analytics.events, isEmpty);
      },
    );

    test('falha antiga de checkCurrentUser reconcilia sessão B', () async {
      final harness = _harness();
      final staleResult = Completer<Result<UserEntity, Failure>>();
      harness.repository.pendingCurrentUserResult = staleResult;

      harness.container.read(authNotifierProvider);
      harness.auth.user = _FirebaseUser(_userB);
      harness.repository.currentUserResults.add(const Success(_userB));
      staleResult.complete(const Error(AuthFailure('falha antiga de A')));
      await pumpEventQueue(times: 20);

      final state = harness.state;
      expect(state, isA<AuthAuthenticated>());
      expect((state as AuthAuthenticated).user.uid, 'user-b');
      expect(harness.syncManager.processedUserIds, <String?>['user-b']);
    });

    test('falha antiga de login reconcilia sessão B', () async {
      final harness = _harness();
      final notifier = harness.notifier;
      final staleResult = Completer<Result<UserEntity, Failure>>();
      harness.repository.pendingLoginResult = staleResult;

      final login = notifier.login('user@example.invalid', 'bad-password');
      harness.auth.user = _FirebaseUser(_userB);
      harness.repository.currentUserResults.add(const Success(_userB));
      staleResult.complete(const Error(AuthFailure('falha antiga de A')));

      await login;
      await pumpEventQueue();

      final state = harness.state;
      expect(state, isA<AuthAuthenticated>());
      expect((state as AuthAuthenticated).user.uid, 'user-b');
      expect(harness.syncManager.processedUserIds, <String?>['user-b']);
      expect(harness.analytics.events, isEmpty);
    });

    test('falha antiga de cadastro reconcilia sessão B', () async {
      final harness = _harness();
      final notifier = harness.notifier;
      final staleResult = Completer<Result<UserEntity, Failure>>();
      harness.repository.pendingRegistrationResult = staleResult;

      final registration = notifier.register(
        'user@example.invalid',
        'bad-password',
        'User',
      );
      harness.auth.user = _FirebaseUser(_userB);
      harness.repository.currentUserResults.add(const Success(_userB));
      staleResult.complete(const Error(AuthFailure('falha antiga de A')));

      await registration;
      await pumpEventQueue();

      final state = harness.state;
      expect(state, isA<AuthAuthenticated>());
      expect((state as AuthAuthenticated).user.uid, 'user-b');
      expect(harness.syncManager.processedUserIds, <String?>['user-b']);
      expect(harness.analytics.events, isEmpty);
    });

    test('falha antiga de Google Sign-In reconcilia sessão B', () async {
      final harness = _harness();
      final notifier = harness.notifier;
      final staleResult = Completer<Result<UserEntity, Failure>>();
      harness.repository.pendingGoogleResult = staleResult;

      final googleLogin = notifier.signInWithGoogle();
      harness.auth.user = _FirebaseUser(_userB);
      harness.repository.currentUserResults.add(const Success(_userB));
      staleResult.complete(const Error(AuthFailure('falha antiga de A')));

      await googleLogin;
      await pumpEventQueue();

      final state = harness.state;
      expect(state, isA<AuthAuthenticated>());
      expect((state as AuthAuthenticated).user.uid, 'user-b');
      expect(harness.syncManager.processedUserIds, <String?>['user-b']);
      expect(harness.analytics.events, isEmpty);
    });

    test(
      'falha de checkCurrentUser sem sessão mantém fluxo fail-closed',
      () async {
        final harness = _harness();
        harness.repository.currentUserResults.add(
          const Error(AuthFailure('sessão ausente')),
        );

        harness.container.read(authNotifierProvider);
        await pumpEventQueue(times: 20);

        expect(harness.state, isA<AuthError>());
        expect(harness.syncManager.processedUserIds, isEmpty);
      },
    );
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

  test('password reset success returns true and unauthenticates', () async {
    final harness = _harness();

    final succeeded = await harness.notifier.resetPassword(
      'user@example.invalid',
    );

    expect(succeeded, isTrue);
    expect(harness.state, isA<AuthUnauthenticated>());
    expect(harness.repository.passwordResetCalls, 1);
  });

  test(
    'password reset failure returns false and exposes friendly state',
    () async {
      final harness = _harness();
      harness.repository.passwordResetResult = const Error(
        AuthFailure(
          'Não foi possível solicitar a recuperação de senha. Tente novamente.',
          code: 'PASSWORD_RESET_FAILED',
        ),
      );

      final succeeded = await harness.notifier.resetPassword(
        'user@example.invalid',
      );

      expect(succeeded, isFalse);
      expect(harness.state, isA<AuthError>());
      expect(
        (harness.state as AuthError).message,
        'Não foi possível solicitar a recuperação de senha. Tente novamente.',
      );
      expect(harness.repository.passwordResetCalls, 1);
    },
  );
}
