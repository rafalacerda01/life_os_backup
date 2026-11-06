import 'package:life_os/core/database/local_account_session.dart';
import 'package:life_os/core/services/owned_notification_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/core/database/database_provider.dart';
import 'package:life_os/core/services/firebase_auth_provider.dart';
import 'package:life_os/core/services/notification_preferences.dart';
import 'package:life_os/core/services/notification_service.dart';

import 'medication_reminder_lifecycle.dart';
import 'medication_reminder_session_reconciler.dart';

final notificationServiceProvider = Provider<NotificationService>((ref) {
  final snapshot = ref.watch(localAccountSessionProvider);
  if (snapshot.identity == null) return NotificationService.instance;
  final lease = ref.read(localAccountSessionProvider.notifier).capture();
  return OwnedNotificationService(
    identity: lease.identity,
    native: NotificationService.instance,
    isCurrent: () => lease.isCurrent,
  );
});

final medicationReminderLifecycleProvider =
    Provider<MedicationReminderLifecycle>((ref) {
      return MedicationReminderLifecycleService(
        ref.watch(databaseProvider),
        ref.watch(notificationServiceProvider),
        loadPreferences: ref.watch(notificationPreferencesStoreProvider).load,
      );
    });

final medicationReminderSessionReconcilerProvider =
    Provider<MedicationReminderSessionReconciler>((ref) {
      final auth = ref.watch(firebaseAuthProvider);
      final captured = ref.watch(localAccountSessionProvider);
      final store = ref.watch(notificationPreferencesStoreProvider);
      final reconciler = MedicationReminderSessionReconciler(
        lifecycle: ref.watch(medicationReminderLifecycleProvider),
        loadPreferences: store.load,
        currentUserId: () =>
            ref.read(localAccountSessionProvider).revision == captured.revision
            ? auth.currentUser?.uid
            : null,
      );
      ref.onDispose(reconciler.dispose);
      return reconciler;
    });
