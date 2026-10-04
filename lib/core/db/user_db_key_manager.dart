import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:life_os/core/database/local_database_identity.dart';

/// Account-scoped keys. The legacy DbKeyManager remains independent.
class UserDbKeyManager {
  UserDbKeyManager({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(encryptedSharedPreferences: true),
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock,
            ),
          );

  static final instance = UserDbKeyManager();
  static const _keyLength = 32;

  final FlutterSecureStorage _storage;
  final _cache = <String, String>{};
  final _cacheRevisions = <String, int>{};
  final _operationTails = <String, Future<void>>{};

  Future<String> getEncryptionKey(
    LocalDatabaseIdentity identity, {
    required bool allowCreate,
  }) => _serialize(identity.keyAlias, () async {
    final alias = identity.keyAlias;
    final revision = _cacheRevisions[alias] ?? 0;
    try {
      final cached = _cache[alias];
      if (cached != null) return cached;

      final stored = await _storage.read(key: alias);
      String key;
      if (stored != null) {
        key = stored.trim();
        if (!_isValidKey(key)) throw StateError('USER_DATABASE_KEY_INVALID');
      } else {
        if (!allowCreate) throw StateError('USER_DATABASE_KEY_MISSING');
        final random = Random.secure();
        key = base64UrlEncode(
          List<int>.generate(_keyLength, (_) => random.nextInt(256)),
        );
        await _storage.write(key: alias, value: key);
        final persisted = await _storage.read(key: alias);
        if (persisted?.trim() != key) {
          throw StateError('USER_DATABASE_KEY_NOT_PERSISTED');
        }
      }

      // Clearing a cache while a read is in flight must not repopulate it.
      if ((_cacheRevisions[alias] ?? 0) == revision) _cache[alias] = key;
      return key;
    } catch (_) {
      throw StateError('USER_DATABASE_KEY_UNAVAILABLE');
    }
  });

  void clearCache(LocalDatabaseIdentity identity) {
    final alias = identity.keyAlias;
    _cache.remove(alias);
    _cacheRevisions[alias] = (_cacheRevisions[alias] ?? 0) + 1;
  }

  void clearAllCaches() {
    for (final alias in {..._cache.keys, ..._operationTails.keys}) {
      _cacheRevisions[alias] = (_cacheRevisions[alias] ?? 0) + 1;
    }
    _cache.clear();
  }

  Future<void> deleteKey(LocalDatabaseIdentity identity) {
    clearCache(identity);
    return _serialize(identity.keyAlias, () async {
      clearCache(identity);
      try {
        await _storage.delete(key: identity.keyAlias);
        if (await _storage.read(key: identity.keyAlias) != null) {
          throw StateError('USER_DATABASE_KEY_NOT_DELETED');
        }
      } catch (_) {
        throw StateError('USER_DATABASE_KEY_DELETE_FAILED');
      }
    });
  }

  // Serialize per identity: concurrent loads share the persisted/cached key,
  // and deletion cannot race a load into recreating an old cache entry.
  Future<T> _serialize<T>(String alias, Future<T> Function() action) {
    final previous = _operationTails[alias] ?? Future<void>.value();
    final result = previous.then((_) => action());
    final settled = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _operationTails[alias] = settled;
    unawaited(
      settled.then((_) {
        if (identical(_operationTails[alias], settled)) {
          _operationTails.remove(alias);
        }
      }),
    );
    return result;
  }

  static bool _isValidKey(String key) {
    try {
      return base64Url.decode(base64Url.normalize(key)).length == _keyLength;
    } catch (_) {
      return false;
    }
  }
}
