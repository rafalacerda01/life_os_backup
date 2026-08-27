import 'package:flutter_riverpod/flutter_riverpod.dart';

class CycleReminderOperationEpoch {
  final Map<String, int> _generations = <String, int>{};

  int snapshot(String userId) {
    final normalizedUserId = _normalizeUserId(userId);
    return _generations.putIfAbsent(normalizedUserId, () => 0);
  }

  void invalidate(String userId) {
    final normalizedUserId = _normalizeUserId(userId);
    _generations[normalizedUserId] = snapshot(normalizedUserId) + 1;
  }

  bool isCurrent(String userId, int generation) {
    return snapshot(userId) == generation;
  }

  String _normalizeUserId(String userId) {
    final normalizedUserId = userId.trim();
    if (normalizedUserId.isEmpty) {
      throw ArgumentError('CYCLE_REMINDER_EPOCH_USER_REQUIRED');
    }
    return normalizedUserId;
  }
}

final cycleReminderOperationEpochProvider =
    Provider<CycleReminderOperationEpoch>((ref) {
      return CycleReminderOperationEpoch();
    });
