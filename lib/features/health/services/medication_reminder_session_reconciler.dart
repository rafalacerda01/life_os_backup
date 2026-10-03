import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:life_os/core/services/notification_preferences.dart';
import 'package:life_os/core/utils/app_logger.dart';

import 'medication_reminder_lifecycle.dart';

class MedicationReminderSession {
  const MedicationReminderSession._(this._owner, this._uid, this._generation);

  final MedicationReminderSessionReconciler _owner;
  final String _uid;
  final int _generation;
}

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

  MedicationReminderSession? captureSession() {
    final uid = _preparedUid;
    if (uid == null || _disposed || _currentUserId() != uid) return null;
    return MedicationReminderSession._(this, uid, _generation);
  }

  bool isCurrentSession(MedicationReminderSession? session) =>
      session != null &&
      identical(session._owner, this) &&
      !_disposed &&
      _preparedUid == session._uid &&
      _generation == session._generation &&
      _currentUserId() == session._uid;

  // Explicit preference changes queue a fresh read, never reuse an older job.
  Future<void> reconcileForSession(MedicationReminderSession? session) {
    if (!isCurrentSession(session)) return Future<void>.value();
    return _enqueue(session!, coalesce: false);
  }

  Future<void> reconcile() {
    final session = captureSession();
    if (session == null) return Future<void>.value();
    return _enqueue(session, coalesce: true);
  }

  Future<void> _enqueue(
    MedicationReminderSession session, {
    required bool coalesce,
  }) {
    bool isCurrent() => isCurrentSession(session);
    if (coalesce &&
        _inFlight != null &&
        _inFlightGeneration == session._generation) {
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
    _inFlightGeneration = session._generation;
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
