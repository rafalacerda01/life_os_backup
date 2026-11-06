import 'package:life_os/core/database/local_database_identity.dart';
import 'package:life_os/core/storage/generational_local_store.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureStorageService {
  const SecureStorageService(this._secureStorage) : _scope = null;
  SecureStorageService.scoped(
    FlutterSecureStorage storage,
    LocalDatabaseIdentity identity,
  ) : _secureStorage = storage,
      _scope = GenerationalLocalStore(
        identity: identity,
        domain: 'session_tokens',
        read: (key) => storage.read(key: key),
        write: (key, value) => storage.write(key: key, value: value),
        delete: (key) => storage.delete(key: key),
        listKeys: () async => (await storage.readAll()).keys.toSet(),
      );
  final GenerationalLocalStore? _scope;
  Future<void> retire() async {
    final scope = _scope;
    if (scope == null) throw StateError('LOCAL_GENERATION_BINDING_REQUIRED');
    await scope.retire();
  }

  final FlutterSecureStorage _secureStorage;

  static const String tokenKey = 'auth_access_token';

  // Salvar o token com criptografia nativa de hardware (Keychain/EncryptedSharedPreferences)
  Future<void> saveToken(String token) async {
    if (_scope != null) {
      await _scope.write(tokenKey, token);
      return;
    }
    await _secureStorage.write(key: tokenKey, value: token);
  }

  // Ler o token salvo
  Future<String?> getToken() async {
    if (_scope != null) return _scope.read(tokenKey);
    return await _secureStorage.read(key: tokenKey);
  }

  // Deletar o token (Logout do usuário)
  Future<void> deleteToken() async {
    if (_scope != null) {
      await _scope.delete(tokenKey);
      return;
    }
    await _secureStorage.delete(key: tokenKey);
  }
}
