import 'dart:convert';
import 'dart:math';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/foundation.dart'; // Para debug

class DbKeyManager {
  static const _storage = FlutterSecureStorage(
    // Configuração robusta para Android: usa EncryptedSharedPreferences
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  static const _keyName = 'db_encryption_key';
  static String? _cachedKey;

  static Future<String> getEncryptionKey() async {
    // Retorna o cache em memória para evitar leituras repetidas e lentas do SecureStorage
    if (_cachedKey != null) return _cachedKey!;

    try {
      String? key = await _storage.read(key: _keyName);

      if (key == null) {
        final random = Random.secure();
        final values = List<int>.generate(32, (i) => random.nextInt(256));
        key = base64Url.encode(values);
        await _storage.write(key: _keyName, value: key);
      }

      _cachedKey = key;
      return key;
    } catch (e) {
      // Falha crítica de segurança ou armazenamento:
      // Não podemos continuar se não conseguirmos acessar a chave.
      throw Exception('Falha crítica ao recuperar chave de criptografia: $e');
    }
  }
}
