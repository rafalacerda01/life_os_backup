import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class DbKeyManager {
  DbKeyManager._();

  // ===========================================================================
  // CONFIGURAÇÃO
  // ===========================================================================

  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  static const String _keyName = 'db_encryption_key';

  /// Tamanho da chave em bytes.
  ///
  /// 32 bytes = 256 bits.
  static const int _keyLengthBytes = 32;

  /// Chave mantida somente durante a execução do aplicativo.
  static String? _cachedKey;

  /// Evita que duas chamadas simultâneas gerem duas chaves diferentes
  /// durante a inicialização.
  static Future<String>? _keyFuture;

  // ===========================================================================
  // OBTENÇÃO DA CHAVE
  // ===========================================================================

  /// Retorna a chave de criptografia do banco.
  ///
  /// Fluxo:
  ///
  /// 1. Retorna a chave em memória, se disponível.
  /// 2. Recupera a chave do armazenamento seguro.
  /// 3. Caso não exista, gera uma nova chave criptograficamente segura.
  /// 4. Persiste a chave no armazenamento seguro.
  /// 5. Mantém a chave em cache somente durante a execução atual.
  ///
  /// A chave nunca deve ser hardcoded no código-fonte.
  static Future<String> getEncryptionKey() {
    final cachedKey = _cachedKey;

    if (cachedKey != null && _isValidKey(cachedKey)) {
      return Future<String>.value(cachedKey);
    }

    final ongoingFuture = _keyFuture;

    if (ongoingFuture != null) {
      return ongoingFuture;
    }

    final future = _loadOrCreateKey();

    _keyFuture = future;

    return future.whenComplete(() {
      // Só limpa se ainda for a mesma operação.
      if (identical(_keyFuture, future)) {
        _keyFuture = null;
      }
    });
  }

  // ===========================================================================
  // CARREGAMENTO / GERAÇÃO
  // ===========================================================================

  static Future<String> _loadOrCreateKey() async {
    try {
      final storedKey = await _storage.read(key: _keyName);

      // -----------------------------------------------------------------------
      // Chave existente
      // -----------------------------------------------------------------------

      if (storedKey != null) {
        final normalizedKey = storedKey.trim();

        if (_isValidKey(normalizedKey)) {
          _cachedKey = normalizedKey;
          return normalizedKey;
        }

        // A chave armazenada existe, mas está inválida/corrompida.
        //
        // NÃO devemos simplesmente gerar outra chave.
        //
        // Se o banco já estiver criptografado com a chave antiga,
        // gerar uma nova chave tornaria o banco inacessível.
        throw StateError(
          'A chave de criptografia armazenada é inválida ou corrompida.',
        );
      }

      // -----------------------------------------------------------------------
      // Primeira execução — gerar chave
      // -----------------------------------------------------------------------

      final newKey = _generateSecureKey();

      await _storage.write(key: _keyName, value: newKey);

      // Confirma que a chave realmente foi persistida.
      final persistedKey = await _storage.read(key: _keyName);

      if (persistedKey == null ||
          persistedKey.trim() != newKey ||
          !_isValidKey(persistedKey.trim())) {
        throw StateError(
          'Não foi possível confirmar a persistência '
          'da chave de criptografia.',
        );
      }

      _cachedKey = newKey;

      return newKey;
    } catch (e, stack) {
      debugPrint('DbKeyManager: falha ao carregar chave: $e\n$stack');

      throw StateError(
        'Falha crítica ao recuperar a chave de criptografia '
        'do banco de dados.',
      );
    }
  }

  // ===========================================================================
  // GERAÇÃO DA CHAVE
  // ===========================================================================

  static String _generateSecureKey() {
    final random = Random.secure();

    final bytes = List<int>.generate(
      _keyLengthBytes,
      (_) => random.nextInt(256),
      growable: false,
    );

    return base64UrlEncode(bytes);
  }

  // ===========================================================================
  // VALIDAÇÃO
  // ===========================================================================

  static bool _isValidKey(String? key) {
    if (key == null || key.trim().isEmpty) {
      return false;
    }

    try {
      final normalized = key.trim();

      final decoded = base64Url.decode(base64Url.normalize(normalized));

      return decoded.length == _keyLengthBytes;
    } catch (_) {
      return false;
    }
  }

  // ===========================================================================
  // LIMPEZA DO CACHE
  // ===========================================================================

  /// Remove a chave apenas do cache da memória.
  ///
  /// NÃO remove a chave do armazenamento seguro.
  ///
  /// Isso é importante:
  /// clearCache() pode ser usado no logout sem destruir a capacidade
  /// de abrir novamente o banco quando o usuário fizer login.
  static void clearCache() {
    _cachedKey = null;
  }

  // ===========================================================================
  // LIMPEZA DEFINITIVA
  // ===========================================================================

  /// Remove definitivamente a chave do armazenamento seguro.
  ///
  /// ATENÇÃO:
  /// Nunca chamar durante um logout normal.
  ///
  /// Se o banco estiver criptografado com essa chave, removê-la pode
  /// tornar os dados locais permanentemente inacessíveis.
  static Future<void> deleteKey() async {
    try {
      _cachedKey = null;

      await _storage.delete(key: _keyName);
    } catch (e, stack) {
      debugPrint('DbKeyManager: erro ao remover chave: $e\n$stack');

      throw StateError('Não foi possível remover a chave de criptografia.');
    }
  }
}
