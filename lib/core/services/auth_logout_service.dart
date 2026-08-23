import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/database_provider.dart';
import '../database/app_database.dart';
import '../db/db_key_manager.dart';
import '../storage/secure_storage_service.dart';

final authLogoutServiceProvider = Provider<AuthLogoutService>((ref) {
  return AuthLogoutService(
    database: ref.watch(databaseProvider),
    secureStorage: const FlutterSecureStorage(),
  );
});

class AuthLogoutService {
  final AppDatabase database;
  final FlutterSecureStorage secureStorage;
  final FirebaseAuth firebaseAuth;

  AuthLogoutService({
    required this.database,
    required this.secureStorage,
    FirebaseAuth? firebaseAuth,
  }) : firebaseAuth = firebaseAuth ?? FirebaseAuth.instance;

  Future<void> executeLogout() async {
    try {
      // 1. Limpa fisicamente todas as tabelas do Drift SQLite
      await database.clearAllData();

      // 2. Remove apenas a credencial de sessão. A chave técnica do banco
      // precisa sobreviver enquanto o arquivo criptografado existir.
      await secureStorage.delete(key: SecureStorageService.tokenKey);

      // 3. Limpa somente a cópia da chave mantida em memória.
      DbKeyManager.clearCache();

      // 4. Encerra a sessão no Firebase Auth
      await firebaseAuth.signOut();
    } catch (_) {
      throw StateError('LOCAL_LOGOUT_CLEANUP_FAILED');
    }
  }
}
