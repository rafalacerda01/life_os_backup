import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/core/services/analytics_service.dart';

enum AnalyticsPreferenceStatus { loading, disabled, enabled }

class AnalyticsPreferenceState {
  const AnalyticsPreferenceState(
    this.status, {
    this.operationInProgress = false,
  });

  const AnalyticsPreferenceState.loading()
    : status = AnalyticsPreferenceStatus.loading,
      operationInProgress = false;

  final AnalyticsPreferenceStatus status;
  final bool operationInProgress;

  bool get isEnabled => status == AnalyticsPreferenceStatus.enabled;

  AnalyticsPreferenceState copyWith({bool? operationInProgress}) {
    return AnalyticsPreferenceState(
      status,
      operationInProgress: operationInProgress ?? this.operationInProgress,
    );
  }
}

final analyticsServiceProvider = Provider<AnalyticsService>((ref) {
  return AnalyticsService();
});

final analyticsPreferenceStoreProvider = Provider<AnalyticsPreferenceStore>((
  ref,
) {
  return AnalyticsPreferenceStore();
});

class AnalyticsPreferenceNotifier extends Notifier<AnalyticsPreferenceState> {
  bool _operationInProgress = false;

  @override
  AnalyticsPreferenceState build() {
    _operationInProgress = false;
    unawaited(_load());
    return const AnalyticsPreferenceState.loading();
  }

  Future<void> _load() async {
    final service = ref.read(analyticsServiceProvider);
    try {
      final enabled = await ref
          .read(analyticsPreferenceStoreProvider)
          .loadEnabled();
      await service.setCollectionEnabled(enabled);
      if (!ref.mounted) return;
      state = AnalyticsPreferenceState(
        enabled
            ? AnalyticsPreferenceStatus.enabled
            : AnalyticsPreferenceStatus.disabled,
      );
    } catch (_) {
      await _disableCollectionBestEffort(service);
      if (ref.mounted) {
        state = const AnalyticsPreferenceState(
          AnalyticsPreferenceStatus.disabled,
        );
      }
    }
  }

  Future<bool> setEnabled(bool enabled) async {
    if (state.status == AnalyticsPreferenceStatus.loading ||
        _operationInProgress ||
        state.isEnabled == enabled) {
      return state.status != AnalyticsPreferenceStatus.loading &&
          state.isEnabled == enabled;
    }

    final previous = state;
    _operationInProgress = true;
    state = previous.copyWith(operationInProgress: true);
    try {
      return enabled ? await _enable() : await _disable();
    } finally {
      _operationInProgress = false;
      if (ref.mounted && state.operationInProgress) state = previous;
    }
  }

  Future<bool> _enable() async {
    final store = ref.read(analyticsPreferenceStoreProvider);
    final service = ref.read(analyticsServiceProvider);
    try {
      if (!await store.saveEnabled(true)) return false;
      await service.setCollectionEnabled(true);
      if (!ref.mounted) return false;
      _operationInProgress = false;
      state = const AnalyticsPreferenceState(AnalyticsPreferenceStatus.enabled);
      return true;
    } catch (_) {
      await _disableCollectionBestEffort(service);
      await _persistDisabledBestEffort(store);
      if (ref.mounted) {
        _operationInProgress = false;
        state = const AnalyticsPreferenceState(
          AnalyticsPreferenceStatus.disabled,
        );
      }
      return false;
    }
  }

  Future<bool> _disable() async {
    final store = ref.read(analyticsPreferenceStoreProvider);
    final service = ref.read(analyticsServiceProvider);
    try {
      await service.setCollectionEnabled(false);
      if (!await store.saveEnabled(false)) return false;

      var resetSucceeded = true;
      try {
        await service.resetAnalyticsData();
      } catch (_) {
        resetSucceeded = false;
      }

      if (!ref.mounted) return false;
      _operationInProgress = false;
      state = const AnalyticsPreferenceState(
        AnalyticsPreferenceStatus.disabled,
      );
      return resetSucceeded;
    } catch (_) {
      return false;
    }
  }

  Future<void> _disableCollectionBestEffort(AnalyticsService service) async {
    try {
      await service.setCollectionEnabled(false);
    } catch (_) {
      // Native configuration remains the fail-closed baseline.
    }
  }

  Future<void> _persistDisabledBestEffort(
    AnalyticsPreferenceStore store,
  ) async {
    try {
      await store.saveEnabled(false);
    } catch (_) {
      // The in-memory state remains disabled after a failed enable attempt.
    }
  }
}

final analyticsPreferenceProvider =
    NotifierProvider<AnalyticsPreferenceNotifier, AnalyticsPreferenceState>(
      AnalyticsPreferenceNotifier.new,
    );
