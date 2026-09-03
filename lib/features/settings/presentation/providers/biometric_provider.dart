import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/core/services/biometric_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum BiometricLockStatus { loading, disabled, locked, unlocked }

class BiometricLockState {
  const BiometricLockState(
    this.status, {
    this.authenticationInProgress = false,
  });

  const BiometricLockState.loading()
    : status = BiometricLockStatus.loading,
      authenticationInProgress = false;

  final BiometricLockStatus status;
  final bool authenticationInProgress;

  bool get isEnabled =>
      status == BiometricLockStatus.locked ||
      status == BiometricLockStatus.unlocked;
  bool get isLocked => status == BiometricLockStatus.locked;

  BiometricLockState copyWith({bool? authenticationInProgress}) {
    return BiometricLockState(
      status,
      authenticationInProgress:
          authenticationInProgress ?? this.authenticationInProgress,
    );
  }
}

typedef BiometricPreferencesLoader = Future<SharedPreferences> Function();

final biometricServiceProvider = Provider<BiometricService>((ref) {
  return BiometricService();
});

final biometricPreferencesLoaderProvider = Provider<BiometricPreferencesLoader>(
  (ref) => SharedPreferences.getInstance,
);

class BiometricNotifier extends Notifier<BiometricLockState> {
  static const String storageKey = 'biometrics_enabled';

  bool _authenticationInProgress = false;

  @override
  BiometricLockState build() {
    _authenticationInProgress = false;
    unawaited(_loadPreference());
    return const BiometricLockState.loading();
  }

  Future<void> _loadPreference() async {
    try {
      final prefs = await ref.read(biometricPreferencesLoaderProvider)();
      if (!ref.mounted) return;
      state = prefs.getBool(storageKey) == true
          ? const BiometricLockState(BiometricLockStatus.locked)
          : const BiometricLockState(BiometricLockStatus.disabled);
    } catch (_) {
      // Unknown preference state remains fail-closed for authenticated sessions.
    }
  }

  Future<bool> toggleBiometrics(bool enable) async {
    if (state.status == BiometricLockStatus.loading ||
        _authenticationInProgress ||
        enable == state.isEnabled) {
      return enable == state.isEnabled;
    }

    return _authenticateAndPersist(
      enable: enable,
      reason: enable
          ? 'Confirme sua biometria para habilitar este recurso'
          : 'Confirme sua biometria para desabilitar este recurso',
    );
  }

  Future<bool> _authenticateAndPersist({
    required bool enable,
    required String reason,
  }) async {
    final previous = state;
    _authenticationInProgress = true;
    state = previous.copyWith(authenticationInProgress: true);
    try {
      final service = ref.read(biometricServiceProvider);
      if (enable && !await service.hasEnrolledBiometrics()) return false;

      final authenticated = await ref
          .read(biometricServiceProvider)
          .authenticate(reason: reason);
      if (!authenticated || !ref.mounted) return false;

      final prefs = await ref.read(biometricPreferencesLoaderProvider)();
      final persisted = await prefs.setBool(storageKey, enable);
      if (!persisted || !ref.mounted) return false;

      _authenticationInProgress = false;
      state = BiometricLockState(
        enable ? BiometricLockStatus.unlocked : BiometricLockStatus.disabled,
      );
      return true;
    } catch (_) {
      return false;
    } finally {
      _authenticationInProgress = false;
      if (ref.mounted && state.authenticationInProgress) state = previous;
    }
  }

  Future<bool> unlock() async {
    if (!state.isLocked || _authenticationInProgress) return false;

    final previous = state;
    _authenticationInProgress = true;
    state = previous.copyWith(authenticationInProgress: true);
    try {
      final authenticated = await ref
          .read(biometricServiceProvider)
          .authenticate(
            reason: 'Confirme sua biometria para acessar o Life OS',
          );
      if (!authenticated || !ref.mounted) return false;
      _authenticationInProgress = false;
      state = const BiometricLockState(BiometricLockStatus.unlocked);
      return true;
    } catch (_) {
      return false;
    } finally {
      _authenticationInProgress = false;
      if (ref.mounted && state.authenticationInProgress) state = previous;
    }
  }

  void lock() {
    if (!state.isEnabled || _authenticationInProgress) return;
    state = const BiometricLockState(BiometricLockStatus.locked);
  }

  Future<void> clearAfterConfirmedSignOut() async {
    final prefs = await ref.read(biometricPreferencesLoaderProvider)();
    final persisted = await prefs.setBool(storageKey, false);
    if (!persisted) throw StateError('BIOMETRIC_PREFERENCE_CLEAR_FAILED');
    if (ref.mounted) {
      state = const BiometricLockState(BiometricLockStatus.disabled);
    }
  }
}

final biometricProvider =
    NotifierProvider<BiometricNotifier, BiometricLockState>(
      BiometricNotifier.new,
    );
