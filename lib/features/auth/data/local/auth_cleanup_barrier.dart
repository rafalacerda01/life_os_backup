import 'dart:convert';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

enum AuthCleanupIntent { isolation, logout }

class PendingAuthCleanup {
  const PendingAuthCleanup({
    required this.version,
    required this.userId,
    required this.intent,
    required this.revision,
  });

  final int version;
  final String userId;
  final AuthCleanupIntent intent;
  final String revision;

  bool get requiresSignOut => intent == AuthCleanupIntent.logout;

  @override
  bool operator ==(Object other) {
    return other is PendingAuthCleanup &&
        other.version == version &&
        other.userId == userId &&
        other.intent == intent &&
        other.revision == revision;
  }

  @override
  int get hashCode => Object.hash(version, userId, intent, revision);
}

abstract interface class AuthCleanupBarrierStorage {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);
}

class SecureAuthCleanupBarrierStorage implements AuthCleanupBarrierStorage {
  const SecureAuthCleanupBarrierStorage(this._storage);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

abstract interface class AuthCleanupBarrier {
  Future<PendingAuthCleanup?> readPending();

  Future<PendingAuthCleanup> setPending(
    String userId,
    AuthCleanupIntent intent,
  );

  Future<bool> clearIfCurrent(PendingAuthCleanup expected);
}

class AuthCleanupBarrierStore implements AuthCleanupBarrier {
  AuthCleanupBarrierStore(this._storage, {String Function()? revisionFactory})
    : _revisionFactory = revisionFactory ?? _createRevision;

  // Keep the key stable so a pre-v2 marker fails closed instead of vanishing.
  static const String _storageKey = 'life_os_auth_cleanup_pending_v1';
  static const int _storageVersion = 2;
  static final RegExp _revisionPattern = RegExp(r'^[A-Za-z0-9_-]{22}$');
  static final Random _secureRandom = Random.secure();
  static Future<void> _mutationTail = Future<void>.value();

  final AuthCleanupBarrierStorage _storage;
  final String Function() _revisionFactory;

  @override
  Future<PendingAuthCleanup?> readPending() => _readPending();

  @override
  Future<PendingAuthCleanup> setPending(
    String userId,
    AuthCleanupIntent intent,
  ) {
    final normalizedUserId = _normalizeUserId(userId);
    return _runSerialized(() async {
      final existing = await _readPending();
      if (existing != null && existing.userId != normalizedUserId) {
        throw StateError('AUTH_CLEANUP_BARRIER_CONFLICT');
      }

      final effectiveIntent =
          existing?.requiresSignOut == true ||
              intent == AuthCleanupIntent.logout
          ? AuthCleanupIntent.logout
          : AuthCleanupIntent.isolation;
      if (existing != null && existing.intent == effectiveIntent) {
        return existing;
      }

      final marker = PendingAuthCleanup(
        version: _storageVersion,
        userId: normalizedUserId,
        intent: effectiveIntent,
        revision: _normalizeRevision(_revisionFactory()),
      );

      await _storage.write(
        _storageKey,
        jsonEncode(<String, Object>{
          'v': marker.version,
          'uid': marker.userId,
          'logout': marker.requiresSignOut,
          'revision': marker.revision,
        }),
      );
      return marker;
    });
  }

  @override
  Future<bool> clearIfCurrent(PendingAuthCleanup expected) {
    _validateExpectedMarker(expected);
    return _runSerialized(() async {
      final current = await _readPending();
      if (current != expected) return false;
      await _storage.delete(_storageKey);
      return true;
    });
  }

  Future<PendingAuthCleanup?> _readPending() async {
    final raw = await _storage.read(_storageKey);
    if (raw == null) return null;

    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic> ||
        decoded.length != 4 ||
        decoded['v'] != _storageVersion ||
        decoded['uid'] is! String ||
        decoded['logout'] is! bool ||
        decoded['revision'] is! String) {
      throw const FormatException('AUTH_CLEANUP_BARRIER_INVALID');
    }

    final userId = _normalizeUserId(decoded['uid'] as String);
    final revision = _normalizeRevision(decoded['revision'] as String);
    return PendingAuthCleanup(
      version: _storageVersion,
      userId: userId,
      intent: decoded['logout'] as bool
          ? AuthCleanupIntent.logout
          : AuthCleanupIntent.isolation,
      revision: revision,
    );
  }

  Future<T> _runSerialized<T>(Future<T> Function() operation) {
    final result = _mutationTail.then<T>((_) => operation());
    _mutationTail = result.then<void>((_) {}, onError: (_, _) {});
    return result;
  }

  static String _createRevision() {
    final bytes = List<int>.generate(16, (_) => _secureRandom.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  static String _normalizeRevision(String revision) {
    if (!_revisionPattern.hasMatch(revision)) {
      throw ArgumentError('AUTH_CLEANUP_REVISION_INVALID');
    }
    return revision;
  }

  static void _validateExpectedMarker(PendingAuthCleanup expected) {
    if (expected.version != _storageVersion) {
      throw ArgumentError('AUTH_CLEANUP_VERSION_INVALID');
    }
    _normalizeUserId(expected.userId);
    _normalizeRevision(expected.revision);
  }

  static String _normalizeUserId(String userId) {
    final normalized = userId.trim();
    if (normalized.isEmpty) {
      throw ArgumentError('AUTH_CLEANUP_USER_REQUIRED');
    }
    return normalized;
  }
}

final authCleanupBarrierProvider = Provider<AuthCleanupBarrier>((ref) {
  const storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  return AuthCleanupBarrierStore(
    const SecureAuthCleanupBarrierStorage(storage),
  );
});
