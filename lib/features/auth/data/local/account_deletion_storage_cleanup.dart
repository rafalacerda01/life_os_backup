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
  });

  final UserDatabaseStorageDestroyer destroyer;
  final Future<void> Function(String) deletePreferences;
  final Future<void> Function(String) deleteActionToken;
  final Future<void> Function(String) deleteAiCache;

  Future<void> destroy(LocalDatabaseIdentity identity) async {
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
        deletePreferences: ref
            .read(cycleReminderPreferencesStoreProvider)
            .delete,
        deleteActionToken: ref
            .read(cycleReminderActionTokenStoreProvider)
            .delete,
        deleteAiCache: AiConsentLocalCache.instance.deleteForAccount,
      );
    });
