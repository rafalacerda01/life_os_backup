import 'cycle_reminder_mutation_gate.dart';
import 'cycle_reminder_notification_lifecycle.dart';

typedef CycleReminderActionTokenRotation = Future<void> Function(String userId);

class CycleReminderSessionCleanup {
  const CycleReminderSessionCleanup(
    this._mutationGate,
    this._lifecycle, {
    required this.rotateActionToken,
  });

  final CycleReminderMutationGate _mutationGate;
  final CycleReminderNotificationLifecycle _lifecycle;
  final CycleReminderActionTokenRotation rotateActionToken;

  Future<int> cancelAfterCurrentMutations(String userId) {
    return _mutationGate.run(userId, () async {
      await rotateActionToken(userId);
      return _lifecycle.cancelAllCycleReminders(userId);
    });
  }
}
