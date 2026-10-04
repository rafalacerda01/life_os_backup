import 'cycle_reminder_mutation_gate.dart';
import 'cycle_reminder_notification_lifecycle.dart';

typedef CycleReminderActionTokenRotation = Future<void> Function(String userId);
typedef CycleReminderPreferencesDeletion = Future<void> Function(String userId);

enum CycleReminderCleanupIntent { sessionExit, accountDeletion }

class CycleReminderSessionCleanup {
  const CycleReminderSessionCleanup(
    this._mutationGate,
    this._lifecycle, {
    required this.rotateActionToken,
    required this.deletePreferences,
  });

  final CycleReminderMutationGate _mutationGate;
  final CycleReminderNotificationLifecycle _lifecycle;
  final CycleReminderActionTokenRotation rotateActionToken;
  final CycleReminderPreferencesDeletion deletePreferences;

  Future<int> cancelAfterCurrentMutations(
    String userId, {
    CycleReminderCleanupIntent intent = CycleReminderCleanupIntent.sessionExit,
  }) {
    return _mutationGate.runCleanup(userId, () async {
      await rotateActionToken(userId);
      final failedCancellations = await _lifecycle.cancelAllCycleReminders(
        userId,
      );
      if (intent == CycleReminderCleanupIntent.accountDeletion) {
        await deletePreferences(userId);
      }
      return failedCancellations;
    });
  }
}
