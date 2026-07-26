import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureStorageService {
  const SecureStorageService(this._secureStorage);

  final FlutterSecureStorage _secureStorage;

  static const String _tokenKey = 'auth_access_token';

  // Salvar o token com criptografia nativa de hardware (Keychain/EncryptedSharedPreferences)
  Future<void> saveToken(String token) async {
    await _secureStorage.write(key: _tokenKey, value: token);
  }

  // Ler o token salvo
  Future<String?> getToken() async {
    return await _secureStorage.read(key: _tokenKey);
  }

  // Deletar o token (Logout do usuário)
  Future<void> deleteToken() async {
    await _secureStorage.delete(key: _tokenKey);
  }

  Future<void> deleteAll() async {
    await _secureStorage.deleteAll();
  }
}
