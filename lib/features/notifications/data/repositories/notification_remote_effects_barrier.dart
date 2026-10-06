import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final notificationRemoteEffectsBarrierProvider =
    Provider<NotificationRemoteEffectsBarrier>((ref) {
      return NotificationRemoteEffectsBarrier();
    });

/// Tracks local continuations and SDK writes until they actually settle.
class NotificationRemoteEffectsBarrier {
  final Set<Future<void>> _inFlight = {};
  int _generation = 0;
  bool _sealed = false;

  int get generation => _generation;

  bool isCurrent(int generation) => !_sealed && generation == _generation;

  Future<T> track<T>(Future<T> Function() action) {
    final result = Future<T>.sync(action);
    late final Future<void> tracked;
    tracked = result
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() => _inFlight.remove(tracked));
    _inFlight.add(tracked);
    return result;
  }

  /// Wait for already admitted effects without sealing the current session.
  Future<void> drainCurrent() async {
    // Local continuations can admit an SDK write while this wait is in progress.
    while (_inFlight.isNotEmpty) {
      await Future.wait(_inFlight.toList());
    }
  }

  Future<void> sealAndDrain() async {
    _sealed = true;
    _generation += 1;
    while (_inFlight.isNotEmpty) {
      await Future.wait(_inFlight.toList());
    }
  }

  bool resume() {
    if (!_sealed) return true;
    if (_inFlight.isNotEmpty) return false;
    _generation += 1;
    _sealed = false;
    return true;
  }
}
