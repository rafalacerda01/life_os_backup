import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/database_provider.dart';
import '../database/app_database.dart';
import '../db/db_key_manager.dart'; // 🚀 CÓDIGO INSERIDO: Import do gerenciador de chaves

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

      // 2. Limpa dados sensíveis no armazenamento seguro do dispositivo
      await secureStorage.deleteAll();

      // 3. 🚀 CÓDIGO INSERIDO: Limpa a chave em memória RAM (Memory State Leak Fix)
      DbKeyManager.clearCache();

      // 4. Encerra a sessão no Firebase Auth
      await firebaseAuth.signOut();
    } catch (e) {
      throw Exception('Falha crítica ao limpar dados durante o logout: $e');
    }
  }
}
