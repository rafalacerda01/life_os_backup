import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:life_os/core/services/notification_service.dart';
import 'package:life_os/core/services/firebase_auth_provider.dart';
import 'package:life_os/core/services/analytics_service.dart';
import 'package:life_os/core/services/sync_manager_provider.dart';
import 'package:life_os/core/utils/app_logger.dart';
import 'package:life_os/core/security/input_sanitizer.dart';
// Imports dos providers de todos os módulos
import 'package:life_os/features/finance/presentation/providers/finance_provider.dart';
import 'package:life_os/features/tasks/presentation/providers/tasks_provider.dart';
import 'package:life_os/features/habits/presentation/providers/habits_provider.dart';
import 'package:life_os/features/goals/presentation/goals_provider.dart';
import 'package:life_os/features/checkin/presentation/providers/check_in_provider.dart';
import 'package:life_os/features/health/presentation/providers/health_provider.dart';
import 'package:life_os/features/health/services/cycle_reminder_action_coordinator.dart';
import 'package:life_os/features/health/services/cycle_reminder_session_reconciler.dart';
import 'package:life_os/features/health/services/cycle_reminder_session_cleanup.dart';
import 'package:life_os/features/health/services/medication_reminder_session_reconciler.dart';
import 'package:life_os/features/health/services/medication_reminder_providers.dart';
import 'package:life_os/features/focus/presentation/providers/providers/focus_provider.dart';
import 'package:life_os/features/study/presentation/providers/study_provider.dart';
import 'package:life_os/features/tasks/presentation/providers/tasks_notifier.dart';
import 'package:life_os/features/ai_companion/presentation/providers/ai_companion_provider.dart';
import 'package:life_os/features/ai_companion/presentation/providers/ai_consent_provider.dart';
import 'package:life_os/features/circles/presentation/circles_provider.dart';
import 'package:life_os/features/premium/presentation/premium_provider.dart';
import 'package:life_os/features/settings/presentation/providers/analytics_provider.dart';
import 'package:life_os/features/notifications/domain/providers/notification_engine.dart';
import 'package:life_os/features/notifications/data/repositories/notifications_repository.dart';

import 'package:life_os/features/dashboard/presentation/providers/dashboard_provider.dart';
import 'package:life_os/features/auth/data/repositories/auth_repository_impl.dart';
import 'package:life_os/features/auth/data/remote/account_remote_data_source.dart';
import 'package:life_os/features/auth/data/local/auth_cleanup_barrier.dart';
import 'package:life_os/features/auth/data/services/google_sign_in_initializer.dart';
import 'package:life_os/features/auth/domain/entities/user_entity.dart';
import 'package:life_os/features/auth/domain/repositories/auth_repository.dart';
import 'package:life_os/features/auth/presentation/providers/auth_state.dart';
import 'package:life_os/core/storage/secure_storage_service.dart';
import 'package:life_os/core/database/database_provider.dart';
import 'package:life_os/core/database/local_mutation_gate.dart';
import 'package:life_os/core/database/session_database_coordinator.dart';

// Providers de infraestrutura
export 'package:life_os/core/services/firebase_auth_provider.dart';
export 'package:life_os/features/health/services/medication_reminder_providers.dart'
    show medicationReminderSessionReconcilerProvider;

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
  bool _authResultReconciliationInProgress = false;
  int _sessionGeneration = 0;
  MedicationReminderSessionReconciler? _medicationReconciler;
  Future<void> _preparationTail = Future<void>.value();

  SessionDatabaseCoordinator get _databases =>
      ref.read(sessionDatabaseCoordinatorProvider);

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
      _databases.observeSession(firebaseUser?.uid);
      if (firebaseUser == null) {
        if (_accountDeletionInProgress || _explicitSignOutInProgress) return;
        state = AuthState.loading();
        _localCleanupRequired = true;
        await _finishLocalSignOut();
      } else if (!_accountDeletionInProgress && !_explicitSignOutInProgress) {
        if (_activeLocalSessionUid != firebaseUser.uid) {
          state = AuthState.loading();
        }
        if (await _prepareAuthenticatedSession(firebaseUser)) {
          await checkCurrentUser();
        }
      }
    });

    ref.onDispose(() {
      _disposed = true;
      _medicationReconciler?.onSessionCleared();
      subscription.cancel();
    });
  }

  void _scheduleHydration(String uid) {
    final cleanUid = uid.trim();

    if (cleanUid.isEmpty ||
        _disposed ||
        _accountDeletionInProgress ||
        _explicitSignOutInProgress)
      return;

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

      var checkInsDrained = false;
      try {
        checkInsDrained = await ref
            .read(checkInRepositoryProvider)
            .syncPendingCheckIns();
      } catch (_) {
        // Um módulo offline indisponível não bloqueia os demais pulls.
      }
      if (!_isCurrentSession(uid, generation)) return;
      if (checkInsDrained) {
        try {
          await ref
              .read(checkInRepositoryProvider)
              .syncCheckinsFromFirebaseToLocal();
        } catch (_) {
          // Falha de Check-ins não interrompe a hidratação dos demais módulos.
        }
        if (!_isCurrentSession(uid, generation)) return;
      }

      final pulls = <Future<void> Function()>[
        () =>
            ref.read(financeRepositoryProvider).syncTransactionsFromFirestore(),
        () => ref.read(tasksRepositoryProvider).syncTasksFromFirebaseToLocal(),
        () =>
            ref.read(habitsRepositoryProvider).syncHabitsFromFirebaseToLocal(),
        () => ref.read(goalRepositoryProvider).syncGoalsFromFirebaseToLocal(),
        () => ref.read(healthRepositoryProvider).syncHealthFromFirebase(),
        () => ref.read(studyRepositoryProvider).syncStudyFromFirebaseToLocal(),
        () => ref.read(focusRepositoryProvider).syncFocusFromFirebaseToLocal(),
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
        !_explicitSignOutInProgress &&
        generation == _sessionGeneration &&
        ref.read(firebaseAuthProvider).currentUser?.uid == uid;
  }

  Future<T> _serializeLocalSession<T>(Future<T> Function() action) {
    final result = _preparationTail.then((_) => action());
    _preparationTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<bool> _prepareAuthenticatedSession(User firebaseUser) =>
      _serializeLocalSession(() => _performSessionPreparation(firebaseUser));

  Future<bool> _performSessionPreparation(User firebaseUser) async {
    if (_disposed || _accountDeletionInProgress || _explicitSignOutInProgress) {
      return false;
    }

    final uid = firebaseUser.uid;
    if (ref.read(firebaseAuthProvider).currentUser?.uid != uid) return false;
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

    if (_activeLocalSessionUid == uid && !_localCleanupRequired) {
      try {
        _databases.requirePrepared();
        return true;
      } on SessionDatabaseUnavailable {
        // A failed/incomplete detach must be resolved by the coordinator.
      }
    }

    try {
      await _databases.prepare(
        uid,
        beforePublish: () async {
          String? token;
          try {
            token = await firebaseUser.getIdToken();
          } on FirebaseAuthException catch (error) {
            if (error.code != 'network-request-failed') rethrow;
          }
          if (_disposed ||
              ref.read(firebaseAuthProvider).currentUser?.uid != uid) {
            throw const SessionDatabaseUnavailable();
          }
          if (token != null) await _secureStorage.saveToken(token);
        },
      );
    } catch (_) {
      if (!_disposed) {
        state = AuthState.error('Não foi possível proteger a sessão local.');
      }
      return false;
    }

    final isPrepared =
        !_disposed &&
        !_localCleanupRequired &&
        !_explicitSignOutInProgress &&
        !_accountDeletionInProgress &&
        ref.read(firebaseAuthProvider).currentUser?.uid == uid;

    if (isPrepared) {
      if (!ref.read(notificationRemoteEffectsBarrierProvider).resume()) {
        return false;
      }
      _databases.requirePrepared();
      _activeLocalSessionUid = uid;
      _firestoreLocalStateCleared = false;
      try {
        ref.read(premiumProvider);
      } catch (_) {
        // Falha fechada: sem listener válido, nenhum entitlement é concedido.
        AppLogger.w('[Billing] Falha ao iniciar monitoramento Premium.');
      }
      _notifyCycleReminderActionSessionPrepared(uid);
      _restoreCycleReminderForPreparedSession(uid);
      _restoreMedicationRemindersForPreparedSession(uid);
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
    _medicationReconciler?.onSessionCleared();
  }

  void _restoreMedicationRemindersForPreparedSession(String uid) {
    try {
      final reconciler = ref.read(medicationReminderSessionReconcilerProvider);
      _medicationReconciler = reconciler;
      unawaited(reconciler.onSessionPrepared(uid));
    } on Object {
      AppLogger.w('Falha ao iniciar lembretes locais de medicamentos.');
    }
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
    final restoredUser = ref.read(firebaseAuthProvider).currentUser;
    final result = await _repository.getCurrentUser();
    await result.when(
      (user) async {
        if (_disposed || _accountDeletionInProgress) return;
        await _publishAuthenticatedResult(user);
      },
      (failure) async {
        if (_disposed || _accountDeletionInProgress) return;
        if (failure.code == 'NETWORK_ERROR' &&
            restoredUser != null &&
            restoredUser.uid.trim().isNotEmpty &&
            ref.read(firebaseAuthProvider).currentUser?.uid ==
                restoredUser.uid) {
          final displayName = InputSanitizer.sanitize(restoredUser.displayName);
          await _publishAuthenticatedResult(
            UserEntity(
              uid: restoredUser.uid,
              email: InputSanitizer.sanitize(restoredUser.email),
              displayName: displayName.isEmpty ? 'Usuário' : displayName,
              photoUrl: restoredUser.photoURL,
              isPremium: false,
              xp: 0,
              level: 1,
              streak: 0,
            ),
          );
          return;
        }
        await _handleAuthenticationFailure(
          failure.message,
          finishLocalSignOutWhenNoUser: true,
        );
      },
    );
  }

  Future<bool> _publishAuthenticatedResult(
    UserEntity user, {
    bool allowReconciliation = true,
    bool sessionAlreadyPrepared = false,
  }) async {
    if (_disposed || _accountDeletionInProgress) return false;

    final expectedUid = user.uid;
    final firebaseUser = ref.read(firebaseAuthProvider).currentUser;
    if (expectedUid.trim().isEmpty ||
        firebaseUser == null ||
        firebaseUser.uid != expectedUid) {
      if (allowReconciliation) {
        await _reconcileCurrentFirebaseSession();
      } else {
        _setInvalidAuthSessionState();
      }
      return false;
    }

    if (!sessionAlreadyPrepared &&
        !await _prepareAuthenticatedSession(firebaseUser)) {
      final currentUid = ref.read(firebaseAuthProvider).currentUser?.uid;
      if (allowReconciliation &&
          currentUid != null &&
          currentUid != expectedUid) {
        await _reconcileCurrentFirebaseSession();
      }
      return false;
    }

    if (_disposed || _accountDeletionInProgress) return false;
    if (ref.read(firebaseAuthProvider).currentUser?.uid != expectedUid) {
      if (allowReconciliation) {
        await _reconcileCurrentFirebaseSession();
      } else {
        _setInvalidAuthSessionState();
      }
      return false;
    }

    state = AuthState.authenticated(user);
    _scheduleHydration(expectedUid);
    return true;
  }

  Future<void> _reconcileCurrentFirebaseSession() async {
    if (_disposed ||
        _accountDeletionInProgress ||
        _authResultReconciliationInProgress) {
      return;
    }

    _authResultReconciliationInProgress = true;
    state = AuthState.loading();
    try {
      final firebaseUser = ref.read(firebaseAuthProvider).currentUser;
      final expectedUid = firebaseUser?.uid ?? '';
      if (firebaseUser == null || expectedUid.trim().isEmpty) {
        await _finishLocalSignOut();
        return;
      }

      if (!await _prepareAuthenticatedSession(firebaseUser)) return;
      if (_disposed || _accountDeletionInProgress) return;
      if (ref.read(firebaseAuthProvider).currentUser?.uid != expectedUid) {
        _setInvalidAuthSessionState();
        return;
      }

      final result = await _repository.getCurrentUser();
      await result.when(
        (user) => _publishAuthenticatedResult(
          user,
          allowReconciliation: false,
          sessionAlreadyPrepared: true,
        ),
        (failure) async {
          if (!_disposed && !_accountDeletionInProgress) {
            state = AuthState.error(failure.message);
          }
        },
      );
    } finally {
      _authResultReconciliationInProgress = false;
    }
  }

  void _setInvalidAuthSessionState() {
    if (_disposed || _accountDeletionInProgress) return;
    state = AuthState.error(
      'Sua sessão não é válida. Entre novamente e tente de novo.',
    );
  }

  Future<void> _handleAuthenticationFailure(
    String message, {
    bool finishLocalSignOutWhenNoUser = false,
  }) async {
    if (_disposed || _accountDeletionInProgress) return;
    if (ref.read(firebaseAuthProvider).currentUser != null) {
      await _reconcileCurrentFirebaseSession();
      return;
    }

    if (finishLocalSignOutWhenNoUser) {
      await _finishLocalSignOut();
      return;
    }

    state = _entryFailureState(message);
  }

  AuthState _entryFailureState(String message) {
    final isPublicEntry =
        ref.read(firebaseAuthProvider).currentUser == null &&
        _activeLocalSessionUid == null &&
        !_localCleanupRequired &&
        !_explicitSignOutInProgress &&
        !_accountDeletionInProgress &&
        !_authResultReconciliationInProgress &&
        _localCleanupInFlight == null &&
        _durableCleanupRecoveryInFlight == null;
    return AuthState.error(
      message,
      scope: isPublicEntry
          ? AuthErrorScope.publicEntry
          : AuthErrorScope.protectedSession,
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
        if (await _publishAuthenticatedResult(user)) {
          unawaited(analytics.logLogin(method: AnalyticsAuthMethod.email));
        }
      },
      (failure) async {
        await _handleAuthenticationFailure(failure.message);
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
        if (await _publishAuthenticatedResult(user)) {
          unawaited(analytics.logSignUp(method: AnalyticsAuthMethod.email));
        }
      },
      (failure) async {
        await _handleAuthenticationFailure(failure.message);
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
        if (await _publishAuthenticatedResult(user)) {
          unawaited(analytics.logLogin(method: AnalyticsAuthMethod.google));
        }
      },
      (failure) async {
        await _handleAuthenticationFailure(failure.message);
      },
    );
  }

  Future<void> updateDisplayName(String newName) async {
    await updateProfile(newName: newName);
  }

  Future<void> updateProfile({String? newName, String? newPhotoUrl}) async {
    await state.maybeWhen(
      authenticated: (user) async {
        final expectedUid = user.uid.trim();
        final result = await _repository.updateProfile(
          newName ?? user.displayName ?? '',
          expectedUid: expectedUid,
          newPhotoUrl: newPhotoUrl,
        );

        if (_disposed) return;
        result.when((updatedUser) {
          if (updatedUser.uid != expectedUid ||
              ref.read(firebaseAuthProvider).currentUser?.uid != expectedUid) {
            state = AuthState.error(
              'Sua sessão não é válida. Entre novamente e tente de novo.',
            );
            return;
          }
          state = AuthState.authenticated(updatedUser);
        }, (failure) => state = AuthState.error(failure.message));
      },
      orElse: () async {},
    );
  }

  Future<void> logout() async {
    if (_explicitSignOutInProgress || _accountDeletionInProgress) return;
    state = AuthState.loading();
    final firebaseAuth = ref.read(firebaseAuthProvider);
    final logoutUserId =
        _activeLocalSessionUid ?? firebaseAuth.currentUser?.uid;
    _explicitSignOutInProgress = true;
    PendingAuthCleanup? logoutMarker;
    LocalMutationQuiescence? quiescence;
    var keepMutationGateSealed = false;

    try {
      // Seal admission before even the durable marker read can yield.
      if (!_localCleanupRequired &&
          logoutUserId != null &&
          firebaseAuth.currentUser?.uid == logoutUserId) {
        quiescence = _databases.requirePrepared().localMutations.beginQuiesce(
          logoutUserId,
        );
      }
      if (_localCleanupRequired ||
          await ref.read(authCleanupBarrierProvider).readPending() != null) {
        await _recoverPendingLocalCleanup(useRepositorySignOut: true);
        quiescence = null;
        if (_disposed) return;
        if (firebaseAuth.currentUser == null) {
          if (_localCleanupRequired) {
            await _finishLocalSignOut();
          } else {
            _invalidateSessionProviders();
            state = AuthState.unauthenticated();
          }
          return;
        }
        if (_databases.attachedDatabase == null &&
            firebaseAuth.currentUser?.uid == logoutUserId &&
            logoutUserId != null) {
          final restoredUser = firebaseAuth.currentUser!;
          await _databases.prepare(
            logoutUserId,
            beforePublish: () async {
              String? token;
              try {
                token = await restoredUser.getIdToken();
              } on FirebaseAuthException catch (error) {
                if (error.code != 'network-request-failed') rethrow;
              }
              if (_disposed || firebaseAuth.currentUser?.uid != logoutUserId) {
                throw const SessionDatabaseUnavailable();
              }
              if (token != null) await _secureStorage.saveToken(token);
            },
          );
          _activeLocalSessionUid = logoutUserId;
          _firestoreLocalStateCleared = false;
        }
      }
      if (logoutUserId == null ||
          logoutUserId.trim().isEmpty ||
          firebaseAuth.currentUser?.uid != logoutUserId) {
        if (!_disposed) {
          state = AuthState.error('Sua sessão mudou. Tente novamente.');
        }
        return;
      }

      final database = _databases.requirePrepared();
      if (database.identity?.uid != logoutUserId) {
        throw const SessionDatabaseUnavailable();
      }

      // Close admission before the first await. Lazy DB initialization is internal.
      quiescence ??= database.localMutations.beginQuiesce(logoutUserId);
      await quiescence.cleanup(() => database.customSelect('SELECT 1').get());
      if (_disposed || firebaseAuth.currentUser?.uid != logoutUserId) {
        if (!_disposed)
          state = AuthState.error('Sua sessão mudou. Tente novamente.');
        return;
      }
      try {
        await quiescence.drain().timeout(const Duration(seconds: 20));
      } catch (_) {
        if (!_disposed) {
          state = AuthState.error(
            'Não foi possível concluir suas alterações. Tente sair novamente.',
          );
        }
        return;
      }

      bool queueDrained;
      try {
        queueDrained = await ref
            .read(syncManagerProvider)
            .prepareForLocalDataDiscard();
      } catch (_) {
        queueDrained = false;
      }

      if (firebaseAuth.currentUser?.uid != logoutUserId) {
        if (!_disposed) {
          state = AuthState.error('Sua sessão mudou. Tente novamente.');
        }
        return;
      }

      if (!queueDrained) {
        if (!_disposed) {
          state = AuthState.error(
            'Há alterações pendentes que ainda não foram sincronizadas. '
            'Verifique sua conexão e tente sair novamente.',
          );
        }
        return;
      }

      bool checkInsDrained;
      try {
        checkInsDrained = await ref
            .read(checkInRepositoryProvider)
            .syncPendingCheckIns();
      } catch (_) {
        checkInsDrained = false;
      }

      if (firebaseAuth.currentUser?.uid != logoutUserId) {
        if (!_disposed) {
          state = AuthState.error('Sua sessão mudou. Tente novamente.');
        }
        return;
      }

      if (!checkInsDrained) {
        if (!_disposed) {
          state = AuthState.error(
            'Há alterações pendentes que ainda não foram sincronizadas. '
            'Verifique sua conexão e tente sair novamente.',
          );
        }
        return;
      }

      try {
        quiescence.requireCurrentSession();
        logoutMarker = await ref
            .read(authCleanupBarrierProvider)
            .setPending(logoutUserId, AuthCleanupIntent.logout);
        _localCleanupRequired = true;
        await ref
            .read(notificationRemoteEffectsBarrierProvider)
            .sealAndDrain()
            .timeout(const Duration(seconds: 20));
        _clearCycleReminderActionSession();
        _sessionGeneration++;
        await _medicationReconciler?.drain().timeout(
          const Duration(seconds: 20),
        );
      } catch (_) {
        _localCleanupRequired = true;
        try {
          final pending = await ref
              .read(authCleanupBarrierProvider)
              .readPending();
          keepMutationGateSealed =
              pending?.userId == logoutUserId &&
              pending?.requiresSignOut == true;
        } catch (_) {
          keepMutationGateSealed = true;
        }
        if (!_disposed) {
          state = AuthState.error(
            'Não foi possível isolar os dados locais. Tente novamente.',
          );
        }
        return;
      }

      quiescence.requireCurrentSession();
      final result = await _repository.signOut();

      await result.when(
        (_) async {
          try {
            if (firebaseAuth.currentUser != null) {
              throw StateError('AUTH_SIGN_OUT_NOT_CONFIRMED');
            }
            await _runCriticalLocalDataClear(logoutUserId);
            final expectedMarker = logoutMarker;
            if (expectedMarker == null ||
                !await ref
                    .read(authCleanupBarrierProvider)
                    .clearIfCurrent(expectedMarker)) {
              throw StateError('AUTH_CLEANUP_BARRIER_CHANGED');
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
          // No data was destroyed. Cancel the exact intent and reopen A only
          // if Firebase still confirms the same session.
          if (firebaseAuth.currentUser?.uid == logoutUserId &&
              logoutMarker != null) {
            try {
              if (!await ref
                  .read(authCleanupBarrierProvider)
                  .clearIfCurrent(logoutMarker)) {
                throw StateError('AUTH_CLEANUP_BARRIER_CHANGED');
              }
              _restorePreparedSessionAfterLogoutAbort(logoutUserId);
              _localCleanupRequired = false;
              keepMutationGateSealed = false;
            } catch (_) {
              _localCleanupRequired = true;
              keepMutationGateSealed = true;
            }
          }
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
      quiescence?.finish(
        signOutConfirmed: firebaseAuth.currentUser == null,
        keepSealed: keepMutationGateSealed,
      );
      _explicitSignOutInProgress = false;
    }
  }

  void _restorePreparedSessionAfterLogoutAbort(String uid) {
    if (_disposed || ref.read(firebaseAuthProvider).currentUser?.uid != uid) {
      throw const SessionDatabaseUnavailable();
    }
    _databases.requirePrepared();
    if (!ref.read(notificationRemoteEffectsBarrierProvider).resume()) {
      throw const SessionDatabaseUnavailable();
    }
    _notifyCycleReminderActionSessionPrepared(uid);
    _restoreCycleReminderForPreparedSession(uid);
    _restoreMedicationRemindersForPreparedSession(uid);
  }

  Future<bool> resetPassword(String email) async {
    state = AuthState.loading();
    final result = await _repository.sendPasswordResetEmail(email);

    return result.when(
      (success) {
        state = AuthState.unauthenticated();
        return true;
      },
      (failure) {
        state = _entryFailureState(failure.message);
        return false;
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
    final notificationEffects = ref.read(
      notificationRemoteEffectsBarrierProvider,
    );
    var notificationEffectsSealed = false;

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
        await googleSignInInitialization;

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

      notificationEffectsSealed = true;
      await notificationEffects.sealAndDrain().timeout(
        const Duration(seconds: 20),
      );
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
    } finally {
      if (notificationEffectsSealed &&
          !_disposed &&
          !_localCleanupRequired &&
          !_accountDeletionInProgress &&
          _isExpectedFirebaseSession(expectedUid)) {
        notificationEffects.resume();
      }
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

      await _clearLocalData(
        targetUserId: expectedUid,
        destroyRows: deletionConfirmed,
      );
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

  Future<void> _finishLocalSignOut() =>
      _serializeLocalSession(_performLocalSignOut);

  Future<void> _performLocalSignOut() async {
    if (_disposed) return;
    _databases.observeSession(ref.read(firebaseAuthProvider).currentUser?.uid);

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
    bool destroyRows = false,
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

    await _runCriticalLocalDataClear(cleanupUserId, destroyRows: destroyRows);
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

  Future<void> _runCriticalLocalDataClear(
    String? cleanupUserId, {
    bool destroyRows = false,
  }) {
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
    operation = _performLocalDataClear(cleanupUserId, destroyRows: destroyRows)
        .whenComplete(() {
          if (identical(_localCleanupInFlight, operation)) {
            _localCleanupInFlight = null;
            _localCleanupInFlightUid = null;
          }
        });
    _localCleanupInFlight = operation;
    _localCleanupInFlightUid = cleanupUserId;
    return operation;
  }

  Future<void> _performLocalDataClear(
    String? cleanupUserId, {
    bool destroyRows = false,
  }) async {
    await ref
        .read(notificationRemoteEffectsBarrierProvider)
        .sealAndDrain()
        .timeout(const Duration(seconds: 20));
    _clearCycleReminderActionSession();
    _sessionGeneration += 1;
    await _medicationReconciler?.drain().timeout(const Duration(seconds: 20));
    final hydration = _hydrationInFlight;

    if (hydration != null) {
      await hydration.timeout(const Duration(seconds: 20));
    }

    await ref
        .read(notificationBootstrapCoordinatorProvider)
        .resetAndDrain()
        .timeout(const Duration(seconds: 20));

    final secureStorage = _secureStorage;
    final db = _databases.attachedDatabase;
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
            .cancelAfterCurrentMutations(
              cleanupUserId,
              intent: destroyRows
                  ? CycleReminderCleanupIntent.accountDeletion
                  : CycleReminderCleanupIntent.sessionExit,
            );
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

    if (destroyRows) {
      try {
        if (db == null || db.identity?.uid != cleanupUserId) {
          throw const SessionDatabaseUnavailable();
        }
        await db.clearAllData();
      } on Object {
        cleanupFailed = true;
      }
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
    if (cleanupUserId != null) {
      await _databases.detach(expectedUid: cleanupUserId);
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

  Future<void> _recoverPendingLocalCleanup({
    bool useRepositorySignOut = false,
  }) {
    final running = _durableCleanupRecoveryInFlight;
    if (running != null) return running;

    late final Future<void> operation;
    operation =
        _performPendingLocalCleanupRecovery(
          useRepositorySignOut: useRepositorySignOut,
        ).whenComplete(() {
          if (identical(_durableCleanupRecoveryInFlight, operation)) {
            _durableCleanupRecoveryInFlight = null;
          }
        });
    _durableCleanupRecoveryInFlight = operation;
    return operation;
  }

  Future<void> _performPendingLocalCleanupRecovery({
    required bool useRepositorySignOut,
  }) async {
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
      final auth = ref.read(firebaseAuthProvider);
      if (pending.requiresSignOut && auth.currentUser?.uid == pending.userId) {
        if (useRepositorySignOut) {
          final result = await _repository.signOut();
          result.when(
            (_) {},
            (_) => throw StateError('AUTH_SIGN_OUT_NOT_CONFIRMED'),
          );
        } else {
          await auth.signOut();
        }
        if (auth.currentUser?.uid == pending.userId) {
          throw StateError('AUTH_SIGN_OUT_NOT_CONFIRMED');
        }
      }

      await _runCriticalLocalDataClear(pending.userId);
      _activeLocalSessionUid = null;

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
    ref.read(notificationBootstrapCoordinatorProvider).reset();
    ref.invalidate(notificationEngineProvider);
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
    ref.invalidate(premiumCatalogProvider);
    ref.invalidate(premiumProvider);
    ref.invalidate(premiumRepositoryProvider);
    ref.invalidate(dashboardStateProvider);
  }
}

final authNotifierProvider = NotifierProvider<AuthNotifier, AuthState>(
  AuthNotifier.new,
);
