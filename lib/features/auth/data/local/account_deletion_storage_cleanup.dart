import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:life_os/core/services/notification_preferences.dart';
import 'package:life_os/core/services/notification_service.dart';
import 'package:life_os/core/services/owned_notification_service.dart';
import 'package:life_os/core/storage/secure_storage_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/core/database/local_database_identity.dart';
import 'package:life_os/core/database/user_database_storage_destroyer.dart';
import 'package:life_os/core/storage/ai_consent_local_cache.dart';
import 'package:life_os/features/health/presentation/cycle/cycle_reminder_preferences.dart';
import 'package:life_os/features/health/services/cycle_reminder_action_security.dart';

class AccountDeletionStorageCleanup {
  AccountDeletionStorageCleanup({
    required this.destroyer,
    required this.deletePreferences,
    required this.deleteActionToken,
    required this.deleteAiCache,
    this.deleteOwnedState,
  });

  final Future<void> Function(LocalDatabaseIdentity)? deleteOwnedState;
  final UserDatabaseStorageDestroyer destroyer;
  final Future<void> Function(String) deletePreferences;
  final Future<void> Function(String) deleteActionToken;
  final Future<void> Function(String) deleteAiCache;

  Future<void> destroy(LocalDatabaseIdentity identity) async {
    if (identity.generation != null) {
      final owned = deleteOwnedState;
      if (!identity.isBound || owned == null)
        throw StateError('GENERATIONAL_CLEANUP_PORT_REQUIRED');
      await owned(identity);
      await destroyer.destroy(identity);
      return;
    }
    await destroyer.destroy(identity);
    await deletePreferences(identity.uid);
    await deleteActionToken(identity.uid);
    await deleteAiCache(identity.uid);
  }
}

final accountDeletionStorageCleanupProvider =
    Provider<AccountDeletionStorageCleanup>((ref) {
      return AccountDeletionStorageCleanup(
        destroyer: UserDatabaseStorageDestroyer(),
        // Legacy callbacks are explicitly unscoped, never the current B store.
        deletePreferences: const CycleReminderPreferencesStore(
          SecureCycleReminderPreferencesStorage(
            FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            ),
          ),
        ).delete,
        deleteActionToken: CycleReminderActionTokenStore(
          const SecureCycleReminderActionTokenStorage(
            FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            ),
          ),
        ).delete,
        deleteOwnedState: (identity) async {
          const storage = FlutterSecureStorage(
            aOptions: AndroidOptions(encryptedSharedPreferences: true),
          );
          Future<Set<String>> keys() async =>
              (await storage.readAll()).keys.toSet();
          // Each port receives the captured identity. It never selects currentUser.
          await CycleReminderPreferencesStore.scoped(
            const SecureCycleReminderPreferencesStorage(storage),
            identity,
            listKeys: keys,
          ).retire();
          await CycleReminderActionTokenStore.scoped(
            const SecureCycleReminderActionTokenStorage(storage),
            identity,
            listKeys: keys,
          ).retire();
          await AiConsentLocalCache.instance.deleteForAccount(
            identity.uid,
            identity: identity,
          );
          await NotificationPreferencesStore.scoped(identity).retire();
          await SecureStorageService.scoped(
            const FlutterSecureStorage(),
            identity,
          ).retire();
          await OwnedNotificationService(
            identity: identity,
            native: NotificationService.instance,
            isCurrent: () => false,
          ).retire();
        },
        deleteAiCache: AiConsentLocalCache.instance.deleteForAccount,
      );
    });
