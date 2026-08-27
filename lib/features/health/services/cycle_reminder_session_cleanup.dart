import 'cycle_reminder_mutation_gate.dart';
import 'cycle_reminder_notification_lifecycle.dart';

class CycleReminderSessionCleanup {
  const CycleReminderSessionCleanup(this._mutationGate, this._lifecycle);

  final CycleReminderMutationGate _mutationGate;
  final CycleReminderNotificationLifecycle _lifecycle;

  Future<int> cancelAfterCurrentMutations(String userId) {
    return _mutationGate.run(
      userId,
      () => _lifecycle.cancelAllCycleReminders(userId),
    );
  }
}
