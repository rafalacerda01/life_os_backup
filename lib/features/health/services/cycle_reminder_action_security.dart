import 'dart:convert';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const String cycleReminderActionKind = 'cr';
const int cycleReminderActionPayloadVersion = 1;

abstract interface class CycleReminderActionTokenStorage {
  Future<String?> read(String key);

  Future<void> write(String key, String value);
}

class SecureCycleReminderActionTokenStorage
    implements CycleReminderActionTokenStorage {
  const SecureCycleReminderActionTokenStorage(this._storage);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
}

abstract interface class CycleReminderActionTokenReader {
  Future<String?> load(String userId);

  Future<String> getOrCreate(String userId);
}

typedef CycleReminderSecureRandomBytes = List<int> Function(int length);

class CycleReminderActionTokenStore implements CycleReminderActionTokenReader {
  CycleReminderActionTokenStore(
    this._storage, {
    CycleReminderSecureRandomBytes? randomBytes,
  }) : _randomBytes = randomBytes ?? _createSecureRandomBytes;

  static const String _keyPrefix = 'life_os_cycle_action_token_v1_';
  static const int _tokenBytes = 32;

  final CycleReminderActionTokenStorage _storage;
  final CycleReminderSecureRandomBytes _randomBytes;
  final Map<String, Future<String>> _inFlight = <String, Future<String>>{};

  @override
  Future<String?> load(String userId) async {
    final stored = await _storage.read(_keyFor(userId));
    if (stored == null) return null;
    if (!isValidCycleReminderActionToken(stored)) {
      throw const FormatException('CYCLE_REMINDER_ACTION_TOKEN_INVALID');
    }
    return stored;
  }

  @override
  Future<String> getOrCreate(String userId) {
    final normalizedUserId = _normalizeUserId(userId);
    final existing = _inFlight[normalizedUserId];
    if (existing != null) return existing;

    late final Future<String> operation;
    operation = _getOrCreate(normalizedUserId).whenComplete(() {
      if (identical(_inFlight[normalizedUserId], operation)) {
        _inFlight.remove(normalizedUserId);
      }
    });
    _inFlight[normalizedUserId] = operation;
    return operation;
  }

  Future<String> _getOrCreate(String userId) async {
    final existing = await load(userId);
    if (existing != null) return existing;

    final bytes = _randomBytes(_tokenBytes);
    if (bytes.length != _tokenBytes ||
        bytes.any((value) => value < 0 || value > 255)) {
      throw StateError('CYCLE_REMINDER_ACTION_RANDOM_INVALID');
    }

    final token = base64Url.encode(bytes).replaceAll('=', '');
    await _storage.write(_keyFor(userId), token);
    return token;
  }

  String _keyFor(String userId) => '$_keyPrefix${_normalizeUserId(userId)}';

  static String _normalizeUserId(String userId) {
    final normalized = userId.trim();
    if (normalized.isEmpty) {
      throw ArgumentError('CYCLE_REMINDER_ACTION_USER_REQUIRED');
    }
    return normalized;
  }

  static List<int> _createSecureRandomBytes(int length) {
    final random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(256));
  }
}

class CycleReminderActionPayload {
  const CycleReminderActionPayload(this.token);

  final String token;
}

class CycleReminderActionPayloadCodec {
  const CycleReminderActionPayloadCodec();

  static const int maxPayloadLength = 512;

  String encode(CycleReminderActionPayload payload) {
    if (!isValidCycleReminderActionToken(payload.token)) {
      throw ArgumentError('CYCLE_REMINDER_ACTION_TOKEN_INVALID');
    }
    return jsonEncode(<String, Object>{
      'v': cycleReminderActionPayloadVersion,
      'k': cycleReminderActionKind,
      'o': payload.token,
    });
  }

  CycleReminderActionPayload? decode(String? raw) {
    if (raw == null || raw.isEmpty || raw.length > maxPayloadLength) {
      return null;
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic> || decoded.length != 3) {
        return null;
      }
      if (decoded['v'] != cycleReminderActionPayloadVersion ||
          decoded['k'] != cycleReminderActionKind ||
          decoded['o'] is! String) {
        return null;
      }
      final token = decoded['o'] as String;
      if (!isValidCycleReminderActionToken(token)) return null;
      return CycleReminderActionPayload(token);
    } on FormatException {
      return null;
    }
  }
}

bool isValidCycleReminderActionToken(String token) {
  if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(token)) return false;
  try {
    return base64Url.decode('$token=').length == 32;
  } on FormatException {
    return false;
  }
}

bool constantTimeTokenEquals(String first, String second) {
  if (first.length != second.length) return false;
  var difference = 0;
  for (var index = 0; index < first.length; index += 1) {
    difference |= first.codeUnitAt(index) ^ second.codeUnitAt(index);
  }
  return difference == 0;
}

final cycleReminderActionTokenStoreProvider =
    Provider<CycleReminderActionTokenReader>((ref) {
      const storage = FlutterSecureStorage(
        aOptions: AndroidOptions(encryptedSharedPreferences: true),
      );
      return CycleReminderActionTokenStore(
        const SecureCycleReminderActionTokenStorage(storage),
      );
    });
