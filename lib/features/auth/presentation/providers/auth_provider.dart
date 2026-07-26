import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:life_os/features/auth/data/repositories/auth_repository_impl.dart';
import 'package:life_os/features/auth/domain/repositories/auth_repository.dart';
import 'package:life_os/features/auth/presentation/providers/auth_state.dart';
import 'package:life_os/core/storage/secure_storage_service.dart';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

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
        // Remove o token do armazenamento seguro ao detectar perda de sessão
        await _secureStorage.deleteToken();

        state.maybeWhen(
          unauthenticated: () {},
          orElse: () => state = AuthState.unauthenticated(),
        );
      } else {
        // Garante que o token atualizado seja persistido com segurança
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

  Future<void> deleteAccount() async {
    state = AuthState.loading();

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
  }

  Future<void> _clearLocalData() async {
    try {
      await _secureStorage.deleteAll();

      final dbFolder = await getApplicationDocumentsDirectory();
      final file = File(p.join(dbFolder.path, 'life_os.sqlite'));

      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      print("Erro ao limpar dados locais: $e");
    }
  }
}

final authNotifierProvider = NotifierProvider<AuthNotifier, AuthState>(
  AuthNotifier.new,
);
