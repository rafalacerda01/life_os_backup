import 'package:life_os/core/database/local_account_session.dart';
import 'dart:async';
import 'package:life_os/core/services/emulator_account_runtime.dart';
import 'package:life_os/core/services/trusted_account_access.dart';

import 'package:life_os/core/errors/failure.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:life_os/core/services/notification_service.dart';
import 'package:life_os/core/services/firebase_auth_provider.dart';
import 'package:life_os/core/services/analytics_service.dart';
import 'package:life_os/core/services/sync_manager.dart';
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
import 'package:life_os/features/auth/data/local/account_deletion_cleanup_barrier.dart';
import 'package:life_os/features/auth/data/local/account_deletion_storage_cleanup.dart';
import 'package:life_os/core/database/local_database_identity.dart';
import 'package:life_os/features/auth/data/services/google_sign_in_initializer.dart';
import 'package:life_os/features/auth/domain/entities/user_entity.dart';
import 'package:life_os/features/auth/domain/repositories/auth_repository.dart';
import 'package:life_os/features/auth/presentation/providers/auth_state.dart';
import 'package:life_os/core/storage/secure_storage_service.dart';
import 'package:life_os/core/database/database_provider.dart';
import 'package:life_os/core/database/local_mutation_gate.dart';
import 'package:life_os/core/services/water_v2_provider.dart';
import 'package:life_os/core/database/session_database_coordinator.dart';

// Providers de infraestrutura
export 'package:life_os/core/services/firebase_auth_provider.dart';
export 'package:life_os/features/health/services/medication_reminder_providers.dart'
    show medicationReminderSessionReconcilerProvider;

final firestoreProvider = firebaseFirestoreProvider;

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
  final identity = ref.watch(localAccountSessionProvider).identity;
  return identity == null
      ? SecureStorageService(storage)
      : SecureStorageService.scoped(storage, identity);
});

final accountDeletionCleanupBarrierProvider =
    Provider<AccountDeletionCleanupBarrier>((ref) {
      return AccountDeletionCleanupBarrier(
        SecureAuthCleanupBarrierStorage(ref.read(secureStorageProvider)),
        identity: ref.watch(localAccountSessionProvider).identity,
        listKeys: () async =>
            (await ref.read(secureStorageProvider).readAll()).keys.toSet(),
      );
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
    emulatorRuntime: ref.watch(emulatorAccountRuntimeProvider),
  );
});

// Refatorado para Notifier
class AuthNotifier extends Notifier<AuthState> {
  AuthRepository get _repository => ref.read(authRepositoryProvider);
  SecureStorageService get _secureStorage =>
      ref.read(secureStorageServiceProvider);
  bool get _localTasksSession => ref.read(emulatorAccountRuntimeProvider) != null;
  bool _localAuthBusy = false;
  int _localAuthOperation = 0;

  void _initializeLocalTasksAuth() {
    final auth = ref.read(firebaseAuthProvider);
    final subscription = auth.authStateChanges().listen((user) {
      _sessionGeneration++;
      ref.read(localAccountSessionProvider.notifier).clear();
      _databases.observeSession(null);
      _databases.observeSession(user?.uid);
      if (_localAuthBusy || _disposed) return;
      final operation = ++_localAuthOperation;
      unawaited(_restoreLocalTasksSession(operation));
    }, onError: (Object _) {
      if (!_disposed) {
        ref.read(localAccountSessionProvider.notifier).clear();
        _databases.observeSession(null);
        state = AuthState.error('Não foi possível confirmar a sessão.');
      }
    });
    ref.onDispose(() {
      _disposed = true;
      _localAuthOperation++;
      subscription.cancel();
    });
  }

  Future<void> _detachLocalTasksSession() async {
    final previous = _databases.attachedDatabase?.identity;
    ref.read(localAccountSessionProvider.notifier).clear();
    if (previous != null) {
      // Stop the actual Drift consumers before closing their connection. A
      // hidden/paused provider stream can otherwise retain the close drain.
      ref.invalidate(tasksStreamProvider);
      ref.invalidate(habitsStreamProvider);
      ref.invalidate(financeStreamProvider);
      ref.invalidate(goalsStreamProvider);
      ref.invalidate(studyStreamProvider);
      ref.invalidate(subjectsStreamProvider);
      ref.invalidate(flashcardStreamProvider);
      ref.invalidate(healthStreamProvider);
      ref.invalidate(medicationsStreamProvider);
      ref.invalidate(checkInStreamProvider);
      ref.invalidate(localNotificationInboxProvider);
      ref.invalidate(focusProvider);
      await _databases.detach(expectedUid: previous.uid);
    }
    _activeLocalSessionUid = null;
  }

  Future<bool> _prepareLocalTasksSession(User user) => _serializeLocalSession(() async {
    final runtime = ref.read(emulatorAccountRuntimeProvider)!;
    runtime.requireClients(ref.read(firebaseAuthProvider), ref.read(firestoreProvider));
    final generation = _sessionGeneration;
    final identity = await TrustedAccountAccess.admittedIdentity(
        runtime.auth, runtime.store, user.uid);
    if (_disposed || generation != _sessionGeneration || runtime.auth.currentUser?.uid != user.uid) return false;
    final db = await _databases.prepare(user.uid, accountIdentity: identity);
    if (_disposed || generation != _sessionGeneration || runtime.auth.currentUser?.uid != user.uid) {
      await _databases.detach(expectedUid: user.uid);
      return false;
    }
    if (db.identity != identity) throw const SessionDatabaseUnavailable();
    ref.read(localAccountSessionProvider.notifier).bind(identity);
    _activeLocalSessionUid = user.uid;
    return true;
  });

  Future<void> _publishLocalTasksUser(UserEntity user, int operation) async {
    final firebaseUser = ref.read(firebaseAuthProvider).currentUser;
    if (_disposed || operation != _localAuthOperation || firebaseUser?.uid != user.uid) return;
    if (!await _prepareLocalTasksSession(firebaseUser!)) return;
    if (_disposed || operation != _localAuthOperation) return;
    // Resolve only the explicitly enabled resource dependencies outside build.
    // Their streams are disposed when hidden and cannot retain A's values for B.
    final modules=ref.read(emulatorAccountRuntimeProvider)!.enabledModules;
    if(modules.contains('tasks'))ref.read(tasksRepositoryProvider);
    if(modules.contains('habits'))ref.read(habitsRepositoryProvider);
    if(modules.contains('finance'))ref.read(financeRepositoryProvider);
    if(modules.contains('goals'))ref.read(goalRepositoryProvider);
    if(modules.contains('study'))ref.read(studyRepositoryProvider);
    if(modules.contains('health'))ref.read(healthRepositoryProvider);
    if(modules.contains('checkin'))ref.read(checkInRepositoryProvider);
    if(modules.contains('notifications'))ref.read(notificationsRepositoryProvider);
    state = AuthState.authenticated(user);
    // No Premium, reminder, notification-engine or other module initialization.
    // Queue failure does not block the separately protected Tasks pull.
    unawaited(_hydrateLocalTasks());
  }

  Future<void> _hydrateLocalTasks() async {
    final lease = ref.read(localAccountSessionProvider.notifier).capture();
    try {
      await ref.read(syncManagerProvider).processPendingItems();
      lease.requireCurrent();
      await ref.read(tasksRepositoryProvider).syncTasksFromFirebaseToLocal();
    } catch (_) {
      // Existing admitted Drift data stays available; no fabricated ACK.
    }
  }

  Future<void> _restoreLocalTasksSession(int operation) async {
    try {
      if (ref.read(firebaseAuthProvider).currentUser == null) {
        await _detachLocalTasksSession();
        if (!_disposed && operation == _localAuthOperation) state = AuthState.unauthenticated();
        return;
      }
      if (!_disposed) state = AuthState.loading();
      final result = await _repository.getCurrentUser();
      await result.when((user) => _publishLocalTasksUser(user, operation), (failure) async {
        if (!_disposed && operation == _localAuthOperation) state = AuthState.error(failure.message, code: failure.code);
      });
    } catch (_) {
      if (!_disposed && operation == _localAuthOperation) state = AuthState.error('Não foi possível confirmar a sessão.');
    }
  }

  Future<void> _authenticateLocalTasks(String email, String password, {String? name}) async {
    if (_localAuthBusy) return;
    final operation = ++_localAuthOperation;
    _localAuthBusy = true;
    state = AuthState.loading();
    try {
      await _detachLocalTasksSession();
      final result = name == null
          ? await _repository.signInWithEmailAndPassword(email, password)
          : await _repository.signUpWithEmailAndPassword(email, password, name);
      await result.when((user) => _publishLocalTasksUser(user, operation), (failure) async {
        if (!_disposed && operation == _localAuthOperation) state = _entryFailureState(failure.message);
      });
    } catch (_) {
      if (!_disposed && operation == _localAuthOperation) state = AuthState.error('Não foi possível preparar a sessão.');
    } finally {
      _localAuthBusy = false;
    }
  }

  Future<void> _logoutLocalTasks() async {
    if (_localAuthBusy) return;
    _localAuthBusy = true;
    ++_localAuthOperation;
    state = AuthState.loading();
    try {
      final uid = ref.read(firebaseAuthProvider).currentUser?.uid;
      if (uid != null && _databases.attachedDatabase != null) {
        // Stop retries/in-flight work without requiring an upload or deleting.
        if (!await ref.read(syncManagerProvider).prepareForSessionDetach(uid)) {
          throw const SessionDatabaseUnavailable();
        }
      }
      await _detachLocalTasksSession();
      final result = await _repository.signOut();
      result.when((_) {}, (_) => throw StateError('SIGN_OUT_UNCONFIRMED'));
      if (ref.read(firebaseAuthProvider).currentUser != null) throw StateError('SIGN_OUT_UNCONFIRMED');
      if (!_disposed) state = AuthState.unauthenticated();
    } catch (_) {
      if (!_disposed) state = AuthState.error('Não foi possível encerrar a sessão com segurança.');
    } finally {
      _localAuthBusy = false;
    }
  }

  bool _disposed = false;
  bool _accountDeletionInProgress = false;
  bool _explicitSignOutInProgress = false;
  bool _localCleanupRequired = false;
  String? _unconfirmedAccountDeletionUid;
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
    if (ref.watch(emulatorAccountRuntimeProvider) != null) {
      _initializeLocalTasksAuth();
      return ref.read(firebaseAuthProvider).currentUser == null
          ? AuthState.unauthenticated() : AuthState.initial();
    }
    if (TrustedAccountAccess.localSessionClosed) {
      // No identity exists to protect: show onboarding/public entry normally.
      // This does not admit a private session or start any remote hydration.
      if (ref.read(firebaseAuthProvider).currentUser == null) {
        return AuthState.unauthenticated();
      }
      return AuthState.error(
        'Esta coorte aguarda a habilitação segura dos dados locais.',
        code: 'TRUSTED_LOCAL_SESSION_CLOSED',
      );
    }
    _initializeAuthListener();
    return AuthState.initial();
  }

  void _initializeAuthListener() {
    final auth = ref.read(firebaseAuthProvider);
    unawaited(checkCurrentUser());

    final subscription = auth.authStateChanges().listen((firebaseUser) async {
      _sessionGeneration++;
      ref.read(localAccountSessionProvider.notifier).clear();
      _databases.observeSession(null);
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
      await _recoverAccountDeletionCleanup();
    } catch (error) {
      _localCleanupRequired = true;
      if (!_disposed)
        state = error is AccountDeletionUnconfirmedFailure
            ? _unconfirmedDeletionState()
            : AuthState.error(
                'Não foi possível concluir a limpeza da conta. Tente novamente.',
              );
      return false;
    }
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

    if (TrustedAccountAccess.localSessionClosed) {
      state = AuthState.error(
        'O acesso desta coorte aguarda a separação segura dos dados locais.',
        code: 'TRUSTED_LOCAL_SESSION_CLOSED',
      );
      return false;
    }
    LocalDatabaseIdentity accountIdentity;
    try {
      accountIdentity = await TrustedAccountAccess.admittedIdentity(
        ref.read(firebaseAuthProvider),
        FirebaseFirestore.instance,
        uid,
      );
    } catch (_) {
      if (!_disposed)
        state = AuthState.error(
          'A conta precisa de preparo ou revisão de origem.',
        );
      return false;
    }
    if (_activeLocalSessionUid == uid &&
        !_localCleanupRequired &&
        _databases.snapshot.identity == accountIdentity) {
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
        accountIdentity: accountIdentity,
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
          if (token != null)
            await SecureStorageService.scoped(
              ref.read(secureStorageProvider),
              accountIdentity,
            ).saveToken(token);
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
      ref.read(localAccountSessionProvider.notifier).bind(accountIdentity);
      _activeLocalSessionUid = uid;
      _unconfirmedAccountDeletionUid = null;
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
    if (_localTasksSession) {
      if (_localAuthBusy) return;
      return _restoreLocalTasksSession(++_localAuthOperation);
    }
    if (_disposed || _accountDeletionInProgress) return;
    try {
      await _serializeLocalSession(() async {
        if (_disposed || _accountDeletionInProgress) return;
        await _recoverAccountDeletionCleanup();
      });
    } catch (error) {
      _localCleanupRequired = true;
      if (!_disposed)
        state = error is AccountDeletionUnconfirmedFailure
            ? _unconfirmedDeletionState()
            : AuthState.error(
                'Não foi possível concluir a limpeza da conta. Tente novamente.',
              );
      return;
    }
    if (_disposed || _accountDeletionInProgress) return;
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
          failure,
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
      if (_disposed || _accountDeletionInProgress) return false;
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
            state = AuthState.error(
              failure.message,
              code: failure.code == 'TRUSTED_ACCOUNT_PROVISIONING_PENDING'
                  ? failure.code
                  : null,
            );
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
    Failure failure, {
    bool finishLocalSignOutWhenNoUser = false,
  }) async {
    if (_disposed || _accountDeletionInProgress) return;
    if (failure.code == 'TRUSTED_ACCOUNT_PROVISIONING_PENDING' &&
        ref.read(firebaseAuthProvider).currentUser != null) {
      // Auth succeeded. Keep the session pending until an explicit resume or
      // the existing Auth event asks for the server profile again.
      state = AuthState.error(failure.message, code: failure.code);
      return;
    }
    if (ref.read(firebaseAuthProvider).currentUser != null) {
      await _reconcileCurrentFirebaseSession();
      return;
    }

    if (finishLocalSignOutWhenNoUser) {
      await _finishLocalSignOut();
      return;
    }

    state = _entryFailureState(failure.message);
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
    if (_localTasksSession) return _authenticateLocalTasks(email, password);
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
        await _handleAuthenticationFailure(failure);
      },
    );
  }

  Future<void> register(String email, String password, String name) async {
    if (_localTasksSession) return _authenticateLocalTasks(email, password, name: name);
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
        await _handleAuthenticationFailure(failure);
      },
    );
  }

  Future<void> signInWithGoogle() async {
    if (_localTasksSession) { state = _entryFailureState('Google aguarda homologação.'); return; }
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
        await _handleAuthenticationFailure(failure);
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
    if (_localTasksSession) return _logoutLocalTasks();
    if (_explicitSignOutInProgress || _accountDeletionInProgress) return;
    state = AuthState.loading();
    final firebaseAuth = ref.read(firebaseAuthProvider);
    final logoutUserId =
        _activeLocalSessionUid ?? firebaseAuth.currentUser?.uid;
    _explicitSignOutInProgress = true;
    PendingAuthCleanup? logoutMarker;
    LocalMutationQuiescence? quiescence;
    SyncManager? pausedSyncManager;
    var keepMutationGateSealed = false;

    try {
      if (logoutUserId != null &&
          _unconfirmedAccountDeletionUid == logoutUserId) {
        // An uncertain deletion must never reopen this database just to drain
        // queues. The SDK may still cache a user whose Auth identity is gone.
        if (firebaseAuth.currentUser?.uid == logoutUserId) {
          await firebaseAuth.signOut().timeout(const Duration(seconds: 20));
        }
        await _finishLocalSignOut();
        return;
      }

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
          final restoredIdentity = await TrustedAccountAccess.admittedIdentity(
            firebaseAuth,
            FirebaseFirestore.instance,
            logoutUserId,
          );
          await _databases.prepare(
            logoutUserId,
            accountIdentity: restoredIdentity,
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
              if (token != null)
                await SecureStorageService.scoped(
                  ref.read(secureStorageProvider),
                  restoredIdentity,
                ).saveToken(token);
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

      // Normal logout preserves the account database and every queue status.
      // Stop retries/in-flight processing; remote success is not an exit gate.
      final syncManager = ref.read(syncManagerProvider);
      pausedSyncManager = syncManager;
      final syncStopped = await syncManager
          .prepareForSessionDetach(logoutUserId)
          .timeout(const Duration(seconds: 20));
      if (!syncStopped || firebaseAuth.currentUser?.uid != logoutUserId) {
        if (!_disposed) {
          state = AuthState.error('Sua sessão mudou. Tente novamente.');
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
      if (!_disposed &&
          !_localCleanupRequired &&
          logoutUserId != null &&
          firebaseAuth.currentUser?.uid == logoutUserId) {
        pausedSyncManager?.resumeForPreparedSession(logoutUserId);
      }
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
    // UID-scoped local deletion receipts/preferences cannot attest the new
    // generation. Keep this integration closed before any remote effect.
    if (_databases.attachedDatabase?.identity?.generation != null) {
      state = AuthState.error(
        'A exclusão desta conta aguarda a habilitação segura da limpeza local.',
        code: 'TRUSTED_LOCAL_DELETION_CLOSED',
      );
      return;
    }
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
    PendingAccountDeletion? deletionMarker;
    var remoteCallStarted = false;

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

      deletionMarker = await ref
          .read(accountDeletionCleanupBarrierProvider)
          .request(expectedUid);
      if (!_isExpectedFirebaseSession(expectedUid)) {
        await ref
            .read(accountDeletionCleanupBarrierProvider)
            .clearIfCurrent(deletionMarker);
        await _handleChangedAccountDeletionSession(expectedUid);
        return;
      }
      remoteCallStarted = true;
      final result = await _repository.deleteAccount(expectedUid: expectedUid);

      if (_disposed) return;
      await result.when(
        (success) async {
          final confirmed = await ref
              .read(accountDeletionCleanupBarrierProvider)
              .confirmIfCurrent(deletionMarker!);
          await _finishExpectedAccountDeletion(expectedUid, confirmed);
        },
        (failure) async {
          const nonAmbiguousCodes = {
            'APP_CHECK_REQUIRED',
            'APP_CHECK_INVALID',
            'REAUTHENTICATION_REQUIRED',
            'UNAUTHENTICATED',
            'RATE_LIMITED',
            'CIRCLE_ADMIN_ACTION_REQUIRED',
            'ACCOUNT_STATE_CONFLICT',
          };
          if (!nonAmbiguousCodes.contains(failure.code)) {
            await _serializeLocalSession(
              () => _preserveUnconfirmedAccountDeletion(expectedUid),
            );
            _accountDeletionInProgress = false;
            if (_disposed) return;
            final currentUid = ref.read(firebaseAuthProvider).currentUser?.uid;
            if (currentUid != null && currentUid != expectedUid) {
              await checkCurrentUser();
            } else {
              state = _unconfirmedDeletionState();
            }
            return;
          }
          if (!await ref
              .read(accountDeletionCleanupBarrierProvider)
              .clearIfCurrent(deletionMarker!)) {
            throw StateError('ACCOUNT_DELETION_MARKER_CHANGED');
          }
          if (!_isExpectedFirebaseSession(expectedUid)) {
            await _handleChangedAccountDeletionSession(expectedUid);
            return;
          }
          _accountDeletionInProgress = false;
          if (!_disposed) state = AuthState.error(failure.message);
        },
      );
    } on FirebaseAuthException catch (e) {
      if (deletionMarker != null) {
        _localCleanupRequired = true;
        try {
          await _databases.detach(expectedUid: expectedUid);
        } catch (_) {
          // The durable marker remains authoritative for recovery.
        }
        _accountDeletionInProgress = false;
        if (!_disposed) {
          state = AuthState.error(
            'Não foi possível concluir a exclusão. Tente novamente.',
          );
        }
        return;
      }
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
      if (deletionMarker != null) {
        _localCleanupRequired = true;
        try {
          if (!remoteCallStarted) {
            await ref
                .read(accountDeletionCleanupBarrierProvider)
                .clearIfCurrent(deletionMarker);
          } else {
            await _databases.detach(expectedUid: expectedUid);
          }
        } catch (_) {
          // Preserve the marker and deny preparation until recovery succeeds.
        }
        _accountDeletionInProgress = false;
        if (!_disposed)
          state = AuthState.error(
            'Não foi possível concluir a exclusão. Tente novamente.',
          );
        return;
      }
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

  Future<void> _finishExpectedAccountDeletion(
    String expectedUid,
    PendingAccountDeletion marker,
  ) async {
    await _serializeLocalSession(
      () => _completeConfirmedAccountDeletion(marker),
    );
    _accountDeletionInProgress = false;
    if (_disposed) return;
    _invalidateSessionProviders();
    final current = ref.read(firebaseAuthProvider).currentUser;
    if (current != null && current.uid != expectedUid) {
      await checkCurrentUser();
    } else {
      state = AuthState.unauthenticated();
    }
  }

  Future<void> _recoverAccountDeletionCleanup() async {
    // UID-only markers cannot authorize generation-specific local destruction.
    if (TrustedAccountAccess.localSessionClosed) {
      throw StateError('TRUSTED_LOCAL_SESSION_CLOSED');
    }
    final barrier = ref.read(accountDeletionCleanupBarrierProvider);
    final markers = await barrier.readAll();
    // Stop on the first failure; never clear another identity as compensation.
    for (final confirmed in markers) {
      if (confirmed.phase == AccountDeletionPhase.remoteConfirmed &&
          confirmed.hasAuthoritativeConfirmation) {
        await _completeConfirmedAccountDeletion(confirmed);
      }
    }
    final user = ref.read(firebaseAuthProvider).currentUser;
    if (user == null) return;
    final marker = await barrier.readForUser(user.uid);
    if (marker == null) return;
    if (marker.phase == AccountDeletionPhase.remoteConfirmed &&
        !marker.hasAuthoritativeConfirmation) {
      await _preserveUnconfirmedAccountDeletion(marker.userId);
      throw const AccountDeletionUnconfirmedFailure();
    }
    if (marker.phase == AccountDeletionPhase.requested) {
      if (ref.read(firebaseAuthProvider).currentUser?.uid != marker.userId) {
        // Only the target session can resolve an unconfirmed deletion.
        return;
      }
      try {
        await user.reload().timeout(const Duration(seconds: 20));
        if (ref.read(firebaseAuthProvider).currentUser?.uid != marker.userId) {
          return;
        }
        if (!await barrier.clearIfCurrent(marker))
          throw StateError('ACCOUNT_DELETION_MARKER_CHANGED');
        return;
      } on FirebaseAuthException catch (error) {
        if (error.code != 'user-not-found') rethrow;
        final auth = ref.read(firebaseAuthProvider);
        final currentUid = auth.currentUser?.uid;
        if (currentUid != null && currentUid != marker.userId) return;
        // No authoritative response survived: keep requested, never confirm.
        await _preserveUnconfirmedAccountDeletion(marker.userId);
        if (auth.currentUser?.uid == marker.userId) {
          try {
            await auth.signOut().timeout(const Duration(seconds: 20));
          } catch (_) {
            // The detached database and durable marker still deny admission.
          }
        }
        throw const AccountDeletionUnconfirmedFailure();
      }
    }
    await _completeConfirmedAccountDeletion(marker);
  }

  AuthState _unconfirmedDeletionState() => AuthState.error(
    const AccountDeletionUnconfirmedFailure().message,
    code: AccountDeletionUnconfirmedFailure.failureCode,
    scope: AuthErrorScope.publicEntry,
  );

  // Called within the local-session serialization, including startup recovery.
  // Stop private effects and detach; preserve rows, files, keys and preferences.
  Future<void> _preserveUnconfirmedAccountDeletion(String expectedUid) async {
    if (_disposed) return;
    final activeUid = _activeLocalSessionUid;
    if (activeUid != null && activeUid != expectedUid) {
      await _databases.detach(expectedUid: expectedUid);
      return;
    }
    _unconfirmedAccountDeletionUid = expectedUid;
    _localCleanupRequired = true;
    await _clearLocalData(targetUserId: expectedUid);
    // Keep remote effects sealed until a separately prepared session is valid.
    _localCleanupRequired = true;
    if (!_disposed) _invalidateSessionProviders();
  }

  Future<void> _completeConfirmedAccountDeletion(
    PendingAccountDeletion marker,
  ) async {
    final barrier = ref.read(accountDeletionCleanupBarrierProvider);
    if (marker.phase != AccountDeletionPhase.remoteConfirmed ||
        !marker.hasAuthoritativeConfirmation ||
        await barrier.readForUser(marker.userId) != marker) {
      throw StateError('ACCOUNT_DELETION_NOT_CONFIRMED');
    }
    final previousDeletion = _accountDeletionInProgress;
    _accountDeletionInProgress = true;
    _localCleanupRequired = true;
    // A bound marker must use the scoped journal/ports, never this legacy
    // UID-only cancellation/sign-out sequence. Preserve it while CLOSED.
    if (marker.identity != null)
      throw StateError('GENERATIONAL_CLEANUP_PIPELINE_CLOSED');
    final identity = LocalDatabaseIdentity(marker.userId);
    try {
      final attached = _databases.attachedDatabase;
      final currentUid = ref.read(firebaseAuthProvider).currentUser?.uid;
      final activeUid = _activeLocalSessionUid;
      final hasOtherSession =
          (currentUid != null && currentUid != identity.uid) ||
          (activeUid != null && activeUid != identity.uid) ||
          (attached != null && attached.identity != identity);
      if (!hasOtherSession) {
        // Drain private effects without deleting stores before the files/key.
        await _runCriticalLocalDataClear(identity.uid);
        _activeLocalSessionUid = null;
      } else {
        final failed = await ref
            .read(cycleReminderSessionCleanupProvider)
            .cancelAfterCurrentMutations(identity.uid);
        if (failed > 0) throw StateError('ACCOUNT_NATIVE_CLEANUP_FAILED');
      }
      await _databases.destroy(
        identity,
        () => ref.read(accountDeletionStorageCleanupProvider).destroy(identity),
      );
      if (_activeLocalSessionUid == identity.uid) {
        _activeLocalSessionUid = null;
      }
      final auth = ref.read(firebaseAuthProvider);
      if (auth.currentUser?.uid == identity.uid) {
        await auth.signOut();
        if (auth.currentUser?.uid == identity.uid)
          throw StateError('ACCOUNT_SIGN_OUT_NOT_CONFIRMED');
      }
      if (!await barrier.clearIfCurrent(marker))
        throw StateError('ACCOUNT_DELETION_MARKER_CHANGED');
      _localCleanupRequired = false;
    } finally {
      _accountDeletionInProgress = previousDeletion;
    }
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
      await _recoverAccountDeletionCleanup();
      await _recoverPendingLocalCleanup();
      await _clearLocalData();
      if (_disposed) return;

      _invalidateSessionProviders();
      final unconfirmedUid = _unconfirmedAccountDeletionUid;
      final unconfirmed = unconfirmedUid == null
          ? null
          : await ref
                .read(accountDeletionCleanupBarrierProvider)
                .readForUser(unconfirmedUid);
      if (unconfirmed != null && !unconfirmed.hasAuthoritativeConfirmation) {
        if (!_disposed) state = _unconfirmedDeletionState();
      } else {
        state.maybeWhen(
          unauthenticated: () {},
          orElse: () => state = AuthState.unauthenticated(),
        );
      }
    } catch (error) {
      _localCleanupRequired = true;
      if (!_disposed) {
        state = error is AccountDeletionUnconfirmedFailure
            ? _unconfirmedDeletionState()
            : AuthState.error(
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
    // Capture before any drain. UID-only legacy recovery cannot select a
    // bound database or replace it with whichever session appears later.
    final capturedLocal = ref.read(localAccountSessionProvider);
    final capturedDatabase = _databases.attachedDatabase;
    void validateCaptured() {
      final attached = _databases.attachedDatabase;
      final uid = ref.read(firebaseAuthProvider).currentUser?.uid;
      if (ref.read(localAccountSessionProvider).revision !=
              capturedLocal.revision ||
          attached != null && !identical(attached, capturedDatabase) ||
          uid != null && uid != cleanupUserId)
        throw StateError('LOCAL_CLEANUP_SESSION_CHANGED');
    }

    validateCaptured();
    final capturedIdentity = capturedDatabase?.identity;
    if (capturedIdentity?.generation != null) {
      throw StateError('GENERATIONAL_CLEANUP_PIPELINE_CLOSED');
    }
    if (capturedIdentity != null &&
        cleanupUserId != null &&
        capturedIdentity.uid != cleanupUserId) {
      throw StateError('LOCAL_CLEANUP_USER_CONFLICT');
    }

    await ref
        .read(notificationRemoteEffectsBarrierProvider)
        .sealAndDrain()
        .timeout(const Duration(seconds: 20));
    validateCaptured();
    _clearCycleReminderActionSession();
    _sessionGeneration += 1;
    await _medicationReconciler?.drain().timeout(const Duration(seconds: 20));
    validateCaptured();
    final hydration = _hydrationInFlight;

    if (hydration != null) {
      await hydration.timeout(const Duration(seconds: 20));
    }

    await ref
        .read(notificationBootstrapCoordinatorProvider)
        .resetAndDrain()
        .timeout(const Duration(seconds: 20));

    validateCaptured();
    final secureStorage = _secureStorage;
    final db = capturedDatabase;
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
      validateCaptured();
      final capturedIdentity = db?.identity;
      if (capturedIdentity?.generation != null) {
        if (capturedIdentity?.isBound != true)
          throw StateError('LOCAL_GENERATION_BINDING_REQUIRED');
        await SecureStorageService.scoped(
          ref.read(secureStorageProvider),
          capturedIdentity!,
        ).deleteToken();
      } else {
        await secureStorage.deleteToken();
      }
    } on Object {
      cleanupFailed = true;
    }

    validateCaptured();
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
      validateCaptured();
      await ref.read(authNotificationCleanupProvider)();
      validateCaptured();
    } on Object {
      cleanupFailed = true;
    }

    if (cleanupFailed) {
      _localCleanupRequired = true;
      throw StateError('LOCAL_DATA_ISOLATION_FAILED');
    }
    if (cleanupUserId != null) {
      _invalidateLocalDataStreams();
      await _databases.detach(expectedUid: cleanupUserId);
    }
  }

  Future<void> _clearFirestoreLocalState() async {
    if (ref.read(localAccountSessionProvider).identity != null)
      throw StateError('GLOBAL_FIRESTORE_CACHE_CLEANUP_CLOSED');
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

  // Cancel paused consumers before Drift waits for their done events on close.
  // Durable cleanup and session fences remain in force until detach completes.
  void _invalidateLocalDataStreams() {
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
    ref.invalidate(waterGoalProvider);
    ref.invalidate(waterAdmissionProvider);
  }

  void _invalidateSessionProviders() {
    ref.read(notificationBootstrapCoordinatorProvider).reset();
    _invalidateLocalDataStreams();
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
