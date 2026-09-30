import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:life_os/core/services/notification_preferences.dart';
import 'package:life_os/core/utils/app_logger.dart';

import 'medication_reminder_lifecycle.dart';

class MedicationReminderSessionReconciler with WidgetsBindingObserver {
  factory MedicationReminderSessionReconciler({
    required MedicationReminderLifecycle lifecycle,
    required Future<NotificationPreferences> Function() loadPreferences,
    required String? Function() currentUserId,
    WidgetsBinding? binding,
  }) => MedicationReminderSessionReconciler._(
    lifecycle,
    loadPreferences,
    currentUserId,
    binding ?? WidgetsBinding.instance,
  );

  MedicationReminderSessionReconciler._(
    this._lifecycle,
    this._loadPreferences,
    this._currentUserId,
    this._binding,
  ) {
    _binding.addObserver(this);
  }

  final MedicationReminderLifecycle _lifecycle;
  final Future<NotificationPreferences> Function() _loadPreferences;
  final String? Function() _currentUserId;
  final WidgetsBinding _binding;
  String? _preparedUid;
  int _generation = 0;
  bool _disposed = false;
  Future<void> _tail = Future<void>.value();
  Future<void>? _inFlight;
  int? _inFlightGeneration;

  Future<void> onSessionPrepared(String uid) {
    if (_disposed || uid.trim().isEmpty || _currentUserId() != uid) {
      return Future<void>.value();
    }
    if (_preparedUid == uid) return _inFlight ?? Future<void>.value();
    _preparedUid = uid;
    _generation += 1;
    return reconcile();
  }

  void onSessionCleared() {
    _preparedUid = null;
    _generation += 1;
  }

  Future<void> drain() => _tail;

  Future<void> reconcile() {
    final uid = _preparedUid;
    final generation = _generation;
    bool isCurrent() =>
        !_disposed &&
        _preparedUid == uid &&
        _generation == generation &&
        _currentUserId() == uid;

    if (uid == null || !isCurrent()) return Future<void>.value();
    if (_inFlight != null && _inFlightGeneration == generation) {
      return _inFlight!;
    }

    late final Future<void> operation;
    operation = _tail
        .then((_) async {
          try {
            if (!isCurrent()) return;
            final preferences = await _loadPreferences();
            if (!isCurrent()) return;
            if (!preferences.allNotifications ||
                !preferences.medicationReminders) {
              await _lifecycle.cancelAllMedicationReminders(
                shouldContinue: isCurrent,
              );
            } else {
              await _lifecycle.rebuildMedicationReminders(
                shouldContinue: isCurrent,
              );
            }
          } catch (_) {
            AppLogger.w(
              'Falha ao reconciliar lembretes locais de medicamentos.',
            );
          }
        })
        .whenComplete(() {
          if (identical(_inFlight, operation)) {
            _inFlight = null;
            _inFlightGeneration = null;
          }
        });
    _inFlight = operation;
    _inFlightGeneration = generation;
    _tail = operation;
    return operation;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(reconcile());
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    onSessionCleared();
    _binding.removeObserver(this);
  }
}
