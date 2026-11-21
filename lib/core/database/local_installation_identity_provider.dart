import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'local_installation_identity_service.dart';
import 'local_installation_storage_inspector.dart';

final localExpectedInstallationIdProvider = Provider<String?>((ref) => null);

/// Prepared but intentionally NOT wired to the app's authenticated boot.
/// An explicit migration gate must run before replacing Firebase sessions.
final localInstallationIdentityServiceProvider =
    Provider<LocalInstallationIdentityService>((ref) {
      final inspector = ref.watch(localInstallationStorageInspectorProvider);
      const storage = FlutterSecureStorage(
        // Fail closed instead of migrating or resetting existing keys on reads.
        // Gate 02 proved that per-call flags alone were insufficient. Android
        // now requires the pinned preservation boundary in third_party.
        // These staged primitives still do not authorize runtime cutover.
        aOptions: AndroidOptions(
          encryptedSharedPreferences: true,
          resetOnError: false,
          migrateOnAlgorithmChange: false,
        ),
        iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
      );
      return LocalInstallationIdentityService(
        expectedInstallationId: ref.watch(localExpectedInstallationIdProvider),
        readSavedId: () async {
          await inspector.assertNoUnqualifiedSecondaryStores();
          return storage.read(key: LocalInstallationIdentityService.storageKey);
        },
        writeSavedId: (id) => storage.write(
          key: LocalInstallationIdentityService.storageKey,
          value: id,
        ),
        documentsDirectory: inspector.documentsDirectory,
        newId: () => 'local-v1-${const Uuid().v4()}',
        assertFreshInstall: () async {
          await inspector.assertFreshDirectories();
          // A missing SQLite database does NOT prove a fresh installation:
          // legacy credentials and preferences may still be present.
          final secureKeys = (await storage.readAll()).keys;
          if (secureKeys.any(
            (key) =>
                key == 'auth_access_token' ||
                key == 'db_encryption_key' ||
                key.startsWith('db_encryption_key_v2_') ||
                key.startsWith('life_os_'),
          )) {
            throw StateError('LOCAL_PROFILE_MIGRATION_REQUIRED');
          }
          // Keep this key aligned with onboardingCompletedPreferenceKey.
          final onboarding = await SharedPreferencesAsync().getBool(
            'life_os_onboarding_completed_v1',
          );
          if (onboarding != null) {
            throw StateError('LOCAL_PROFILE_MIGRATION_REQUIRED');
          }
        },
      );
    });
