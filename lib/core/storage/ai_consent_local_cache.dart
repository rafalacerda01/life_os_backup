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

  Future<bool> write(String uid) => _serialize(uid, () async {
    if (_deletedUserIds.contains(uid)) return false;
    return (await _preferencesLoader()).setBool('$keyPrefix$uid', true);
  });

  Future<bool> remove(String uid) => _serialize(uid, () async {
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

  Future<void> deleteForAccount(String uid) async {
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
