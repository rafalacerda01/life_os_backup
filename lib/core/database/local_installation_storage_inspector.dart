import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'local_profile_admission.dart';
import '../services/native_notification_registry.dart';

/// Conservative inspection before opening the local profile. It never opens,
/// migrates or removes a secondary store. The isolated reminder host may
/// recognize its own registry and Android plugin preferences.
class LocalInstallationStorageInspector {
  LocalInstallationStorageInspector({
    required this.documentsDirectory,
    required this.supportDirectory,
    this.allowInstallationReminders = false,
    this.allowAndroidProfileVerifierCache = false,
    this.allowOfficialStartupCoordinator = false,
  });
  final Future<Directory> Function() documentsDirectory;
  final Future<Directory> Function() supportDirectory;
  final bool allowInstallationReminders;
  final bool allowAndroidProfileVerifierCache;
  final bool allowOfficialStartupCoordinator;
  Never _blocked() => throw StateError('LOCAL_PROFILE_MIGRATION_REQUIRED');

  Future<void> assertNoUnqualifiedSecondaryStores() async {
    final support = await supportDirectory();
    if (await support.exists()) {
      await for (final entry in support.list(
        recursive: true,
        followLinks: false,
      )) {
        final name = p.basename(entry.path);
        const reminderFile = NativeNotificationRegistry.installationFileName;
        if (name.startsWith(reminderFile)) {
          final exactFile = name == reminderFile;
          final knownSidecar = const {
            '-wal',
            '-shm',
            '-journal',
          }.contains(name.substring(reminderFile.length));
          if (!allowInstallationReminders ||
              !p.equals(p.dirname(entry.path), support.path) ||
              entry is! File ||
              (!exactFile && !knownSidecar) ||
              (!exactFile &&
                  !await File(p.join(support.path, reminderFile)).exists())) {
            _blocked();
          }
        }
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
        final name = p.basename(entry.path);
        final knownReminderPreference =
            allowInstallationReminders &&
            const {
              'notification_plugin_cache.xml',
              'scheduled_notifications.xml',
            }.contains(name);
        if (entry is! File ||
            (!knownReminderPreference && !qualifiedNames.contains(name))) {
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
        if (entry is Directory) continue;
        if (allowOfficialStartupCoordinator &&
            entry is File &&
            await _isOfficialStartupFile(entry, support.parent)) {
          continue;
        }
        if (allowAndroidProfileVerifierCache &&
            entry is File &&
            p.equals(entry.path, p.join(support.path, 'profileInstalled')) &&
            await _isAndroidProfileVerifierCache(entry)) {
          continue;
        }
        _blocked();
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

  Future<bool> _isOfficialStartupFile(File file, Directory dataRoot) async {
    final path = p.join(
      dataRoot.path,
      'no_backup',
      'life_os_native_startup_v1',
    );
    if (!p.equals(p.dirname(file.path), path)) return false;
    final length = await file.length();
    return switch (p.basename(file.path)) {
      'session.lock' || 'writer.lock' => length == 0,
      'startup.json' => length > 0 && length <= 1024,
      _ => false,
    };
  }

  // AndroidX ProfileVerifier 1.4 writes two big-endian ints and two longs.
  Future<bool> _isAndroidProfileVerifierCache(File file) async {
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file ||
        await file.length() != 24)
      return false;
    final bytes = await file.readAsBytes();
    if (bytes.length != 24) return false;
    final cache = ByteData.sublistView(bytes);
    const outcomes = {0, 1, 2, 3, 65536, 131072, 196608, 262144, 327680};
    return cache.getInt32(0) == 1 &&
        outcomes.contains(cache.getInt32(4)) &&
        cache.getInt64(8) > 0 &&
        cache.getInt64(16) >= 0;
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
