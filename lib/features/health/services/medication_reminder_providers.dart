import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/core/database/database_provider.dart';
import 'package:life_os/core/services/firebase_auth_provider.dart';
import 'package:life_os/core/services/notification_preferences.dart';
import 'package:life_os/core/services/notification_service.dart';

import 'medication_reminder_lifecycle.dart';
import 'medication_reminder_session_reconciler.dart';

final notificationServiceProvider = Provider<NotificationService>((ref) {
  return NotificationService.instance;
});

final medicationReminderLifecycleProvider =
    Provider<MedicationReminderLifecycle>((ref) {
      return MedicationReminderLifecycleService(
        ref.watch(databaseProvider),
        ref.watch(notificationServiceProvider),
      );
    });

final medicationReminderSessionReconcilerProvider =
    Provider<MedicationReminderSessionReconciler>((ref) {
      final auth = ref.watch(firebaseAuthProvider);
      final store = ref.watch(notificationPreferencesStoreProvider);
      final reconciler = MedicationReminderSessionReconciler(
        lifecycle: ref.watch(medicationReminderLifecycleProvider),
        loadPreferences: store.load,
        currentUserId: () => auth.currentUser?.uid,
      );
      ref.onDispose(reconciler.dispose);
      return reconciler;
    });
