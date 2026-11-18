import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'local_profile_admission.dart';

/// Conservative pre-cutover inspection. It never opens, migrates or removes a
/// secondary store. The P1 notification registry needs an ownership gate of its
/// own before these staged primitives may replace the authenticated runtime.
class LocalInstallationStorageInspector {
  LocalInstallationStorageInspector({
    required this.documentsDirectory,
    required this.supportDirectory,
  });
  final Future<Directory> Function() documentsDirectory;
  final Future<Directory> Function() supportDirectory;
  Never _blocked() => throw StateError('LOCAL_PROFILE_MIGRATION_REQUIRED');

  Future<void> assertNoUnqualifiedSecondaryStores() async {
    final support = await supportDirectory();
    if (await support.exists()) {
      await for (final entry in support.list(
        recursive: true,
        followLinks: false,
      )) {
        final name = p.basename(entry.path);
        if (entry is Link ||
            name.startsWith('life_os_native_ownership_v1.sqlite') ||
            name.startsWith('PersistedInstallation') ||
            name.toLowerCase().contains('firebase')) {
          _blocked();
        }
      }
    }
    final dataRoot = support.parent;
    final prefs = Directory(p.join(dataRoot.path, 'shared_prefs'));
    const qualifiedNames = {
      'FlutterSecureStorage.xml',
      'FlutterSecureKeyStorage.xml',
      'FlutterSecureStorageConfiguration.xml',
      'FlutterSecureStorageConfiguration:FlutterSecureStorage.xml',
      'FlutterSharedPreferences.xml',
    };
    if (await prefs.exists()) {
      await for (final entry in prefs.list(followLinks: false)) {
        if (entry is! File ||
            !qualifiedNames.contains(p.basename(entry.path))) {
          _blocked();
        }
      }
    }
    final databases = Directory(p.join(dataRoot.path, 'databases'));
    if (await databases.exists() && !await databases.list().isEmpty) _blocked();
  }

  Future<void> assertFreshDirectories() async {
    await assertNoUnqualifiedSecondaryStores();
    final support = await supportDirectory();
    // Run before reading preferences, since a plugin may create an empty
    // DataStore while loading it. Existing files are not proof of a new install.
    for (final directory in [
      support,
      Directory(p.join(support.parent.path, 'shared_prefs')),
      Directory(p.join(support.parent.path, 'no_backup')),
    ]) {
      if (!await directory.exists()) continue;
      await for (final entry in directory.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entry is! Directory) _blocked();
      }
    }
    final documents = await documentsDirectory();
    if (!await documents.exists()) _blocked();
    await for (final entry in documents.list(followLinks: false)) {
      // Only the validated, currently held, zero-byte admission file is known.
      if (LocalProfileAdmission.isCurrentFile(entry.path)) continue;
      final name = p.basename(entry.path);
      final engineAsset = name == 'flutter_assets' && entry is Directory;
      final engineTimestamp =
          name.startsWith('res_timestamp-') && entry is File;
      if (!engineAsset && !engineTimestamp) _blocked();
    }
  }
}

final localInstallationStorageInspectorProvider =
    Provider<LocalInstallationStorageInspector>((ref) {
      if (!Platform.isAndroid) {
        throw StateError('LOCAL_NATIVE_STORAGE_PLATFORM_UNQUALIFIED');
      }
      return LocalInstallationStorageInspector(
        documentsDirectory: getApplicationDocumentsDirectory,
        supportDirectory: getApplicationSupportDirectory,
      );
    });
