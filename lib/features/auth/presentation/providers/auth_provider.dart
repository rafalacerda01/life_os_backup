import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:life_os/core/services/notification_service.dart';
import 'package:life_os/core/services/sync_manager_provider.dart';
// Imports dos providers de todos os módulos
import 'package:life_os/features/finance/presentation/providers/finance_provider.dart';
import 'package:life_os/features/tasks/presentation/providers/tasks_provider.dart';
import 'package:life_os/features/habits/presentation/providers/habits_provider.dart';
import 'package:life_os/features/goals/presentation/goals_provider.dart';
import 'package:life_os/features/checkin/presentation/providers/check_in_provider.dart';
import 'package:life_os/features/health/presentation/providers/health_provider.dart';
import 'package:life_os/features/focus/presentation/providers/providers/focus_provider.dart';

import 'package:life_os/features/dashboard/presentation/providers/dashboard_provider.dart';
import 'package:life_os/features/auth/data/repositories/auth_repository_impl.dart';
import 'package:life_os/features/auth/data/remote/account_remote_data_source.dart';
import 'package:life_os/features/auth/domain/repositories/auth_repository.dart';
import 'package:life_os/features/auth/presentation/providers/auth_state.dart';
import 'package:life_os/core/storage/secure_storage_service.dart';
import 'package:life_os/core/database/database_provider.dart';

// Providers de infraestrutura
final firebaseAuthProvider = Provider((ref) => FirebaseAuth.instance);
final firestoreProvider = Provider((ref) => FirebaseFirestore.instance);

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
    idTokenProvider: () async {
      final user = ref.read(firebaseAuthProvider).currentUser;
      return user?.getIdToken(true);
    },
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
  Future<void>? _localCleanupInFlight;

  @override
  AuthState build() {
    _disposed = false;
    _initializeAuthListener();
    return AuthState.initial();
  }

  void _initializeAuthListener() {
    final auth = ref.read(firebaseAuthProvider);

    checkCurrentUser();

    final subscription = auth.authStateChanges().listen((firebaseUser) async {
      if (firebaseUser == null) {
        if (_accountDeletionInProgress) return;
        await _finishLocalSignOut();
      } else if (!_accountDeletionInProgress) {
        final token = await firebaseUser.getIdToken();
        if (token != null) {
          await _secureStorage.saveToken(token);
        }
      }
    });

    ref.onDispose(() {
      _disposed = true;
      subscription.cancel();
    });
  }

  // --- Função Helper para centralizar a Hidratação de todos os módulos ---
  void _hydrateAllOfflineData() {
    if (_disposed || _accountDeletionInProgress) return;
    try {
      ref.read(financeRepositoryProvider).syncTransactionsFromFirestore();
      ref.read(tasksRepositoryProvider).syncTasksFromFirebaseToLocal();
      ref.read(habitsRepositoryProvider).syncHabitsFromFirebaseToLocal();
      ref.read(goalRepositoryProvider).syncGoalsFromFirebaseToLocal();
      ref.read(checkInRepositoryProvider).syncCheckinsFromFirebaseToLocal();
      ref.read(healthRepositoryProvider).syncHealthFromFirebase();
      ref.read(focusRepositoryProvider).syncFocusFromFirebaseToLocal();

      ref.read(syncManagerProvider).processPendingItems();
    } catch (e) {
      print("Erro ao tentar hidratar dados na inicialização: $e");
    }
  }

  // --- Métodos de Autenticação e Perfil ---
  Future<void> checkCurrentUser() async {
    final result = await _repository.getCurrentUser();
    result.when(
      (user) async {
        if (_disposed || _accountDeletionInProgress) return;
        final firebaseUser = ref.read(firebaseAuthProvider).currentUser;
        if (firebaseUser != null) {
          final token = await firebaseUser.getIdToken();
          if (token != null) {
            await _secureStorage.saveToken(token);
          }
        }
        if (_disposed || _accountDeletionInProgress) return;
        state = AuthState.authenticated(user);
        _hydrateAllOfflineData();
      },
      (failure) async {
        if (_disposed || _accountDeletionInProgress) return;
        await _secureStorage.deleteToken();
        if (_disposed || _accountDeletionInProgress) return;
        state = AuthState.unauthenticated();
      },
    );
  }

  Future<void> login(String email, String password) async {
    _accountDeletionInProgress = false;
    state = AuthState.loading();
    final result = await _repository.signInWithEmailAndPassword(
      email,
      password,
    );
    result.when((user) async {
      final firebaseUser = ref.read(firebaseAuthProvider).currentUser;
      final token = await firebaseUser?.getIdToken();
      if (token != null) {
        await _secureStorage.saveToken(token);
      }
      state = AuthState.authenticated(user);
      _hydrateAllOfflineData();
    }, (failure) => state = AuthState.error(failure.message));
  }

  Future<void> register(String email, String password, String name) async {
    _accountDeletionInProgress = false;
    state = AuthState.loading();
    final result = await _repository.signUpWithEmailAndPassword(
      email,
      password,
      name,
    );
    result.when((user) async {
      final firebaseUser = ref.read(firebaseAuthProvider).currentUser;
      final token = await firebaseUser?.getIdToken();
      if (token != null) {
        await _secureStorage.saveToken(token);
      }
      state = AuthState.authenticated(user);
      _hydrateAllOfflineData();
    }, (failure) => state = AuthState.error(failure.message));
  }

  Future<void> signInWithGoogle() async {
    _accountDeletionInProgress = false;
    state = AuthState.loading();
    final result = await _repository.signInWithGoogle();
    result.when((user) async {
      final firebaseUser = ref.read(firebaseAuthProvider).currentUser;
      final token = await firebaseUser?.getIdToken();
      if (token != null) {
        await _secureStorage.saveToken(token);
      }
      state = AuthState.authenticated(user);
      _hydrateAllOfflineData();
    }, (failure) => state = AuthState.error(failure.message));
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
    final result = await _repository.signOut();

    result.when((_) async {
      await _finishLocalSignOut();
    }, (failure) => state = AuthState.error(failure.message));
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
    _accountDeletionInProgress = true;
    state = AuthState.loading();

    try {
      final user = ref.read(firebaseAuthProvider).currentUser;

      if (user != null) {
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
      }

      final result = await _repository.deleteAccount();

      result.when(
        (success) async {
          await _finishLocalSignOut();
        },
        (failure) async {
          _accountDeletionInProgress = false;
          if (!_disposed) state = AuthState.error(failure.message);
        },
      );
    } on FirebaseAuthException catch (e) {
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
      _accountDeletionInProgress = false;
      if (_disposed) return;
      state = AuthState.error(
        'Não foi possível excluir a conta. Tente novamente.',
      );
    }
  }

  Future<void> _finishLocalSignOut() async {
    if (_disposed) return;
    await _clearLocalData();
    if (_disposed) return;

    ref.invalidate(financeStreamProvider);
    ref.invalidate(tasksStreamProvider);
    ref.invalidate(habitsStreamProvider);
    ref.invalidate(dashboardStateProvider);
    ref.invalidate(checkInStreamProvider);

    state.maybeWhen(
      unauthenticated: () {},
      orElse: () => state = AuthState.unauthenticated(),
    );
  }

  Future<void> _clearLocalData() {
    final running = _localCleanupInFlight;
    if (running != null) return running;

    late final Future<void> operation;
    operation = _performLocalDataClear().whenComplete(() {
      if (identical(_localCleanupInFlight, operation)) {
        _localCleanupInFlight = null;
      }
    });
    _localCleanupInFlight = operation;
    return operation;
  }

  Future<void> _performLocalDataClear() async {
    final secureStorage = _secureStorage;
    final db = ref.read(databaseProvider);

    try {
      await secureStorage.deleteAll();
    } catch (_) {
      // Os demais dados locais ainda precisam ser removidos.
    }

    try {
      await db.clearAllData();
    } catch (_) {
      // O cancelamento de notificações continua sendo necessário.
    }

    await NotificationService.instance.cancelAllNotifications();
  }
}

final authNotifierProvider = NotifierProvider<AuthNotifier, AuthState>(
  AuthNotifier.new,
);
