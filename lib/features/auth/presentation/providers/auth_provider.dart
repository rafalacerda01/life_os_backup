import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:life_os/features/auth/data/repositories/auth_repository_impl.dart';
import 'package:life_os/features/auth/domain/repositories/auth_repository.dart';
import 'package:life_os/features/auth/presentation/providers/auth_state.dart';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

// Providers de infraestrutura
final firebaseAuthProvider = Provider((ref) => FirebaseAuth.instance);
final firestoreProvider = Provider((ref) => FirebaseFirestore.instance);

// Provider do repositório
final authRepositoryProvider = Provider<AuthRepository>((ref) {
  return AuthRepositoryImpl(
    ref.watch(firebaseAuthProvider),
    ref.watch(firestoreProvider),
  );
});

// Refatorado para Notifier
class AuthNotifier extends Notifier<AuthState> {
  // Acessamos o repositório via ref, sem precisar de construtor
  AuthRepository get _repository => ref.read(authRepositoryProvider);

  @override
  AuthState build() {
    // Inicializa a verificação de sessão de forma assíncrona ao carregar o provider
    _initializeAuthListener();

    // Retorna o estado inicial padrão enquanto checa a sessão no Firestore
    return AuthState.initial();
  }

  /// Configura de forma segura a verificação inicial e escuta mudanças de autenticação
  void _initializeAuthListener() {
    final auth = ref.read(firebaseAuthProvider);

    // Executa a checagem imediata do usuário atual com dados do Firestore
    checkCurrentUser();

    // Escuta alterações futuras no estado do Firebase Auth (ex: expiração de token, logout externo)
    final subscription = auth.authStateChanges().listen((firebaseUser) {
      if (firebaseUser == null) {
        // Apenas atualiza para unauthenticated se o Firebase confirmar nulo e o estado atual não for unauthenticated
        state.maybeWhen(
          unauthenticated: () {},
          orElse: () => state = AuthState.unauthenticated(),
        );
      }
    });

    // Garante que o stream seja cancelado se o provider for destruído
    ref.onDispose(() {
      subscription.cancel();
    });
  }

  // --- Métodos de Autenticação e Perfil ---
  Future<void> checkCurrentUser() async {
    final result = await _repository.getCurrentUser();
    result.when(
      (user) => state = AuthState.authenticated(user),
      (failure) => state = AuthState.unauthenticated(),
    );
  }

  Future<void> login(String email, String password) async {
    state = AuthState.loading();
    final result = await _repository.signInWithEmailAndPassword(
      email,
      password,
    );
    result.when(
      (user) => state = AuthState.authenticated(user),
      (failure) => state = AuthState.error(failure.message),
    );
  }

  Future<void> register(String email, String password, String name) async {
    state = AuthState.loading();
    final result = await _repository.signUpWithEmailAndPassword(
      email,
      password,
      name,
    );
    result.when(
      (user) => state = AuthState.authenticated(user),
      (failure) => state = AuthState.error(failure.message),
    );
  }

  Future<void> signInWithGoogle() async {
    state = AuthState.loading();
    final result = await _repository.signInWithGoogle();
    result.when(
      (user) => state = AuthState.authenticated(user),
      (failure) => state = AuthState.error(failure.message),
    );
  }

  // Mantido para compatibilidade caso seja chamado isoladamente
  Future<void> updateDisplayName(String newName) async {
    await updateProfile(newName: newName);
  }

  // Método unificado para atualizar nome e foto de perfil simultaneamente
  Future<void> updateProfile({String? newName, String? newPhotoUrl}) async {
    await state.maybeWhen(
      authenticated: (user) async {
        // ✅ Corrigido para passar o newPhotoUrl ao repositório do Firestore
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
    result.when(
      (_) => state = AuthState.unauthenticated(),
      (failure) => state = AuthState.error(failure.message),
    );
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
      // Limpa as chaves de criptografia do dispositivo
      await const FlutterSecureStorage().deleteAll();

      // Deleta o arquivo do banco de dados (Drift)
      final dbFolder = await getApplicationDocumentsDirectory();
      final file = File(p.join(dbFolder.path, 'life_os.sqlite'));

      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      // Log de erro silencioso, já que o usuário está sendo deslogado de qualquer forma
      print("Erro ao limpar dados locais: $e");
    }
  }
}

// Atualizado para NotifierProvider
final authNotifierProvider = NotifierProvider<AuthNotifier, AuthState>(
  AuthNotifier.new,
);
