import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/core/database/database_provider.dart';
import 'package:life_os/core/database/local_mutation_gate.dart';

class CycleReminderMutationGate {
  CycleReminderMutationGate([this._localMutations]);

  final LocalMutationGate? _localMutations;
  final Map<String, Future<void>> _tails = <String, Future<void>>{};

  Future<T> run<T>(String userId, Future<T> Function() operation) async {
    final normalizedUserId = _normalizeUserId(userId);
    final localMutations = _localMutations;
    if (localMutations == null) return _serialize(normalizedUserId, operation);
    final ticket = localMutations.capture(expectedUid: normalizedUserId);
    // Admission must precede the feature tail awaited by Auth cleanup.
    return localMutations.run(
      () => _serialize(normalizedUserId, operation),
      ticket: ticket,
    );
  }

  /// Session cleanup drains the feature tail without admitting domain writes.
  Future<T> runCleanup<T>(String userId, Future<T> Function() operation) =>
      _serialize(userId, operation);

  Future<T> _serialize<T>(String userId, Future<T> Function() operation) {
    final normalizedUserId = _normalizeUserId(userId);
    final previous = _tails[normalizedUserId] ?? Future<void>.value();
    final result = previous.then<T>((_) => operation());

    late final Future<void> tail;
    tail = result.then<void>((_) {}, onError: (_, _) {}).whenComplete(() {
      if (identical(_tails[normalizedUserId], tail)) {
        _tails.remove(normalizedUserId);
      }
    });
    _tails[normalizedUserId] = tail;
    return result;
  }

  String _normalizeUserId(String userId) {
    final normalizedUserId = userId.trim();
    if (normalizedUserId.isEmpty) {
      throw ArgumentError('CYCLE_REMINDER_GATE_USER_REQUIRED');
    }
    return normalizedUserId;
  }
}

final cycleReminderMutationGateProvider = Provider<CycleReminderMutationGate>((
  ref,
) {
  return CycleReminderMutationGate(ref.watch(databaseProvider).localMutations);
});
