import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';
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

// Provider do repositório
final authRepositoryProvider = Provider<AuthRepository>((ref) {
  return AuthRepositoryImpl(
    ref.watch(firebaseAuthProvider),
    ref.watch(firestoreProvider),
  );
});

// Refatorado para Notifier
class AuthNotifier extends Notifier<AuthState> {
  AuthRepository get _repository => ref.read(authRepositoryProvider);
  SecureStorageService get _secureStorage =>
      ref.read(secureStorageServiceProvider);

  @override
  AuthState build() {
    _initializeAuthListener();
    return AuthState.initial();
  }

  void _initializeAuthListener() {
    final auth = ref.read(firebaseAuthProvider);

    checkCurrentUser();

    final subscription = auth.authStateChanges().listen((firebaseUser) async {
      if (firebaseUser == null) {
        await _secureStorage.deleteToken();
        await _clearLocalData();
        state.maybeWhen(
          unauthenticated: () {},
          orElse: () => state = AuthState.unauthenticated(),
        );
      } else {
        final token = await firebaseUser.getIdToken();
        if (token != null) {
          await _secureStorage.saveToken(token);
        }
      }
    });

    ref.onDispose(() {
      subscription.cancel();
    });
  }

  // --- Função Helper para centralizar a Hidratação de todos os módulos ---
  void _hydrateAllOfflineData() {
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
        final firebaseUser = ref.read(firebaseAuthProvider).currentUser;
        if (firebaseUser != null) {
          final token = await firebaseUser.getIdToken();
          if (token != null) {
            await _secureStorage.saveToken(token);
          }
        }
        state = AuthState.authenticated(user);
        _hydrateAllOfflineData();
      },
      (failure) async {
        await _secureStorage.deleteToken();
        state = AuthState.unauthenticated();
      },
    );
  }

  Future<void> login(String email, String password) async {
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
      await _clearLocalData();

      ref.invalidate(financeStreamProvider);
      ref.invalidate(tasksStreamProvider);
      ref.invalidate(habitsStreamProvider);
      ref.invalidate(dashboardStateProvider);
      ref.invalidate(checkInStreamProvider);

      state = AuthState.unauthenticated();
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
            state = AuthState.error(
              'A senha atual e obrigatoria para confirmar a exclusao.',
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
          await _clearLocalData();
          state = AuthState.unauthenticated();
        },
        (failure) async {
          state = AuthState.error(failure.message);
        },
      );
    } on FirebaseAuthException catch (e) {
      if (e.code == 'wrong-password') {
        state = AuthState.error('Senha incorreta. Tente novamente.');
      } else if (e.code == 'requires-recent-login') {
        state = AuthState.error(
          'Sessao expirada. Faca login novamente e tente de novo.',
        );
      } else {
        state = AuthState.error(
          e.message ?? 'Ocorreu um erro de reautenticacao.',
        );
      }
    } catch (e) {
      state = AuthState.error('Erro ao deletar conta: $e');
    }
  }

  Future<void> _clearLocalData() async {
    try {
      await _secureStorage.deleteAll();
      final db = ref.read(databaseProvider);
      await db.clearAllData();
    } catch (e) {
      print("Erro ao limpar dados locais: $e");
    }
  }
}

final authNotifierProvider = NotifierProvider<AuthNotifier, AuthState>(
  AuthNotifier.new,
);
