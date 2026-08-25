import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

enum CycleReminderType { pill, otherContraceptive, personal }

enum CycleReminderFrequency { daily, specificWeekdays }

enum CycleReminderPrivacyMode { discreet, informative, custom }

class CycleReminderPreferences {
  factory CycleReminderPreferences({
    required bool enabled,
    required CycleReminderType type,
    required int hour,
    required int minute,
    required CycleReminderFrequency frequency,
    Set<int> weekdays = const <int>{},
    CycleReminderPrivacyMode privacyMode = CycleReminderPrivacyMode.discreet,
    String customTitle = '',
    String customBody = '',
  }) {
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) {
      throw ArgumentError('CYCLE_REMINDER_TIME_INVALID');
    }

    final normalizedWeekdays = Set<int>.unmodifiable(weekdays);
    if (normalizedWeekdays.any((day) => day < 1 || day > 7)) {
      throw ArgumentError('CYCLE_REMINDER_WEEKDAY_INVALID');
    }
    if (frequency == CycleReminderFrequency.specificWeekdays &&
        normalizedWeekdays.isEmpty) {
      throw ArgumentError('CYCLE_REMINDER_WEEKDAYS_REQUIRED');
    }

    final normalizedTitle = _normalizeText(customTitle, maxLength: 60);
    final normalizedBody = _normalizeText(customBody, maxLength: 160);
    if (privacyMode == CycleReminderPrivacyMode.custom &&
        (normalizedTitle.isEmpty || normalizedBody.isEmpty)) {
      throw ArgumentError('CYCLE_REMINDER_CUSTOM_TEXT_REQUIRED');
    }

    return CycleReminderPreferences._(
      enabled: enabled,
      type: type,
      hour: hour,
      minute: minute,
      frequency: frequency,
      weekdays: normalizedWeekdays,
      privacyMode: privacyMode,
      customTitle: normalizedTitle,
      customBody: normalizedBody,
    );
  }

  const CycleReminderPreferences._({
    required this.enabled,
    required this.type,
    required this.hour,
    required this.minute,
    required this.frequency,
    required this.weekdays,
    required this.privacyMode,
    required this.customTitle,
    required this.customBody,
  });

  static const int storageVersion = 1;

  final bool enabled;
  final CycleReminderType type;
  final int hour;
  final int minute;
  final CycleReminderFrequency frequency;
  final Set<int> weekdays;
  final CycleReminderPrivacyMode privacyMode;
  final String customTitle;
  final String customBody;

  CycleReminderPreferences copyWith({bool? enabled}) {
    return CycleReminderPreferences(
      enabled: enabled ?? this.enabled,
      type: type,
      hour: hour,
      minute: minute,
      frequency: frequency,
      weekdays: weekdays,
      privacyMode: privacyMode,
      customTitle: customTitle,
      customBody: customBody,
    );
  }

  Map<String, Object> toJson() {
    final sortedWeekdays = weekdays.toList()..sort();
    return <String, Object>{
      'version': storageVersion,
      'enabled': enabled,
      'type': type.name,
      'hour': hour,
      'minute': minute,
      'frequency': frequency.name,
      'weekdays': sortedWeekdays,
      'privacyMode': privacyMode.name,
      'customTitle': customTitle,
      'customBody': customBody,
    };
  }

  static CycleReminderPreferences fromJson(Map<String, dynamic> json) {
    if (json['version'] != storageVersion || json['enabled'] is! bool) {
      throw const FormatException('CYCLE_REMINDER_FORMAT_INVALID');
    }

    return CycleReminderPreferences(
      enabled: json['enabled'] as bool,
      type: _enumByName(CycleReminderType.values, json['type']),
      hour: _requiredInt(json['hour']),
      minute: _requiredInt(json['minute']),
      frequency: _enumByName(CycleReminderFrequency.values, json['frequency']),
      weekdays: _requiredWeekdays(json['weekdays']),
      privacyMode: _enumByName(
        CycleReminderPrivacyMode.values,
        json['privacyMode'],
      ),
      customTitle: json['customTitle'] is String
          ? json['customTitle'] as String
          : '',
      customBody: json['customBody'] is String
          ? json['customBody'] as String
          : '',
    );
  }

  static int _requiredInt(Object? value) {
    if (value is int) return value;
    throw const FormatException('CYCLE_REMINDER_FORMAT_INVALID');
  }

  static Set<int> _requiredWeekdays(Object? value) {
    if (value is! List) {
      throw const FormatException('CYCLE_REMINDER_FORMAT_INVALID');
    }
    return value.map(_requiredInt).toSet();
  }

  static T _enumByName<T extends Enum>(List<T> values, Object? value) {
    if (value is! String) {
      throw const FormatException('CYCLE_REMINDER_FORMAT_INVALID');
    }
    return values.firstWhere(
      (entry) => entry.name == value,
      orElse: () =>
          throw const FormatException('CYCLE_REMINDER_FORMAT_INVALID'),
    );
  }

  static String _normalizeText(String value, {required int maxLength}) {
    final withoutControls = value.replaceAll(
      RegExp(r'[\u0000-\u001F\u007F]'),
      ' ',
    );
    final normalized = withoutControls.trim().replaceAll(RegExp(r'\s+'), ' ');
    return String.fromCharCodes(normalized.runes.take(maxLength));
  }
}

abstract interface class CycleReminderPreferencesStorage {
  Future<String?> read(String key);

  Future<void> write(String key, String value);
}

class SecureCycleReminderPreferencesStorage
    implements CycleReminderPreferencesStorage {
  const SecureCycleReminderPreferencesStorage(this._storage);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
}

class CycleReminderPreferencesStore {
  const CycleReminderPreferencesStore(this._storage);

  static const String _keyPrefix = 'life_os_cycle_reminder_v1_';

  final CycleReminderPreferencesStorage _storage;

  Future<CycleReminderPreferences?> load(String userId) async {
    final key = _keyFor(userId);
    final stored = await _storage.read(key);
    if (stored == null) return null;

    try {
      final decoded = jsonDecode(stored);
      if (decoded is! Map<String, dynamic>) return null;
      return CycleReminderPreferences.fromJson(decoded);
    } on FormatException {
      return null;
    } on ArgumentError {
      return null;
    }
  }

  Future<void> save(String userId, CycleReminderPreferences preferences) {
    final key = _keyFor(userId);
    return _storage.write(key, jsonEncode(preferences.toJson()));
  }

  String _keyFor(String userId) {
    final normalizedUserId = userId.trim();
    if (normalizedUserId.isEmpty) {
      throw ArgumentError('CYCLE_REMINDER_USER_REQUIRED');
    }
    return '$_keyPrefix$normalizedUserId';
  }
}

final cycleReminderUserIdProvider = StreamProvider<String?>((ref) {
  return FirebaseAuth.instance
      .authStateChanges()
      .map((user) => user?.uid)
      .distinct();
});

typedef CycleReminderUserIdReader = String? Function();

final cycleReminderUserIdReaderProvider = Provider<CycleReminderUserIdReader>((
  ref,
) {
  return () {
    try {
      final userId = FirebaseAuth.instance.currentUser?.uid.trim();
      return userId == null || userId.isEmpty ? null : userId;
    } on Object {
      return null;
    }
  };
});

final cycleReminderPreferencesStoreProvider =
    Provider<CycleReminderPreferencesStore>((ref) {
      const storage = FlutterSecureStorage(
        aOptions: AndroidOptions(encryptedSharedPreferences: true),
      );
      return const CycleReminderPreferencesStore(
        SecureCycleReminderPreferencesStorage(storage),
      );
    });

final cycleReminderPreferencesProvider =
    AsyncNotifierProvider<
      CycleReminderPreferencesNotifier,
      CycleReminderPreferences?
    >(CycleReminderPreferencesNotifier.new);

class CycleReminderPreferencesNotifier
    extends AsyncNotifier<CycleReminderPreferences?> {
  @override
  Future<CycleReminderPreferences?> build() async {
    final userId = _normalizeUserId(
      ref.watch(cycleReminderUserIdProvider).asData?.value,
    );
    if (userId == null) return null;
    return ref.read(cycleReminderPreferencesStoreProvider).load(userId);
  }

  Future<String> save(CycleReminderPreferences preferences) async {
    final userId = _currentUserId();
    if (userId == null) {
      throw StateError('CYCLE_REMINDER_SESSION_REQUIRED');
    }

    await ref
        .read(cycleReminderPreferencesStoreProvider)
        .save(userId, preferences);

    if (_currentUserId() == userId) {
      state = AsyncData(preferences);
    }
    return userId;
  }

  Future<void> setEnabled(bool enabled) async {
    final current = state.asData?.value;
    if (current == null || current.enabled == enabled) return;
    await save(current.copyWith(enabled: enabled));
  }

  String? _currentUserId() {
    return _normalizeUserId(ref.read(cycleReminderUserIdReaderProvider)());
  }

  String? _normalizeUserId(String? userId) {
    final value = userId?.trim();
    return value == null || value.isEmpty ? null : value;
  }
}
