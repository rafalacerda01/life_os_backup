import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:drift/native.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/database_provider.dart';
import 'package:life_os/core/errors/failure.dart';
import 'package:life_os/core/services/sync_manager.dart';
import 'package:life_os/core/services/sync_manager_provider.dart';
import 'package:life_os/features/auth/data/local/auth_cleanup_barrier.dart';
import 'package:life_os/features/auth/domain/entities/user_entity.dart';
import 'package:life_os/features/auth/domain/repositories/auth_repository.dart';
import 'package:life_os/features/auth/presentation/providers/auth_provider.dart';
import 'package:life_os/features/auth/presentation/providers/auth_state.dart';
import 'package:life_os/features/health/presentation/cycle/cycle_reminder_preferences.dart';
import 'package:life_os/features/health/services/cycle_reminder_action_coordinator.dart';
import 'package:life_os/features/health/services/cycle_reminder_mutation_gate.dart';
import 'package:life_os/features/health/services/cycle_reminder_notification_lifecycle.dart';
import 'package:life_os/features/health/services/cycle_reminder_operation_epoch.dart';
import 'package:life_os/features/health/services/cycle_reminder_session_authority.dart';
import 'package:life_os/features/health/services/cycle_reminder_session_cleanup.dart';
import 'package:life_os/features/health/services/cycle_reminder_session_reconciler.dart';
import 'package:multiple_result/multiple_result.dart';

const _userA = UserEntity(
  uid: 'user-a',
  email: 'a@example.invalid',
  displayName: 'A',
  isPremium: false,
  xp: 0,
  level: 1,
  streak: 0,
);

const _userB = UserEntity(
  uid: 'user-b',
  email: 'b@example.invalid',
  displayName: 'B',
  isPremium: false,
  xp: 0,
  level: 1,
  streak: 0,
);

class _FirebaseUser extends Fake implements User {
  _FirebaseUser(this.uid);

  @override
  final String uid;

  @override
  List<UserInfo> get providerData => const <UserInfo>[];

  @override
  Future<String?> getIdToken([bool forceRefresh = false]) async => 'test-token';
}

class _FirebaseAuth extends Fake implements FirebaseAuth {
  _FirebaseAuth(this.user);

  final StreamController<User?> _changes = StreamController<User?>.broadcast();
  User? user;
  int signOutCalls = 0;

  @override
  User? get currentUser => user;

  @override
  Stream<User?> authStateChanges() => _changes.stream;

  @override
  Future<void> signOut() async {
    signOutCalls += 1;
    user = null;
  }

  void emit(User? next) {
    user = next;
    _changes.add(next);
  }

  Future<void> close() => _changes.close();
}

class _ScriptedFirestore extends Fake implements FirebaseFirestore {
  _ScriptedFirestore({
    Iterable<Object?> clearResults = const <Object?>[null],
    Iterable<Object?> terminateResults = const <Object?>[null],
  }) : _clearResults = clearResults.toList(),
       _terminateResults = terminateResults.toList();

  final List<Object?> _clearResults;
  final List<Object?> _terminateResults;
  int clearPersistenceCalls = 0;
  int terminateCalls = 0;

  @override
  Future<void> clearPersistence() async {
    clearPersistenceCalls += 1;
    final result = _clearResults.isEmpty ? null : _clearResults.removeAt(0);
    if (result != null) throw result;
  }

  @override
  Future<void> terminate() async {
    terminateCalls += 1;
    final result = _terminateResults.isEmpty
        ? null
        : _terminateResults.removeAt(0);
    if (result != null) throw result;
  }
}

class _AuthRepository extends Fake implements AuthRepository {
  _AuthRepository(
    this.auth, {
    this.failSignOut = false,
    this.deleteStarted,
    this.allowDelete,
    this.completeDeletionBySigningOut = false,
    this.onGetCurrentUser,
  });

  final _FirebaseAuth auth;
  final bool failSignOut;
  final Completer<void>? deleteStarted;
  final Completer<void>? allowDelete;
  final bool completeDeletionBySigningOut;
  final Future<void> Function(String userId)? onGetCurrentUser;
  int signOutCalls = 0;
  final List<String> deletedExpectedUserIds = <String>[];

  @override
  Future<Result<UserEntity, Failure>> getCurrentUser() async {
    final userId = auth.currentUser?.uid;
    if (userId == null) {
      return const Error(AuthFailure('not authenticated'));
    }
    await onGetCurrentUser?.call(userId);
    return Success(userId == _userB.uid ? _userB : _userA);
  }

  @override
  Future<Result<void, Failure>> deleteAccount({
    required String expectedUid,
  }) async {
    deletedExpectedUserIds.add(expectedUid);
    deleteStarted?.complete();
    await allowDelete?.future;
    if (completeDeletionBySigningOut) auth.emit(null);
    return const Success(null);
  }

  @override
  Future<Result<void, Failure>> signOut() async {
    signOutCalls += 1;
    if (failSignOut) {
      return const Error(AuthFailure('private sign-out failure'));
    }
    auth.emit(null);
    return const Success(null);
  }
}

class _MemoryBarrierStorage implements AuthCleanupBarrierStorage {
  _MemoryBarrierStorage([Map<String, String>? values])
    : values = values ?? <String, String>{};

  final Map<String, String> values;
  bool throwOnWrite = false;
  bool throwOnDelete = false;
  int writeCalls = 0;
  int deleteCalls = 0;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    writeCalls += 1;
    if (throwOnWrite) throw StateError('private barrier write failure');
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    deleteCalls += 1;
    if (throwOnDelete) throw StateError('private barrier delete failure');
    values.remove(key);
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

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {}
}

class _SyncManager extends Fake implements SyncManager {
  @override
  Future<bool> processPendingItems() async => false;
}

class _SessionCoordinator extends Fake
    implements CycleReminderActionSessionCoordinator {
  _SessionCoordinator(this.authority, this.epoch);

  final CycleReminderSessionAuthority authority;
  final CycleReminderOperationEpoch epoch;
  final List<String> preparedUserIds = <String>[];

  @override
  Future<void> onSessionPrepared(String userId) async {
    authority.prepare(userId);
    preparedUserIds.add(userId);
  }

  @override
  void onSessionCleared() {
    final previousUserId = authority.clear();
    if (previousUserId != null) epoch.invalidate(previousUserId);
  }
}

class _SessionRestore extends Fake implements CycleReminderSessionRestore {
  @override
  Future<void> restoreForSession(String userId) async {}
}

class _ScriptedLifecycle extends Fake
    implements CycleReminderNotificationLifecycle {
  _ScriptedLifecycle(Iterable<int> cancellationResults, {this.events})
    : _cancellationResults = cancellationResults.toList();

  final List<int> _cancellationResults;
  final List<String>? events;
  int cancellationCalls = 0;
  final List<String> cancelledUserIds = <String>[];

  @override
  Future<int> cancelAllCycleReminders(String userId) async {
    cancellationCalls += 1;
    cancelledUserIds.add(userId);
    events?.add('cleanup:$userId');
    return _cancellationResults.removeAt(0);
  }
}

class _ScriptedTokenRotation {
  _ScriptedTokenRotation({
    this.failuresRemaining = 0,
    this.events,
    this.callStarted,
    this.allowCall,
  });

  int failuresRemaining;
  final List<String>? events;
  final Completer<void>? callStarted;
  final Completer<void>? allowCall;
  int calls = 0;
  int tokenVersion = 1;
  final List<String> userIds = <String>[];

  Future<void> call(String userId) async {
    calls += 1;
    userIds.add(userId);
    events?.add('rotate:$userId');
    final started = callStarted;
    if (started != null && !started.isCompleted) started.complete();
    await allowCall?.future;
    if (failuresRemaining > 0) {
      failuresRemaining -= 1;
      throw StateError('private token rotation failure');
    }
    tokenVersion += 1;
  }
}

class _Harness {
  _Harness._({
    required this.auth,
    required this.repository,
    required this.firestore,
    required this.database,
    required this.authority,
    required this.epoch,
    required this.lifecycle,
    required this.rotation,
    required this.coordinator,
    required this.barrierStorage,
    required this.container,
  });

  final _FirebaseAuth auth;
  final _AuthRepository repository;
  final _ScriptedFirestore firestore;
  final AppDatabase database;
  final CycleReminderSessionAuthority authority;
  final CycleReminderOperationEpoch epoch;
  final _ScriptedLifecycle lifecycle;
  final _ScriptedTokenRotation rotation;
  final _SessionCoordinator coordinator;
  final _MemoryBarrierStorage barrierStorage;
  final ProviderContainer container;

  AuthNotifier get notifier => container.read(authNotifierProvider.notifier);
  AuthState get state => container.read(authNotifierProvider);

  Future<T> waitForState<T extends AuthState>() async {
    final current = state;
    if (current is T) return current;

    final completer = Completer<T>();
    late final ProviderSubscription<AuthState> subscription;
    subscription = container.listen<AuthState>(authNotifierProvider, (_, next) {
      if (next is T && !completer.isCompleted) {
        completer.complete(next);
        subscription.close();
      }
    });
    return completer.future;
  }

  Future<PendingAuthCleanup?> readPendingCleanup() {
    return AuthCleanupBarrierStore(barrierStorage).readPending();
  }

  static Future<_Harness> create(
    Iterable<int> cancellationResults, {
    int rotationFailures = 0,
    bool failSignOut = false,
    _MemoryBarrierStorage? barrierStorage,
    _ScriptedTokenRotation? tokenRotation,
    String? firebaseUserId = 'user-a',
    bool waitForAuthentication = true,
    Completer<void>? deleteStarted,
    Completer<void>? allowDelete,
    bool completeDeletionBySigningOut = false,
    _ScriptedFirestore? firestore,
    Future<void> Function(String userId, AppDatabase database)?
    onGetCurrentUser,
    List<String>? lifecycleEvents,
  }) async {
    final auth = _FirebaseAuth(
      firebaseUserId == null ? null : _FirebaseUser(firebaseUserId),
    );
    final database = AppDatabase(executor: NativeDatabase.memory());
    final localFirestore = firestore ?? _ScriptedFirestore();
    final repository = _AuthRepository(
      auth,
      failSignOut: failSignOut,
      deleteStarted: deleteStarted,
      allowDelete: allowDelete,
      completeDeletionBySigningOut: completeDeletionBySigningOut,
      onGetCurrentUser: onGetCurrentUser == null
          ? null
          : (userId) => onGetCurrentUser(userId, database),
    );
    final authority = CycleReminderSessionAuthority();
    final epoch = CycleReminderOperationEpoch();
    final mutationGate = CycleReminderMutationGate();
    final lifecycle = _ScriptedLifecycle(
      cancellationResults,
      events: lifecycleEvents,
    );
    final rotation =
        tokenRotation ??
        _ScriptedTokenRotation(failuresRemaining: rotationFailures);
    final durableStorage = barrierStorage ?? _MemoryBarrierStorage();
    final coordinator = _SessionCoordinator(authority, epoch);
    final cleanup = CycleReminderSessionCleanup(
      mutationGate,
      lifecycle,
      rotateActionToken: rotation.call,
    );
    final container = ProviderContainer(
      overrides: [
        firebaseAuthProvider.overrideWithValue(auth),
        firestoreProvider.overrideWithValue(localFirestore),
        authRepositoryProvider.overrideWithValue(repository),
        secureStorageProvider.overrideWithValue(_SecureStorage()),
        databaseProvider.overrideWithValue(database),
        syncManagerProvider.overrideWithValue(_SyncManager()),
        cycleReminderSessionAuthorityProvider.overrideWithValue(authority),
        cycleReminderOperationEpochProvider.overrideWithValue(epoch),
        cycleReminderMutationGateProvider.overrideWithValue(mutationGate),
        cycleReminderActionCoordinatorProvider.overrideWithValue(coordinator),
        cycleReminderSessionReconcilerProvider.overrideWithValue(
          _SessionRestore(),
        ),
        cycleReminderSessionCleanupProvider.overrideWithValue(cleanup),
        authCleanupBarrierProvider.overrideWithValue(
          AuthCleanupBarrierStore(durableStorage),
        ),
        cycleReminderFirebaseUserIdReaderProvider.overrideWithValue(
          () => auth.currentUser?.uid,
        ),
      ],
    );

    if (waitForAuthentication) {
      final authenticated = Completer<void>();
      container.listen<AuthState>(authNotifierProvider, (_, next) {
        if (next is AuthAuthenticated && !authenticated.isCompleted) {
          authenticated.complete();
        }
      }, fireImmediately: true);
      await authenticated.future;
    } else {
      container.read(authNotifierProvider);
    }

    return _Harness._(
      auth: auth,
      repository: repository,
      firestore: localFirestore,
      database: database,
      authority: authority,
      epoch: epoch,
      lifecycle: lifecycle,
      rotation: rotation,
      coordinator: coordinator,
      barrierStorage: durableStorage,
      container: container,
    );
  }

  Future<void> dispose() async {
    container.dispose();
    await database.close();
    await auth.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'logout termina Firestore após failed-precondition e repete clear',
    () async {
      final firestore = _ScriptedFirestore(
        clearResults: <Object?>[
          FirebaseException(
            plugin: 'cloud_firestore',
            code: 'failed-precondition',
          ),
          null,
        ],
      );
      final harness = await _Harness.create(<int>[0], firestore: firestore);
      addTearDown(harness.dispose);

      await harness.notifier.logout();

      expect(harness.state, isA<AuthUnauthenticated>());
      expect(harness.repository.signOutCalls, 1);
      expect(firestore.clearPersistenceCalls, 2);
      expect(firestore.terminateCalls, 1);
    },
  );

  test('segunda passagem do logout não repete limpeza Firestore', () async {
    final firestore = _ScriptedFirestore();
    final harness = await _Harness.create(<int>[0], firestore: firestore);
    addTearDown(harness.dispose);

    await harness.notifier.logout();

    expect(harness.state, isA<AuthUnauthenticated>());
    expect(firestore.clearPersistenceCalls, 1);
    expect(firestore.terminateCalls, 0);
  });

  test('falha ao terminar Firestore bloqueia sign-out', () async {
    final firestore = _ScriptedFirestore(
      clearResults: <Object?>[
        FirebaseException(
          plugin: 'cloud_firestore',
          code: 'failed-precondition',
        ),
      ],
      terminateResults: <Object?>[
        StateError('private Firestore terminate failure'),
      ],
    );
    final harness = await _Harness.create(<int>[0], firestore: firestore);
    addTearDown(harness.dispose);

    await harness.notifier.logout();

    expect(harness.state, isA<AuthError>());
    expect(harness.repository.signOutCalls, 0);
    expect(firestore.clearPersistenceCalls, 1);
    expect(firestore.terminateCalls, 1);
  });

  test('falha no segundo clear não conclui guard e retry limpa', () async {
    final firestore = _ScriptedFirestore(
      clearResults: <Object?>[
        FirebaseException(
          plugin: 'cloud_firestore',
          code: 'failed-precondition',
        ),
        StateError('private second clear failure'),
        null,
      ],
    );
    final harness = await _Harness.create(<int>[0, 0], firestore: firestore);
    addTearDown(harness.dispose);

    await harness.notifier.logout();

    expect(harness.state, isA<AuthError>());
    expect(harness.repository.signOutCalls, 0);
    expect(firestore.clearPersistenceCalls, 2);
    expect(firestore.terminateCalls, 1);

    await harness.notifier.logout();

    expect(harness.state, isA<AuthUnauthenticated>());
    expect(harness.repository.signOutCalls, 1);
    expect(firestore.clearPersistenceCalls, 3);
    expect(firestore.terminateCalls, 1);
  });

  test('nova sessão rearma limpeza Firestore para logout posterior', () async {
    final firestore = _ScriptedFirestore();
    final harness = await _Harness.create(<int>[0, 0], firestore: firestore);
    addTearDown(harness.dispose);

    await harness.notifier.logout();
    expect(harness.state, isA<AuthUnauthenticated>());
    expect(firestore.clearPersistenceCalls, 1);

    harness.auth.user = _FirebaseUser(_userB.uid);
    await harness.notifier.checkCurrentUser();
    expect(harness.state, isA<AuthAuthenticated>());

    await harness.notifier.logout();

    expect(harness.state, isA<AuthUnauthenticated>());
    expect(harness.repository.signOutCalls, 2);
    expect(firestore.clearPersistenceCalls, 2);
    expect(firestore.terminateCalls, 0);
  });

  test(
    'cancelamento final parcial falha fechado e retry posterior pode concluir',
    () async {
      final harness = await _Harness.create(<int>[1, 0]);
      addTearDown(harness.dispose);
      final oldGeneration = harness.epoch.snapshot(_userA.uid);

      await harness.notifier.logout();

      expect(harness.state, isA<AuthError>());
      expect(harness.repository.signOutCalls, 0);
      expect(harness.authority.preparedUserId, isNull);
      expect(harness.epoch.isCurrent(_userA.uid, oldGeneration), isFalse);
      expect(harness.coordinator.preparedUserIds, <String>[_userA.uid]);
      expect(harness.lifecycle.cancellationCalls, 1);
      expect(harness.rotation.calls, 1);

      await harness.notifier.logout();

      expect(harness.state, isA<AuthUnauthenticated>());
      expect(harness.repository.signOutCalls, 1);
      expect(harness.lifecycle.cancellationCalls, 2);
      expect(harness.rotation.calls, 2);
      expect(harness.authority.preparedUserId, isNull);
    },
  );

  test('troca A para B não prepara B quando cleanup de A falha', () async {
    final harness = await _Harness.create(<int>[1]);
    addTearDown(harness.dispose);
    final failed = Completer<void>();
    harness.container.listen<AuthState>(authNotifierProvider, (_, next) {
      if (next is AuthError && !failed.isCompleted) failed.complete();
    });

    harness.auth.emit(_FirebaseUser('user-b'));
    await failed.future;

    expect(harness.lifecycle.cancellationCalls, 1);
    expect(harness.coordinator.preparedUserIds, <String>[_userA.uid]);
    expect(harness.authority.preparedUserId, isNull);
    expect(harness.auth.currentUser, isNull);
    expect(harness.auth.signOutCalls, 1);
    expect(harness.repository.signOutCalls, 0);
  });

  test('zero falhas preserva logout normal', () async {
    final harness = await _Harness.create(<int>[0]);
    addTearDown(harness.dispose);

    await harness.notifier.logout();

    expect(harness.state, isA<AuthUnauthenticated>());
    expect(harness.lifecycle.cancellationCalls, 1);
    expect(harness.rotation.calls, 1);
    expect(harness.repository.signOutCalls, 1);
    expect(harness.authority.preparedUserId, isNull);
    expect(await harness.readPendingCleanup(), isNull);
  });

  test('falha de rotação bloqueia logout e retry posterior conclui', () async {
    final harness = await _Harness.create(<int>[0], rotationFailures: 1);
    addTearDown(harness.dispose);

    await harness.notifier.logout();

    expect(harness.state, isA<AuthError>());
    expect(harness.authority.preparedUserId, isNull);
    expect(harness.rotation.calls, 1);
    expect(harness.rotation.tokenVersion, 1);
    expect(harness.lifecycle.cancellationCalls, 0);
    expect(harness.repository.signOutCalls, 0);

    await harness.notifier.logout();

    expect(harness.state, isA<AuthUnauthenticated>());
    expect(harness.rotation.calls, 2);
    expect(harness.rotation.tokenVersion, 2);
    expect(harness.lifecycle.cancellationCalls, 1);
    expect(harness.repository.signOutCalls, 1);
  });

  test('falha de rotação impede preparar B após troca de sessão', () async {
    final harness = await _Harness.create(<int>[0], rotationFailures: 1);
    addTearDown(harness.dispose);
    final failed = Completer<void>();
    harness.container.listen<AuthState>(authNotifierProvider, (_, next) {
      if (next is AuthError && !failed.isCompleted) failed.complete();
    });

    harness.auth.emit(_FirebaseUser('user-b'));
    await failed.future;

    expect(harness.rotation.calls, 1);
    expect(harness.lifecycle.cancellationCalls, 0);
    expect(harness.coordinator.preparedUserIds, <String>[_userA.uid]);
    expect(harness.authority.preparedUserId, isNull);
    expect(harness.auth.signOutCalls, 1);
  });

  test('falha de sign-out não restaura credencial anterior', () async {
    final harness = await _Harness.create(<int>[0], failSignOut: true);
    addTearDown(harness.dispose);
    final barrier = AuthCleanupBarrierStore(harness.barrierStorage);
    final isolation = await barrier.setPending(
      _userA.uid,
      AuthCleanupIntent.isolation,
    );

    await harness.notifier.logout();

    expect(harness.state, isA<AuthError>());
    expect(harness.rotation.calls, 1);
    expect(harness.rotation.tokenVersion, 2);
    expect(harness.lifecycle.cancellationCalls, 1);
    expect(harness.repository.signOutCalls, 1);
    expect(harness.authority.preparedUserId, isNull);
    final logout = await harness.readPendingCleanup();
    expect(logout?.requiresSignOut, isTrue);
    expect(logout?.revision, isNot(isolation.revision));
    expect(await barrier.clearIfCurrent(isolation), isFalse);
    expect(await harness.readPendingCleanup(), logout);
  });

  test(
    'restart após rotação falhar recupera logout antes de qualquer prepare',
    () async {
      final barrierStorage = _MemoryBarrierStorage();
      final rotation = _ScriptedTokenRotation(failuresRemaining: 1);
      final first = await _Harness.create(
        <int>[0],
        barrierStorage: barrierStorage,
        tokenRotation: rotation,
      );

      await first.notifier.logout();

      expect(first.state, isA<AuthError>());
      expect(rotation.tokenVersion, 1);
      expect((await first.readPendingCleanup())?.requiresSignOut, isTrue);
      await first.dispose();

      final second = await _Harness.create(
        <int>[0],
        barrierStorage: barrierStorage,
        tokenRotation: rotation,
        waitForAuthentication: false,
      );
      addTearDown(second.dispose);
      await second.notifier.checkCurrentUser();

      expect(rotation.tokenVersion, 2);
      expect(rotation.userIds, <String>[_userA.uid, _userA.uid]);
      expect(second.coordinator.preparedUserIds, isEmpty);
      expect(second.auth.currentUser, isNull);
      expect(await second.readPendingCleanup(), isNull);
    },
  );

  test('restart mantém barrier quando rotação falha novamente', () async {
    final barrierStorage = _MemoryBarrierStorage();
    final barrier = AuthCleanupBarrierStore(barrierStorage);
    await barrier.setPending(_userA.uid, AuthCleanupIntent.logout);
    final rotation = _ScriptedTokenRotation(failuresRemaining: 1);

    final harness = await _Harness.create(
      <int>[0],
      barrierStorage: barrierStorage,
      tokenRotation: rotation,
      waitForAuthentication: false,
    );
    addTearDown(harness.dispose);
    await harness.waitForState<AuthError>();

    expect(rotation.calls, 1);
    expect(rotation.tokenVersion, 1);
    expect(harness.coordinator.preparedUserIds, isEmpty);
    expect((await harness.readPendingCleanup())?.userId, _userA.uid);
  });

  test(
    'recovery stale preserva logout mais novo e restart resolve antes do prepare',
    () async {
      final barrierStorage = _MemoryBarrierStorage();
      final barrier = AuthCleanupBarrierStore(barrierStorage);
      final isolation = await barrier.setPending(
        _userA.uid,
        AuthCleanupIntent.isolation,
      );
      final rotationStarted = Completer<void>();
      final allowRotation = Completer<void>();
      final rotation = _ScriptedTokenRotation(
        callStarted: rotationStarted,
        allowCall: allowRotation,
      );
      final first = await _Harness.create(
        <int>[0],
        barrierStorage: barrierStorage,
        tokenRotation: rotation,
        waitForAuthentication: false,
      );

      await rotationStarted.future;
      final logout = await barrier.setPending(
        _userA.uid,
        AuthCleanupIntent.logout,
      );
      expect(logout.revision, isNot(isolation.revision));
      allowRotation.complete();
      await first.waitForState<AuthError>();

      expect(first.coordinator.preparedUserIds, isEmpty);
      expect(await first.readPendingCleanup(), logout);
      await first.dispose();

      final second = await _Harness.create(
        <int>[0],
        barrierStorage: barrierStorage,
        tokenRotation: rotation,
        waitForAuthentication: false,
      );
      addTearDown(second.dispose);
      await second.notifier.checkCurrentUser();

      expect(second.coordinator.preparedUserIds, isEmpty);
      expect(second.auth.currentUser, isNull);
      expect(await second.readPendingCleanup(), isNull);
    },
  );

  test('restart com Firebase B isola A antes de preparar B', () async {
    final events = <String>[];
    final barrierStorage = _MemoryBarrierStorage();
    await AuthCleanupBarrierStore(
      barrierStorage,
    ).setPending(_userA.uid, AuthCleanupIntent.isolation);
    final rotation = _ScriptedTokenRotation(events: events);

    final harness = await _Harness.create(
      <int>[0],
      barrierStorage: barrierStorage,
      tokenRotation: rotation,
      firebaseUserId: 'user-b',
    );
    addTearDown(harness.dispose);
    events.addAll(
      harness.coordinator.preparedUserIds.map((uid) => 'prepare:$uid'),
    );

    expect(rotation.userIds, <String>[_userA.uid]);
    expect(harness.coordinator.preparedUserIds, <String>['user-b']);
    expect(events, <String>['rotate:user-a', 'prepare:user-b']);
    expect(await harness.readPendingCleanup(), isNull);
  });

  test('restart com Firebase null conclui cleanup local de A', () async {
    final barrierStorage = _MemoryBarrierStorage();
    await AuthCleanupBarrierStore(
      barrierStorage,
    ).setPending(_userA.uid, AuthCleanupIntent.isolation);
    final rotation = _ScriptedTokenRotation();

    final harness = await _Harness.create(
      <int>[0],
      barrierStorage: barrierStorage,
      tokenRotation: rotation,
      firebaseUserId: null,
      waitForAuthentication: false,
    );
    addTearDown(harness.dispose);
    await harness.waitForState<AuthUnauthenticated>();

    expect(rotation.userIds, <String>[_userA.uid]);
    expect(harness.lifecycle.cancellationCalls, 1);
    expect(harness.coordinator.preparedUserIds, isEmpty);
    expect(await harness.readPendingCleanup(), isNull);
  });

  test('crash após rotate repete recovery e só então prepara A', () async {
    final barrierStorage = _MemoryBarrierStorage()..throwOnDelete = true;
    await AuthCleanupBarrierStore(
      barrierStorage,
    ).setPending(_userA.uid, AuthCleanupIntent.isolation);
    final rotation = _ScriptedTokenRotation();
    final first = await _Harness.create(
      <int>[0],
      barrierStorage: barrierStorage,
      tokenRotation: rotation,
      waitForAuthentication: false,
    );
    await first.waitForState<AuthError>();

    expect(rotation.tokenVersion, 2);
    expect((await first.readPendingCleanup())?.userId, _userA.uid);
    await first.dispose();

    barrierStorage.throwOnDelete = false;
    final second = await _Harness.create(
      <int>[0],
      barrierStorage: barrierStorage,
      tokenRotation: rotation,
    );
    addTearDown(second.dispose);

    expect(rotation.tokenVersion, 3);
    expect(second.coordinator.preparedUserIds, <String>[_userA.uid]);
    expect(await second.readPendingCleanup(), isNull);
  });

  test('falha ao armar barrier não inicia cleanup crítico', () async {
    final barrierStorage = _MemoryBarrierStorage()..throwOnWrite = true;
    final harness = await _Harness.create(<int>[
      0,
    ], barrierStorage: barrierStorage);
    addTearDown(harness.dispose);

    await harness.notifier.logout();

    expect(harness.state, isA<AuthError>());
    expect(harness.rotation.calls, 0);
    expect(harness.lifecycle.cancellationCalls, 0);
    expect(harness.repository.signOutCalls, 0);
    expect(harness.authority.preparedUserId, isNull);
    expect(await harness.readPendingCleanup(), isNull);
  });

  test('falha ao limpar barrier mantém logout fail-closed', () async {
    final barrierStorage = _MemoryBarrierStorage()..throwOnDelete = true;
    final harness = await _Harness.create(<int>[
      0,
    ], barrierStorage: barrierStorage);
    addTearDown(harness.dispose);

    await harness.notifier.logout();

    expect(harness.state, isA<AuthError>());
    expect(harness.repository.signOutCalls, 1);
    expect(harness.coordinator.preparedUserIds, <String>[_userA.uid]);
    expect(harness.authority.preparedUserId, isNull);
    expect((await harness.readPendingCleanup())?.requiresSignOut, isTrue);
  });

  test(
    'delete A com troca para B limpa A antes de preparar e preserva B',
    () async {
      final deleteStarted = Completer<void>();
      final allowDelete = Completer<void>();
      final events = <String>[];
      final harness = await _Harness.create(
        <int>[0],
        deleteStarted: deleteStarted,
        allowDelete: allowDelete,
        lifecycleEvents: events,
        onGetCurrentUser: (userId, database) async {
          if (userId != _userB.uid) return;
          events.add('prepare:$userId');
          await database
              .into(database.taskTable)
              .insert(
                TaskTableCompanion.insert(
                  id: 'user-b-local-data',
                  title: 'B local data',
                  priority: 'normal',
                  date: DateTime(2026, 9, 1),
                ),
              );
        },
      );
      addTearDown(harness.dispose);

      final deletion = harness.notifier.deleteAccount();
      await deleteStarted.future;
      harness.auth.emit(_FirebaseUser(_userB.uid));
      allowDelete.complete();
      await deletion;

      expect(harness.repository.deletedExpectedUserIds, <String>[_userA.uid]);
      expect(harness.auth.signOutCalls, 0);
      expect(harness.auth.currentUser?.uid, _userB.uid);
      expect(harness.state, isA<AuthAuthenticated>());
      expect((harness.state as AuthAuthenticated).user.uid, _userB.uid);
      expect(events, <String>[
        'cleanup:${_userA.uid}',
        'prepare:${_userB.uid}',
      ]);
      expect(
        await harness.database.select(harness.database.taskTable).get(),
        hasLength(1),
      );
      expect(await harness.readPendingCleanup(), isNull);
    },
  );

  test('delete A no happy path limpa A e termina sem sessão', () async {
    final harness = await _Harness.create(<int>[
      0,
    ], completeDeletionBySigningOut: true);
    addTearDown(harness.dispose);

    await harness.notifier.deleteAccount();

    expect(harness.repository.deletedExpectedUserIds, <String>[_userA.uid]);
    expect(harness.lifecycle.cancelledUserIds, <String>[_userA.uid]);
    expect(harness.state, isA<AuthUnauthenticated>());
    expect(harness.auth.currentUser, isNull);
    expect(await harness.readPendingCleanup(), isNull);
  });
}
