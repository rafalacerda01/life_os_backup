import 'package:flutter_riverpod/flutter_riverpod.dart';

class CycleReminderSessionAuthority {
  String? _preparedUserId;

  String? get preparedUserId => _preparedUserId;

  void prepare(String userId) {
    final normalizedUserId = userId.trim();
    if (normalizedUserId.isEmpty) {
      throw ArgumentError('CYCLE_REMINDER_USER_REQUIRED');
    }
    _preparedUserId = normalizedUserId;
  }

  String? clear() {
    final previousUserId = _preparedUserId;
    _preparedUserId = null;
    return previousUserId;
  }

  String? admittedUserId(String? authenticatedUserId) {
    final normalizedAuthenticatedUserId = authenticatedUserId?.trim();
    final preparedUserId = _preparedUserId;
    if (preparedUserId == null ||
        normalizedAuthenticatedUserId != preparedUserId) {
      return null;
    }
    return preparedUserId;
  }

  bool isPreparedFor(String userId) => _preparedUserId == userId.trim();
}

final cycleReminderSessionAuthorityProvider =
    Provider<CycleReminderSessionAuthority>((ref) {
      return CycleReminderSessionAuthority();
    });
