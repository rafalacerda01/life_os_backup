import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
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
      );
    });
