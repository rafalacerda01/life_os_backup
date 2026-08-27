import 'package:flutter_riverpod/flutter_riverpod.dart';

class CycleReminderMutationGate {
  final Map<String, Future<void>> _tails = <String, Future<void>>{};

  Future<T> run<T>(String userId, Future<T> Function() operation) {
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
  return CycleReminderMutationGate();
});
