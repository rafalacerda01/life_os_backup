import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/features/health/services/cycle_reminder_mutation_gate.dart';
import 'package:life_os/features/health/services/cycle_reminder_notification_lifecycle.dart';
import 'package:life_os/features/health/services/cycle_reminder_session_cleanup.dart';

class _Lifecycle extends Fake implements CycleReminderNotificationLifecycle {
  _Lifecycle(this.events, {this.failedCancellations = 0});

  final List<String> events;
  final int failedCancellations;

  @override
  Future<int> cancelAllCycleReminders(String userId) async {
    events.add('cancel:$userId');
    return failedCancellations;
  }
}

void main() {
  test(
    'session exit drains mutations and preserves preferences by default',
    () async {
      final events = <String>[];
      final gate = CycleReminderMutationGate();
      final started = Completer<void>();
      final release = Completer<void>();
      var preferenceExists = false;
      final mutation = gate.run('user-a', () async {
        started.complete();
        await release.future;
        preferenceExists = true;
      });
      await started.future;
      final cleanup = CycleReminderSessionCleanup(
        gate,
        _Lifecycle(events),
        rotateActionToken: (uid) async => events.add('rotate:$uid'),
        deletePreferences: (_) async {
          preferenceExists = false;
          fail('Session exit must not delete preferences');
        },
      );
      final pending = cleanup.cancelAfterCurrentMutations('user-a');
      expect(events, isEmpty);
      release.complete();
      await mutation;
      expect(await pending, 0);
      expect(preferenceExists, isTrue);
      expect(events, ['rotate:user-a', 'cancel:user-a']);
    },
  );

  test(
    'cleanup aguarda mutação anterior e exclui preferência sem recriação stale',
    () async {
      const userId = 'user-a';
      final events = <String>[];
      final gate = CycleReminderMutationGate();
      final mutationStarted = Completer<void>();
      final allowMutation = Completer<void>();
      var preferenceExists = false;

      final pendingMutation = gate.run(userId, () async {
        events.add('save-start:$userId');
        mutationStarted.complete();
        await allowMutation.future;
        preferenceExists = true;
        events.add('save-end:$userId');
      });
      await mutationStarted.future;

      final cleanup = CycleReminderSessionCleanup(
        gate,
        _Lifecycle(events, failedCancellations: 2),
        rotateActionToken: (exactUserId) async {
          events.add('rotate:$exactUserId');
        },
        deletePreferences: (exactUserId) async {
          events.add('delete:$exactUserId');
          preferenceExists = false;
        },
      );

      final pendingCleanup = cleanup.cancelAfterCurrentMutations(
        userId,
        intent: CycleReminderCleanupIntent.accountDeletion,
      );
      expect(events, <String>['save-start:$userId']);
      allowMutation.complete();

      await pendingMutation;
      expect(await pendingCleanup, 2);
      expect(preferenceExists, isFalse);
      expect(events, <String>[
        'save-start:$userId',
        'save-end:$userId',
        'rotate:$userId',
        'cancel:$userId',
        'delete:$userId',
      ]);
    },
  );

  test(
    'falha ao excluir propaga depois de rotacionar e cancelar o UID exato',
    () async {
      const userId = 'user-a';
      final events = <String>[];
      final cleanup = CycleReminderSessionCleanup(
        CycleReminderMutationGate(),
        _Lifecycle(events),
        rotateActionToken: (exactUserId) async {
          events.add('rotate:$exactUserId');
        },
        deletePreferences: (exactUserId) async {
          events.add('delete:$exactUserId');
          throw StateError('STORAGE_DELETE_FAILED');
        },
      );

      await expectLater(
        cleanup.cancelAfterCurrentMutations(
          userId,
          intent: CycleReminderCleanupIntent.accountDeletion,
        ),
        throwsStateError,
      );
      expect(events, <String>[
        'rotate:$userId',
        'cancel:$userId',
        'delete:$userId',
      ]);
    },
  );
}
