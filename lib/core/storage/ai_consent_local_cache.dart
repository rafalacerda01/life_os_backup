import 'package:life_os/core/database/local_database_identity.dart';
import 'package:life_os/core/storage/generational_local_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Serializes cache writes and seals a remotely deleted account against late writes.
class AiConsentLocalCache {
  AiConsentLocalCache({Future<SharedPreferences> Function()? preferencesLoader})
    : _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance;
  static final instance = AiConsentLocalCache();
  static const keyPrefix = 'ai_consent_accepted_';
  final Future<SharedPreferences> Function() _preferencesLoader;
  final Map<String, Future<void>> _tails = {};
  final Set<String> _deletedUserIds = {};

  GenerationalLocalStore _scope(LocalDatabaseIdentity identity) =>
      GenerationalLocalStore(
        identity: identity,
        domain: 'ai_consent',
        read: (key) async {
          final p = await _preferencesLoader();
          await p.reload();
          return p.getString(key);
        },
        write: (key, value) async {
          if (!await (await _preferencesLoader()).setString(key, value))
            throw StateError('AI_CACHE_WRITE_UNKNOWN');
        },
        delete: (key) async {
          if (!await (await _preferencesLoader()).remove(key))
            throw StateError('AI_CACHE_DELETE_UNKNOWN');
        },
        listKeys: () async {
          final p = await _preferencesLoader();
          await p.reload();
          return p.getKeys();
        },
      );
  Future<bool> write(String uid, {LocalDatabaseIdentity? identity}) {
    if (identity != null) {
      if (identity.uid != uid) throw ArgumentError('LOCAL_OWNER_MISMATCH');
      return _scope(identity).write('consent', 'true').then((_) => true);
    }
    return _serialize(uid, () async {
      if (_deletedUserIds.contains(uid)) return false;
      return (await _preferencesLoader()).setBool('$keyPrefix$uid', true);
    });
  }

  Future<bool> remove(String uid, {LocalDatabaseIdentity? identity}) {
    if (identity != null) {
      if (identity.uid != uid) throw ArgumentError('LOCAL_OWNER_MISMATCH');
      return _scope(identity).delete('consent').then((_) => true);
    }
    return _serialize(uid, () async {
      final preferences = await _preferencesLoader();
      final key = '$keyPrefix$uid';
      await preferences.reload();
      if (preferences.containsKey(key) && !await preferences.remove(key)) {
        throw StateError('AI_CONSENT_CACHE_NOT_REMOVED');
      }
      await preferences.reload();
      if (preferences.containsKey(key))
        throw StateError('AI_CONSENT_CACHE_NOT_REMOVED');
      return true;
    });
  }

  Future<void> deleteForAccount(
    String uid, {
    LocalDatabaseIdentity? identity,
  }) async {
    if (identity != null) {
      if (identity.uid != uid) throw ArgumentError('LOCAL_OWNER_MISMATCH');
      await _scope(identity).retire();
      return;
    }
    if (uid.trim().isEmpty) throw ArgumentError('AI_CONSENT_UID_REQUIRED');
    _deletedUserIds.add(uid);
    await remove(uid);
  }

  Future<T> _serialize<T>(String uid, Future<T> Function() action) {
    final result = (_tails[uid] ?? Future<void>.value()).then((_) => action());
    _tails[uid] = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }
}
