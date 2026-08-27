import 'dart:async';

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

class _FirebaseUser extends Fake implements User {
  _FirebaseUser(this.uid);

  @override
  final String uid;

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
  }

  void emit(User? next) {
    user = next;
    _changes.add(next);
  }

  Future<void> close() => _changes.close();
}

class _AuthRepository extends Fake implements AuthRepository {
  int signOutCalls = 0;

  @override
  Future<Result<UserEntity, Failure>> getCurrentUser() async =>
      const Success(_userA);

  @override
  Future<Result<void, Failure>> signOut() async {
    signOutCalls += 1;
    return const Success(null);
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
  _ScriptedLifecycle(Iterable<int> cancellationResults)
    : _cancellationResults = cancellationResults.toList();

  final List<int> _cancellationResults;
  int cancellationCalls = 0;

  @override
  Future<int> cancelAllCycleReminders(String userId) async {
    cancellationCalls += 1;
    return _cancellationResults.removeAt(0);
  }
}

class _Harness {
  _Harness._({
    required this.auth,
    required this.repository,
    required this.database,
    required this.authority,
    required this.epoch,
    required this.lifecycle,
    required this.coordinator,
    required this.container,
  });

  final _FirebaseAuth auth;
  final _AuthRepository repository;
  final AppDatabase database;
  final CycleReminderSessionAuthority authority;
  final CycleReminderOperationEpoch epoch;
  final _ScriptedLifecycle lifecycle;
  final _SessionCoordinator coordinator;
  final ProviderContainer container;

  AuthNotifier get notifier => container.read(authNotifierProvider.notifier);
  AuthState get state => container.read(authNotifierProvider);

  static Future<_Harness> create(Iterable<int> cancellationResults) async {
    final auth = _FirebaseAuth(_FirebaseUser(_userA.uid));
    final repository = _AuthRepository();
    final database = AppDatabase(executor: NativeDatabase.memory());
    final authority = CycleReminderSessionAuthority();
    final epoch = CycleReminderOperationEpoch();
    final mutationGate = CycleReminderMutationGate();
    final lifecycle = _ScriptedLifecycle(cancellationResults);
    final coordinator = _SessionCoordinator(authority, epoch);
    final cleanup = CycleReminderSessionCleanup(mutationGate, lifecycle);
    final container = ProviderContainer(
      overrides: [
        firebaseAuthProvider.overrideWithValue(auth),
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
        cycleReminderFirebaseUserIdReaderProvider.overrideWithValue(
          () => auth.currentUser?.uid,
        ),
      ],
    );

    final authenticated = Completer<void>();
    container.listen<AuthState>(authNotifierProvider, (_, next) {
      if (next is AuthAuthenticated && !authenticated.isCompleted) {
        authenticated.complete();
      }
    }, fireImmediately: true);
    await authenticated.future;

    return _Harness._(
      auth: auth,
      repository: repository,
      database: database,
      authority: authority,
      epoch: epoch,
      lifecycle: lifecycle,
      coordinator: coordinator,
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

      await harness.notifier.logout();

      expect(harness.state, isA<AuthUnauthenticated>());
      expect(harness.repository.signOutCalls, 1);
      expect(harness.lifecycle.cancellationCalls, 2);
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
    expect(harness.auth.currentUser?.uid, 'user-b');
    expect(harness.auth.signOutCalls, 1);
    expect(harness.repository.signOutCalls, 0);
  });

  test('zero falhas preserva logout normal', () async {
    final harness = await _Harness.create(<int>[0]);
    addTearDown(harness.dispose);

    await harness.notifier.logout();

    expect(harness.state, isA<AuthUnauthenticated>());
    expect(harness.lifecycle.cancellationCalls, 1);
    expect(harness.repository.signOutCalls, 1);
    expect(harness.authority.preparedUserId, isNull);
  });
}
