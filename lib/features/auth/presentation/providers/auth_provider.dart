import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:life_os/core/services/notification_service.dart';
import 'package:life_os/core/services/analytics_service.dart';
import 'package:life_os/core/services/sync_manager_provider.dart';
import 'package:life_os/core/utils/app_logger.dart';
// Imports dos providers de todos os módulos
import 'package:life_os/features/finance/presentation/providers/finance_provider.dart';
import 'package:life_os/features/tasks/presentation/providers/tasks_provider.dart';
import 'package:life_os/features/habits/presentation/providers/habits_provider.dart';
import 'package:life_os/features/goals/presentation/goals_provider.dart';
import 'package:life_os/features/checkin/presentation/providers/check_in_provider.dart';
import 'package:life_os/features/health/presentation/providers/health_provider.dart';
import 'package:life_os/features/health/services/cycle_reminder_action_coordinator.dart';
import 'package:life_os/features/health/services/cycle_reminder_session_reconciler.dart';
import 'package:life_os/features/focus/presentation/providers/providers/focus_provider.dart';
import 'package:life_os/features/study/presentation/providers/study_provider.dart';
import 'package:life_os/features/tasks/presentation/providers/tasks_notifier.dart';
import 'package:life_os/features/ai_companion/presentation/providers/ai_companion_provider.dart';
import 'package:life_os/features/ai_companion/presentation/providers/ai_consent_provider.dart';
import 'package:life_os/features/circles/presentation/circles_provider.dart';
import 'package:life_os/features/premium/presentation/premium_provider.dart';
import 'package:life_os/features/settings/presentation/providers/analytics_provider.dart';

import 'package:life_os/features/dashboard/presentation/providers/dashboard_provider.dart';
import 'package:life_os/features/auth/data/repositories/auth_repository_impl.dart';
import 'package:life_os/features/auth/data/remote/account_remote_data_source.dart';
import 'package:life_os/features/auth/data/local/auth_cleanup_barrier.dart';
import 'package:life_os/features/auth/domain/repositories/auth_repository.dart';
import 'package:life_os/features/auth/presentation/providers/auth_state.dart';
import 'package:life_os/core/storage/secure_storage_service.dart';
import 'package:life_os/core/database/database_provider.dart';

// Providers de infraestrutura
final firebaseAuthProvider = Provider((ref) => FirebaseAuth.instance);
final firestoreProvider = Provider((ref) => FirebaseFirestore.instance);

typedef AuthNotificationCleanup = Future<void> Function();

final authNotificationCleanupProvider = Provider<AuthNotificationCleanup>((
  ref,
) {
  return NotificationService.instance.cancelAllNotificationsOrThrow;
});

// Provider de Armazenamento Seguro
final secureStorageProvider = Provider<FlutterSecureStorage>((ref) {
  return const FlutterSecureStorage();
});

final secureStorageServiceProvider = Provider<SecureStorageService>((ref) {
  final storage = ref.watch(secureStorageProvider);
  return SecureStorageService(storage);
});

final accountRemoteDataSourceProvider = Provider<AccountRemoteDataSource>((
  ref,
) {
  final dataSource = AccountRemoteDataSource(
    idTokenProvider: (expectedUid) => loadAccountIdTokenForExpectedUser(
      ref.read(firebaseAuthProvider),
      expectedUid,
    ),
  );
  ref.onDispose(dataSource.close);
  return dataSource;
});

// Provider do repositório
final authRepositoryProvider = Provider<AuthRepository>((ref) {
  return AuthRepositoryImpl(
    ref.watch(firebaseAuthProvider),
    ref.watch(firestoreProvider),
    ref.watch(accountRemoteDataSourceProvider),
  );
});

// Refatorado para Notifier
class AuthNotifier extends Notifier<AuthState> {
  AuthRepository get _repository => ref.read(authRepositoryProvider);
  SecureStorageService get _secureStorage =>
      ref.read(secureStorageServiceProvider);
  bool _disposed = false;
  bool _accountDeletionInProgress = false;
  bool _explicitSignOutInProgress = false;
  bool _localCleanupRequired = false;
  String? _activeLocalSessionUid;
  bool _firestoreLocalStateCleared = false;
  Future<void>? _localCleanupInFlight;
  String? _localCleanupInFlightUid;
  Future<void>? _durableCleanupRecoveryInFlight;
  Future<void>? _hydrationInFlight;
  String? _hydrationUid;
  int _sessionGeneration = 0;

  @override
  AuthState build() {
    _disposed = false;
    _initializeAuthListener();
    return AuthState.initial();
  }

  void _initializeAuthListener() {
    final auth = ref.read(firebaseAuthProvider);

    unawaited(checkCurrentUser());

    final subscription = auth.authStateChanges().listen((firebaseUser) async {
      if (firebaseUser == null) {
        if (_accountDeletionInProgress || _explicitSignOutInProgress) return;
        await _finishLocalSignOut();
      } else if (!_accountDeletionInProgress) {
        await _prepareAuthenticatedSession(firebaseUser);
      }
    });

    ref.onDispose(() {
      _disposed = true;
      subscription.cancel();
    });
  }

  void _scheduleHydration(String uid) {
    final cleanUid = uid.trim();

    if (cleanUid.isEmpty || _disposed || _accountDeletionInProgress) return;

    if (_hydrationInFlight != null && _hydrationUid == cleanUid) return;

    final generation = _sessionGeneration;
    late final Future<void> operation;
    operation = _hydrateAllOfflineData(cleanUid, generation).whenComplete(() {
      if (identical(_hydrationInFlight, operation)) {
        _hydrationInFlight = null;
        _hydrationUid = null;
      }
    });
    _hydrationInFlight = operation;
    _hydrationUid = cleanUid;
    unawaited(operation);
  }

  Future<void> _hydrateAllOfflineData(String uid, int generation) async {
    if (!_isCurrentSession(uid, generation)) return;

    try {
      final queueDrained = await ref
          .read(syncManagerProvider)
          .processPendingItems();

      if (!queueDrained || !_isCurrentSession(uid, generation)) return;

      final pulls = <Future<void> Function()>[
        ref.read(financeRepositoryProvider).syncTransactionsFromFirestore,
        ref.read(tasksRepositoryProvider).syncTasksFromFirebaseToLocal,
        ref.read(habitsRepositoryProvider).syncHabitsFromFirebaseToLocal,
        ref.read(goalRepositoryProvider).syncGoalsFromFirebaseToLocal,
        ref.read(checkInRepositoryProvider).syncCheckinsFromFirebaseToLocal,
        ref.read(healthRepositoryProvider).syncHealthFromFirebase,
        ref.read(focusRepositoryProvider).syncFocusFromFirebaseToLocal,
      ];

      for (final pull in pulls) {
        if (!_isCurrentSession(uid, generation)) return;
        await pull();
      }
    } catch (_) {
      // A sessão permanece utilizável offline; a próxima entrada tenta de novo.
    }
  }

  bool _isCurrentSession(String uid, int generation) {
    return !_disposed &&
        !_accountDeletionInProgress &&
        generation == _sessionGeneration &&
        ref.read(firebaseAuthProvider).currentUser?.uid == uid;
  }

  Future<bool> _prepareAuthenticatedSession(User firebaseUser) async {
    if (_disposed || _accountDeletionInProgress || _explicitSignOutInProgress) {
      return false;
    }

    final uid = firebaseUser.uid;
    try {
      await _recoverPendingLocalCleanup();
    } catch (_) {
      try {
        await ref.read(firebaseAuthProvider).signOut();
      } catch (_) {
        // O estado de erro continua bloqueando a exposição da sessão.
      }
      if (!_disposed) {
        state = AuthState.error(
          'Não foi possível isolar os dados locais. Tente novamente.',
        );
      }
      return false;
    }

    if (_disposed || _accountDeletionInProgress || _explicitSignOutInProgress) {
      return false;
    }
    final localSessionUid = _activeLocalSessionUid;
    final requiresLocalIsolation =
        _localCleanupRequired ||
        (localSessionUid != null && localSessionUid != uid);

    if (requiresLocalIsolation) {
      try {
        await _clearLocalData();
        if (_localCleanupRequired) return false;
        _invalidateSessionProviders();
      } catch (_) {
        try {
          await ref.read(firebaseAuthProvider).signOut();
        } catch (_) {
          // O estado de erro continua bloqueando a exposição da sessão.
        }

        if (!_disposed) {
          state = AuthState.error(
            'Não foi possível isolar os dados locais. Tente novamente.',
          );
        }
        return false;
      }
    }

    if (ref.read(firebaseAuthProvider).currentUser?.uid != uid) {
      return false;
    }

    try {
      final token = await firebaseUser.getIdToken();
      if (token != null) {
        await _secureStorage.saveToken(token);
      }
    } catch (_) {
      if (!_disposed) {
        state = AuthState.error('Não foi possível proteger a sessão local.');
      }
      return false;
    }

    final isPrepared =
        !_disposed && ref.read(firebaseAuthProvider).currentUser?.uid == uid;

    if (isPrepared) {
      _activeLocalSessionUid = uid;
      _firestoreLocalStateCleared = false;
      _notifyCycleReminderActionSessionPrepared(uid);
      _restoreCycleReminderForPreparedSession(uid);
    }

    return isPrepared;
  }

  void _notifyCycleReminderActionSessionPrepared(String uid) {
    try {
      final coordinator = ref.read(cycleReminderActionCoordinatorProvider);
      unawaited(
        coordinator.onSessionPrepared(uid).catchError((_) {
          AppLogger.w(
            '[AuthSession] Falha ao preparar ação de lembrete local.',
          );
        }),
      );
    } on Object {
      AppLogger.w('[AuthSession] Falha ao iniciar ação de lembrete local.');
    }
  }

  void _clearCycleReminderActionSession() {
    ref.read(cycleReminderActionCoordinatorProvider).onSessionCleared();
  }

  void _restoreCycleReminderForPreparedSession(String uid) {
    try {
      final reconciler = ref.read(cycleReminderSessionReconcilerProvider);
      unawaited(reconciler.restoreForSession(uid));
    } on Object {
      AppLogger.w(
        '[AuthSession] Falha ao iniciar restauração de lembrete local.',
      );
    }
  }

  // --- Métodos de Autenticação e Perfil ---
  Future<void> checkCurrentUser() async {
    final result = await _repository.getCurrentUser();
    await result.when(
      (user) async {
        if (_disposed || _accountDeletionInProgress) return;
        final firebaseUser = ref.read(firebaseAuthProvider).currentUser;
        if (firebaseUser == null) {
          await _finishLocalSignOut();
          return;
        }
        if (!await _prepareAuthenticatedSession(firebaseUser)) return;
        state = AuthState.authenticated(user);
        _scheduleHydration(firebaseUser.uid);
      },
      (failure) async {
        if (_disposed || _accountDeletionInProgress) return;
        await _finishLocalSignOut();
      },
    );
  }

  Future<void> login(String email, String password) async {
    if (_accountDeletionInProgress) return;
    final analytics = ref.read(analyticsServiceProvider);
    state = AuthState.loading();
    final result = await _repository.signInWithEmailAndPassword(
      email,
      password,
    );
    await result.when(
      (user) async {
        final firebaseUser = ref.read(firebaseAuthProvider).currentUser;
        if (firebaseUser == null ||
            !await _prepareAuthenticatedSession(firebaseUser)) {
          return;
        }
        state = AuthState.authenticated(user);
        _scheduleHydration(firebaseUser.uid);
        unawaited(analytics.logLogin(method: AnalyticsAuthMethod.email));
      },
      (failure) async {
        state = AuthState.error(failure.message);
      },
    );
  }

  Future<void> register(String email, String password, String name) async {
    if (_accountDeletionInProgress) return;
    final analytics = ref.read(analyticsServiceProvider);
    state = AuthState.loading();
    final result = await _repository.signUpWithEmailAndPassword(
      email,
      password,
      name,
    );
    await result.when(
      (user) async {
        final firebaseUser = ref.read(firebaseAuthProvider).currentUser;
        if (firebaseUser == null ||
            !await _prepareAuthenticatedSession(firebaseUser)) {
          return;
        }
        state = AuthState.authenticated(user);
        _scheduleHydration(firebaseUser.uid);
        unawaited(analytics.logSignUp(method: AnalyticsAuthMethod.email));
      },
      (failure) async {
        state = AuthState.error(failure.message);
      },
    );
  }

  Future<void> signInWithGoogle() async {
    if (_accountDeletionInProgress) return;
    final analytics = ref.read(analyticsServiceProvider);
    state = AuthState.loading();
    final result = await _repository.signInWithGoogle();
    await result.when(
      (user) async {
        final firebaseUser = ref.read(firebaseAuthProvider).currentUser;
        if (firebaseUser == null ||
            !await _prepareAuthenticatedSession(firebaseUser)) {
          return;
        }
        state = AuthState.authenticated(user);
        _scheduleHydration(firebaseUser.uid);
        unawaited(analytics.logLogin(method: AnalyticsAuthMethod.google));
      },
      (failure) async {
        state = AuthState.error(failure.message);
      },
    );
  }

  Future<void> updateDisplayName(String newName) async {
    await updateProfile(newName: newName);
  }

  Future<void> updateProfile({String? newName, String? newPhotoUrl}) async {
    await state.maybeWhen(
      authenticated: (user) async {
        final result = await _repository.updateProfile(
          newName ?? user.displayName ?? '',
          newPhotoUrl: newPhotoUrl,
        );

        result.when((updatedUser) {
          state = AuthState.authenticated(updatedUser);
        }, (failure) => state = AuthState.error(failure.message));
      },
      orElse: () async {},
    );
  }

  Future<void> logout() async {
    state = AuthState.loading();
    final logoutUserId =
        _activeLocalSessionUid ??
        ref.read(firebaseAuthProvider).currentUser?.uid;
    _explicitSignOutInProgress = true;
    PendingAuthCleanup? logoutMarker;

    try {
      logoutMarker = await _clearLocalData(
        targetUserId: logoutUserId,
        intent: AuthCleanupIntent.logout,
      );
    } catch (_) {
      _localCleanupRequired = true;
      if (!_disposed) {
        state = AuthState.error(
          'Não foi possível isolar os dados locais. Tente novamente.',
        );
      }
      _explicitSignOutInProgress = false;
      return;
    }

    try {
      final result = await _repository.signOut();

      await result.when(
        (_) async {
          try {
            // Fecha a pequena janela entre a limpeza prévia e o sign-out.
            await _runCriticalLocalDataClear(null);
            if (logoutUserId != null) {
              if (ref.read(firebaseAuthProvider).currentUser?.uid ==
                  logoutUserId) {
                throw StateError('AUTH_SIGN_OUT_NOT_CONFIRMED');
              }
              final expectedMarker = logoutMarker;
              if (expectedMarker == null ||
                  !await ref
                      .read(authCleanupBarrierProvider)
                      .clearIfCurrent(expectedMarker)) {
                throw StateError('AUTH_CLEANUP_BARRIER_CHANGED');
              }
            }
            _localCleanupRequired = false;
            _activeLocalSessionUid = null;
            if (!_disposed) {
              _invalidateSessionProviders();
              state = AuthState.unauthenticated();
            }
          } catch (_) {
            _localCleanupRequired = true;
            if (!_disposed) {
              state = AuthState.error(
                'Não foi possível isolar os dados locais. Tente novamente.',
              );
            }
          }
        },
        (failure) async {
          _localCleanupRequired = true;
          if (!_disposed) {
            state = AuthState.error(failure.message);
          }
        },
      );
    } catch (_) {
      _localCleanupRequired = true;
      if (!_disposed) {
        state = AuthState.error('Não foi possível encerrar a sessão.');
      }
    } finally {
      _explicitSignOutInProgress = false;
    }
  }

  Future<void> resetPassword(String email) async {
    state = AuthState.loading();
    final result = await _repository.sendPasswordResetEmail(email);

    result.when(
      (success) {
        state = AuthState.unauthenticated();
      },
      (failure) {
        state = AuthState.error(failure.message);
      },
    );
  }

  Future<void> deleteAccount({String? password}) async {
    if (_accountDeletionInProgress) return;
    final expectedUid = _activeLocalSessionUid?.trim();
    final user = ref.read(firebaseAuthProvider).currentUser;
    if (expectedUid == null ||
        expectedUid.isEmpty ||
        user == null ||
        user.uid != expectedUid) {
      state = AuthState.error(
        'Sua sessão não é válida. Entre novamente e tente de novo.',
      );
      return;
    }

    _accountDeletionInProgress = true;
    state = AuthState.loading();

    try {
      final providerIds = user.providerData.map((e) => e.providerId).toList();

      if (providerIds.contains('password')) {
        if (password != null && password.isNotEmpty && user.email != null) {
          final credential = EmailAuthProvider.credential(
            email: user.email!,
            password: password,
          );
          await user.reauthenticateWithCredential(credential);
        } else {
          _accountDeletionInProgress = false;
          state = AuthState.error(
            'A senha atual é obrigatória para confirmar a exclusão.',
          );
          return;
        }
      } else if (providerIds.contains('google.com')) {
        final googleSignIn = GoogleSignIn.instance;
        await googleSignIn.initialize(
          serverClientId:
              '278760083864-nfp6h9r9gjaq4tvtcerif8h2d08c6afi.apps.googleusercontent.com',
        );

        final googleUser = await googleSignIn.authenticate();
        final googleAuth = googleUser.authentication;

        final credential = GoogleAuthProvider.credential(
          idToken: googleAuth.idToken,
        );

        await user.reauthenticateWithCredential(credential);
      }

      if (!_isExpectedFirebaseSession(expectedUid)) {
        await _handleChangedAccountDeletionSession(expectedUid);
        return;
      }

      final result = await _repository.deleteAccount(expectedUid: expectedUid);

      await result.when(
        (success) async {
          await _finishExpectedAccountDeletion(expectedUid);
        },
        (failure) async {
          if (!_isExpectedFirebaseSession(expectedUid)) {
            await _handleChangedAccountDeletionSession(expectedUid);
            return;
          }
          _accountDeletionInProgress = false;
          if (!_disposed) state = AuthState.error(failure.message);
        },
      );
    } on FirebaseAuthException catch (e) {
      if (!_isExpectedFirebaseSession(expectedUid)) {
        await _handleChangedAccountDeletionSession(expectedUid);
        return;
      }
      _accountDeletionInProgress = false;
      if (_disposed) return;
      if (e.code == 'wrong-password') {
        state = AuthState.error('Senha incorreta. Tente novamente.');
      } else if (e.code == 'requires-recent-login') {
        state = AuthState.error(
          'Sessão expirada. Faça login novamente e tente de novo.',
        );
      } else {
        state = AuthState.error(
          'Não foi possível confirmar sua autenticação. Tente novamente.',
        );
      }
    } catch (_) {
      if (!_isExpectedFirebaseSession(expectedUid)) {
        await _handleChangedAccountDeletionSession(expectedUid);
        return;
      }
      _accountDeletionInProgress = false;
      if (_disposed) return;
      state = AuthState.error(
        'Não foi possível excluir a conta. Tente novamente.',
      );
    }
  }

  bool _isExpectedFirebaseSession(String expectedUid) {
    return ref.read(firebaseAuthProvider).currentUser?.uid == expectedUid;
  }

  Future<void> _finishExpectedAccountDeletion(String expectedUid) async {
    await _isolateExpectedAccountSession(expectedUid, deletionConfirmed: true);
  }

  Future<void> _handleChangedAccountDeletionSession(String expectedUid) async {
    await _isolateExpectedAccountSession(expectedUid, deletionConfirmed: false);
  }

  Future<void> _isolateExpectedAccountSession(
    String expectedUid, {
    required bool deletionConfirmed,
  }) async {
    if (_disposed) return;

    final activeUid = _activeLocalSessionUid;
    if (activeUid != null && activeUid != expectedUid) {
      _accountDeletionInProgress = false;
      return;
    }

    try {
      await _recoverPendingLocalCleanup();
      if (_disposed) return;

      final recoveredActiveUid = _activeLocalSessionUid;
      if (recoveredActiveUid != null && recoveredActiveUid != expectedUid) {
        _accountDeletionInProgress = false;
        return;
      }

      await _clearLocalData(targetUserId: expectedUid);
      if (_disposed) return;

      _invalidateSessionProviders();
      _accountDeletionInProgress = false;

      final currentUser = ref.read(firebaseAuthProvider).currentUser;
      if (currentUser != null && currentUser.uid != expectedUid) {
        await checkCurrentUser();
        return;
      }

      if (deletionConfirmed || currentUser == null) {
        state = AuthState.unauthenticated();
        return;
      }

      state = AuthState.error(
        'Sua sessão não é válida. Entre novamente e tente de novo.',
      );
    } catch (_) {
      _accountDeletionInProgress = false;
      _localCleanupRequired = true;
      if (!_disposed) {
        state = AuthState.error(
          'Não foi possível isolar os dados locais. Tente novamente.',
        );
      }
    }
  }

  Future<void> _finishLocalSignOut() async {
    if (_disposed) return;

    try {
      await _recoverPendingLocalCleanup();
      await _clearLocalData();
      if (_disposed) return;

      _invalidateSessionProviders();
      state.maybeWhen(
        unauthenticated: () {},
        orElse: () => state = AuthState.unauthenticated(),
      );
    } catch (_) {
      _localCleanupRequired = true;
      if (!_disposed) {
        state = AuthState.error(
          'Não foi possível isolar os dados locais. Tente novamente.',
        );
      }
    }
  }

  Future<PendingAuthCleanup?> _clearLocalData({
    String? targetUserId,
    AuthCleanupIntent intent = AuthCleanupIntent.isolation,
  }) async {
    final cleanupUserId = targetUserId ?? _activeLocalSessionUid;
    PendingAuthCleanup? cleanupMarker;
    if (cleanupUserId != null) {
      _localCleanupRequired = true;
      try {
        cleanupMarker = await ref
            .read(authCleanupBarrierProvider)
            .setPending(cleanupUserId, intent);
      } catch (_) {
        _localCleanupRequired = true;
        _clearCycleReminderActionSession();
        throw StateError('LOCAL_CLEANUP_BARRIER_WRITE_FAILED');
      }
    }

    await _runCriticalLocalDataClear(cleanupUserId);
    _activeLocalSessionUid = null;

    if (cleanupMarker != null && intent == AuthCleanupIntent.isolation) {
      try {
        if (cleanupMarker.requiresSignOut) {
          _localCleanupRequired = true;
          return cleanupMarker;
        }
        final wasCleared = await ref
            .read(authCleanupBarrierProvider)
            .clearIfCurrent(cleanupMarker);
        if (!wasCleared) {
          _localCleanupRequired = true;
          throw StateError('AUTH_CLEANUP_BARRIER_CHANGED');
        }
      } catch (_) {
        _localCleanupRequired = true;
        throw StateError('LOCAL_CLEANUP_BARRIER_CLEAR_FAILED');
      }
    }

    _localCleanupRequired = intent == AuthCleanupIntent.logout;
    return cleanupMarker;
  }

  Future<void> _runCriticalLocalDataClear(String? cleanupUserId) {
    final running = _localCleanupInFlight;
    if (running != null) {
      final runningUserId = _localCleanupInFlightUid;
      if (cleanupUserId != null &&
          runningUserId != null &&
          cleanupUserId != runningUserId) {
        return Future<void>.error(StateError('LOCAL_CLEANUP_USER_CONFLICT'));
      }
      return running;
    }

    late final Future<void> operation;
    operation = _performLocalDataClear(cleanupUserId).whenComplete(() {
      if (identical(_localCleanupInFlight, operation)) {
        _localCleanupInFlight = null;
        _localCleanupInFlightUid = null;
      }
    });
    _localCleanupInFlight = operation;
    _localCleanupInFlightUid = cleanupUserId;
    return operation;
  }

  Future<void> _performLocalDataClear(String? cleanupUserId) async {
    _clearCycleReminderActionSession();
    _sessionGeneration += 1;
    final hydration = _hydrationInFlight;

    if (hydration != null) {
      await hydration.timeout(const Duration(seconds: 20));
    }

    final secureStorage = _secureStorage;
    final db = ref.read(databaseProvider);
    var cleanupFailed = false;

    try {
      await _clearFirestoreLocalState();
    } on Object {
      cleanupFailed = true;
    }

    if (cleanupUserId != null) {
      try {
        final failedCancellations = await ref
            .read(cycleReminderSessionCleanupProvider)
            .cancelAfterCurrentMutations(cleanupUserId);
        if (failedCancellations > 0) {
          cleanupFailed = true;
        }
      } on Object {
        cleanupFailed = true;
      }
    }

    try {
      await secureStorage.deleteToken();
    } on Object {
      cleanupFailed = true;
    }

    try {
      await db.clearAllData();
    } on Object {
      cleanupFailed = true;
    }

    try {
      await ref.read(authNotificationCleanupProvider)();
    } on Object {
      cleanupFailed = true;
    }

    if (cleanupFailed) {
      _localCleanupRequired = true;
      throw StateError('LOCAL_DATA_ISOLATION_FAILED');
    }
  }

  Future<void> _clearFirestoreLocalState() async {
    if (_firestoreLocalStateCleared) return;

    final firestore = ref.read(firestoreProvider);
    try {
      await firestore.clearPersistence();
    } on FirebaseException catch (error) {
      if (error.code != 'failed-precondition') rethrow;
      await firestore.terminate();
      await firestore.clearPersistence();
    }

    _firestoreLocalStateCleared = true;
  }

  Future<void> _recoverPendingLocalCleanup() {
    final running = _durableCleanupRecoveryInFlight;
    if (running != null) return running;

    late final Future<void> operation;
    operation = _performPendingLocalCleanupRecovery().whenComplete(() {
      if (identical(_durableCleanupRecoveryInFlight, operation)) {
        _durableCleanupRecoveryInFlight = null;
      }
    });
    _durableCleanupRecoveryInFlight = operation;
    return operation;
  }

  Future<void> _performPendingLocalCleanupRecovery() async {
    final barrier = ref.read(authCleanupBarrierProvider);
    PendingAuthCleanup? pending;
    try {
      pending = await barrier.readPending();
    } catch (_) {
      _localCleanupRequired = true;
      _clearCycleReminderActionSession();
      throw StateError('LOCAL_CLEANUP_BARRIER_READ_FAILED');
    }
    if (pending == null) return;

    _localCleanupRequired = true;
    try {
      await _runCriticalLocalDataClear(pending.userId);
      _activeLocalSessionUid = null;

      final auth = ref.read(firebaseAuthProvider);
      if (pending.requiresSignOut && auth.currentUser?.uid == pending.userId) {
        await auth.signOut();
        if (auth.currentUser?.uid == pending.userId) {
          throw StateError('AUTH_SIGN_OUT_NOT_CONFIRMED');
        }
        await _runCriticalLocalDataClear(null);
      }

      final wasCleared = await barrier.clearIfCurrent(pending);
      if (!wasCleared) {
        throw StateError('AUTH_CLEANUP_BARRIER_CHANGED');
      }
      _localCleanupRequired = false;
    } catch (_) {
      _localCleanupRequired = true;
      _clearCycleReminderActionSession();
      throw StateError('LOCAL_CLEANUP_RECOVERY_FAILED');
    }
  }

  void _invalidateSessionProviders() {
    ref.invalidate(financeStreamProvider);
    ref.invalidate(tasksStreamProvider);
    ref.invalidate(tasksProvider);
    ref.invalidate(habitsStreamProvider);
    ref.invalidate(goalsStreamProvider);
    ref.invalidate(checkInStreamProvider);
    ref.invalidate(healthStreamProvider);
    ref.invalidate(medicationsStreamProvider);
    ref.invalidate(studyStreamProvider);
    ref.invalidate(subjectsStreamProvider);
    ref.invalidate(flashcardStreamProvider);
    ref.invalidate(focusProvider);
    ref.invalidate(circlesProvider);
    ref.invalidate(aiCompanionProvider);
    ref.invalidate(aiConsentProvider);
    ref.invalidate(premiumProvider);
    ref.invalidate(dashboardStateProvider);
  }
}

final authNotifierProvider = NotifierProvider<AuthNotifier, AuthState>(
  AuthNotifier.new,
);
