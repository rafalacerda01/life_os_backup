import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'local_installation_identity_service.dart';

/// Prepared but intentionally NOT wired to the app's authenticated boot.
/// An explicit migration gate must run before replacing Firebase sessions.
final localInstallationIdentityServiceProvider =
    Provider<LocalInstallationIdentityService>((ref) {
      const storage = FlutterSecureStorage(
        aOptions: AndroidOptions(encryptedSharedPreferences: true),
        iOptions: IOSOptions(
          accessibility: KeychainAccessibility.first_unlock,
        ),
      );
      return LocalInstallationIdentityService(
        readSavedId: () => storage.read(
          key: LocalInstallationIdentityService.storageKey,
        ),
        writeSavedId: (id) => storage.write(
          key: LocalInstallationIdentityService.storageKey,
          value: id,
        ),
        documentsDirectory: getApplicationDocumentsDirectory,
        newId: () => 'local-v1-${const Uuid().v4()}',
        assertFreshInstall: () async {
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
