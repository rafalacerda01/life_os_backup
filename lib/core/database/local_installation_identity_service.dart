import 'dart:io';

import 'package:path/path.dart' as p;

import 'local_database_identity.dart';
import 'local_profile_admission.dart';

/// Pre-migration primitive. It does not start a session or touch Firebase.
///
/// On an upgraded installation, a missing local profile marker MUST NOT create
/// a new empty database when older Life OS database artifacts still exist.
/// Importing UID-scoped encrypted databases requires a separately reviewed
/// migration with proof that their encryption keys remain accessible.
class LocalInstallationIdentityService {
  LocalInstallationIdentityService({
    required this.readSavedId,
    required this.writeSavedId,
    required this.documentsDirectory,
    required this.newId,
    required this.assertFreshInstall,
  });

  static const storageKey = 'life_os_local_installation_id_v1';
  static const _databaseSuffixes = {
    '',
    '-wal',
    '-shm',
    '-journal',
    '.plaintext-backup',
    '.plaintext-backup-wal',
    '.plaintext-backup-shm',
    '.plaintext-backup-journal',
    '.encryption-candidate',
    '.encryption-candidate-wal',
    '.encryption-candidate-shm',
    '.encryption-candidate-journal',
  };

  final Future<String?> Function() readSavedId;
  final Future<void> Function(String id) writeSavedId;
  final Future<Directory> Function() documentsDirectory;
  final String Function() newId;

  /// Checks other persisted stores (preferences, secure storage, etc.) without
  /// mutating them. A failure must stop first-time local provisioning.
  final Future<void> Function() assertFreshInstall;

  Future<LocalDatabaseIdentity>? _resolved;

  /// Cache errors per instance. SQLite admission serializes separate instances
  /// and isolates that use this installation directory.
  Future<LocalDatabaseIdentity> resolve() => _resolved ??= _serializeResolve();

  Future<LocalDatabaseIdentity> _serializeResolve() async {
    final directory = await documentsDirectory();
    return LocalProfileAdmission(directory).run(_resolve);
  }

  Future<LocalDatabaseIdentity> _resolve() async {
    final existing = await readSavedId();
    if (existing != null &&
        !LocalDatabaseIdentity.isValidLocalInstallationId(existing)) {
      throw StateError('LOCAL_PROFILE_ID_INVALID');
    }

    final identity = existing == null ? null : LocalDatabaseIdentity(existing);
    final directory = await documentsDirectory();
    if (!await directory.exists()) {
      throw StateError('LOCAL_PROFILE_DIRECTORY_UNAVAILABLE');
    }

    // Detect other profiles, old UID-backed files and all known SQLite
    // sidecars before publishing any installation identity.
    await for (final entity in directory.list(followLinks: false)) {
      if (LocalProfileAdmission.isCurrentFile(entity.path)) continue;
      final filename = p.basename(entity.path);
      final possibleLifeOsDatabase =
          filename.startsWith('life_os.sqlite') ||
          filename.startsWith('life_os_');
      if (!possibleLifeOsDatabase) continue;

      if (identity == null ||
          !filename.startsWith(identity.fileName) ||
          !_databaseSuffixes.contains(
            filename.substring(identity.fileName.length),
          ) ||
          await FileSystemEntity.type(entity.path, followLinks: false) !=
              FileSystemEntityType.file) {
        throw StateError('LOCAL_PROFILE_MIGRATION_REQUIRED');
      }
    }

    if (identity != null) return identity;

    // Legacy user data can survive without the expected SQLite files.
    // Never provision a new identity before auditing non-DB persistence.
    await assertFreshInstall();

    final generated = newId();
    if (!LocalDatabaseIdentity.isValidLocalInstallationId(generated)) {
      throw StateError('LOCAL_PROFILE_GENERATOR_INVALID');
    }
    // The marker is written only after the legacy-data guard. No databases
    // are opened, moved, deleted or re-encrypted by this component.
    await writeSavedId(generated);
    if (await readSavedId() != generated) {
      throw StateError('LOCAL_PROFILE_ID_NOT_PERSISTED');
    }
    return LocalDatabaseIdentity(generated);
  }
}
