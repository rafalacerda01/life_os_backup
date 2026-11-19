import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:life_os/core/database/database_provider.dart';
import 'package:life_os/core/database/local_database_identity.dart';
import 'package:life_os/core/services/biometric_service.dart';

class LocalProfileSettings {
  const LocalProfileSettings({
    this.displayName = '',
    this.requireDeviceUnlock = false,
  });
  final String displayName;
  final bool requireDeviceUnlock;
}

/// Presentation and device-lock preferences belong to the installation and
/// use secure storage with migration and reset disabled.
class LocalProfileSettingsStore {
  LocalProfileSettingsStore(
    LocalDatabaseIdentity identity, {
    this._storage = const FlutterSecureStorage(
      aOptions: AndroidOptions(
        encryptedSharedPreferences: true,
        resetOnError: false,
        migrateOnAlgorithmChange: false,
      ),
    ),
  }) : _key = 'life_os_local_settings_v1_${identity.uid}' {
    if (!identity.isLocalInstallation)
      throw ArgumentError('LOCAL_PROFILE_IDENTITY_REQUIRED');
  }

  final FlutterSecureStorage _storage;
  final String _key;

  static bool validDisplayName(String value) =>
      value.length <= 60 && !RegExp(r'[\u0000-\u001F\u007F]').hasMatch(value);

  Future<LocalProfileSettings> read() async {
    final stored = await _storage.read(key: _key);
    if (stored == null) return const LocalProfileSettings();
    final decoded = jsonDecode(stored);
    if (decoded is! Map<String, dynamic> ||
        decoded.length != 3 ||
        decoded['v'] is! int ||
        decoded['v'] != 1) {
      throw const FormatException('LOCAL_PROFILE_SETTINGS_INVALID');
    }
    final name = decoded['displayName'];
    final locked = decoded['requireDeviceUnlock'];
    if (name is! String ||
        name != name.trim() ||
        !validDisplayName(name) ||
        locked is! bool) {
      throw const FormatException('LOCAL_PROFILE_SETTINGS_INVALID');
    }
    return LocalProfileSettings(displayName: name, requireDeviceUnlock: locked);
  }

  Future<void> write(LocalProfileSettings settings) async {
    final name = settings.displayName;
    if (name != name.trim() || !validDisplayName(name))
      throw ArgumentError('LOCAL_PROFILE_NAME_INVALID');
    final encoded = jsonEncode({
      'v': 1,
      'displayName': name,
      'requireDeviceUnlock': settings.requireDeviceUnlock,
    });
    await _storage.write(key: _key, value: encoded);
    if (await _storage.read(key: _key) != encoded)
      throw StateError('LOCAL_PROFILE_SETTINGS_NOT_PERSISTED');
  }
}

final localProfileSettingsStoreProvider = Provider<LocalProfileSettingsStore>((
  ref,
) {
  final database = ref.watch(databaseProvider);
  if (!database.isLocalOnly)
    throw StateError('LOCAL_PROFILE_SYNC_POLICY_REQUIRED');
  return LocalProfileSettingsStore(database.identity!);
});

final localProfileDeviceAuthProvider = Provider<BiometricService>(
  (ref) => BiometricService(),
);

final localProfileUnlockedProvider = NotifierProvider<LocalProfileUnlock, bool>(
  LocalProfileUnlock.new,
);

class LocalProfileUnlock extends Notifier<bool> {
  bool _authenticating = false;

  @override
  bool build() => false;

  Future<bool> confirm(String reason) async {
    if (_authenticating) return false;
    _authenticating = true;
    try {
      final unlocked = await ref
          .read(localProfileDeviceAuthProvider)
          .authenticateDevice(reason: reason);
      if (!ref.mounted || !unlocked || !await _awaitForeground()) return false;
      if (!ref.mounted ||
          WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
        return false;
      }
      state = true;
      return true;
    } finally {
      _authenticating = false;
    }
  }

  // Android can report successful authentication before dismissing its window.
  // Only wait for the inactive-to-resumed transition from that credential UI.
  Future<bool> _awaitForeground() async {
    final state = WidgetsBinding.instance.lifecycleState;
    if (state == AppLifecycleState.resumed) return true;
    if (state != AppLifecycleState.inactive) return false;

    final foreground = Completer<bool>();
    final listener = AppLifecycleListener(
      onStateChange: (next) {
        if (!foreground.isCompleted && next != AppLifecycleState.inactive) {
          foreground.complete(next == AppLifecycleState.resumed);
        }
      },
    );
    try {
      return await foreground.future.timeout(
        const Duration(seconds: 3),
        onTimeout: () => false,
      );
    } finally {
      listener.dispose();
    }
  }

  void lock() => state = false;
}

final localProfileSettingsProvider =
    AsyncNotifierProvider<LocalProfileSettingsController, LocalProfileSettings>(
      LocalProfileSettingsController.new,
    );

class LocalProfileSettingsController
    extends AsyncNotifier<LocalProfileSettings> {
  bool _saving = false;

  @override
  Future<LocalProfileSettings> build() =>
      ref.watch(localProfileSettingsStoreProvider).read();

  Future<bool> setName(String name) => _change(
    (current) async => LocalProfileSettings(
      displayName: name.trim(),
      requireDeviceUnlock: current.requireDeviceUnlock,
    ),
  );

  Future<bool> setDeviceLock(bool enabled) => _change((current) async {
    if (enabled == current.requireDeviceUnlock) return current;
    final authenticated = await ref
        .read(localProfileUnlockedProvider.notifier)
        .confirm(
          enabled
              ? 'Confirme o bloqueio do dispositivo para ativar a proteção.'
              : 'Confirme o bloqueio do dispositivo para desativar a proteção.',
        );
    if (!authenticated) return null;
    return LocalProfileSettings(
      displayName: current.displayName,
      requireDeviceUnlock: enabled,
    );
  });

  Future<bool> _change(
    Future<LocalProfileSettings?> Function(LocalProfileSettings) propose,
  ) async {
    if (_saving || state is! AsyncData<LocalProfileSettings>) return false;
    _saving = true;
    final store = ref.read(localProfileSettingsStoreProvider);
    try {
      final selected = await propose(state.requireValue);
      if (selected == null || !ref.mounted) return false;
      await store.write(selected);
      if (ref.mounted) state = AsyncData(selected);
      return true;
    } catch (_) {
      final persisted = await AsyncValue.guard(store.read);
      if (ref.mounted) state = persisted;
      rethrow;
    } finally {
      _saving = false;
    }
  }
}
