import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'local_database_identity.dart';
import 'database_encryption.dart';
import 'local_profile_admission.dart';

/// A provenance record for local database creation and eligible schema upgrades.
/// It never authorizes adopting a UID database, rekeying, deleting data or paid access.
final class LocalProfileBootstrapJournal {
  LocalProfileBootstrapJournal(this._storage);
  final FlutterSecureStorage _storage;
  static const storageKey = 'life_os_local_profile_bootstrap_v1';

  Future<T> run<T>({
    required LocalDatabaseIdentity identity,
    required File databaseFile,
    required int schemaVersion,
    int? predecessorSchemaVersion,
    required Future<T> Function(LocalProfileOpenPermit? permit) open,
    required Future<void> Function(T value) closeOnFailure,
  }) async {
    LocalProfileAdmission.requireCurrent(databaseFile.parent);
    await DatabaseEncryptionBootstrap.assertLocalProfileFiles(databaseFile);
    if (!identity.isLocalInstallation ||
        p.basename(databaseFile.path) != identity.fileName) {
      throw StateError('LOCAL_PROFILE_JOURNAL_IDENTITY_INVALID');
    }
    final stored = await _storage.read(key: storageKey);
    Map<String, Object?>? record;
    if (stored != null) {
      try {
        final decoded = jsonDecode(stored);
        if (decoded is! Map<String, dynamic> ||
            decoded.length != 8 ||
            decoded['v'] is! int ||
            decoded['v'] != 1 ||
            decoded['profile'] != identity.uid ||
            decoded['namespace'] != identity.namespace ||
            decoded['file'] != identity.fileName ||
            decoded['alias'] != identity.keyAlias ||
            decoded['schema'] is! int ||
            (decoded['schema'] != schemaVersion &&
                decoded['schema'] != predecessorSchemaVersion) ||
            decoded['nonce'] is! String ||
            !LocalDatabaseIdentity.isValidLocalInstallationId(
              'local-v1-${decoded['nonce']}',
            ) ||
            !const ['CREATING', 'READY'].contains(decoded['phase'])) {
          throw const FormatException();
        }
        record = Map<String, Object?>.from(decoded);
      } catch (_) {
        throw StateError('LOCAL_PROFILE_BOOTSTRAP_JOURNAL_INVALID');
      }
    }
    final exists = await databaseFile.exists();
    if (record?['phase'] == 'READY' && !exists) {
      throw StateError('LOCAL_PROFILE_DATABASE_MISSING');
    }
    if (record == null && !exists) {
      // An existing encryption key without its database is not a fresh install.
      if (await _storage.read(key: identity.keyAlias) != null) {
        throw StateError('LOCAL_PROFILE_DATABASE_MISSING');
      }
      // Refuse orphan sidecars and replacement artifacts before any journal write.
      for (final suffix in [
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
      ]) {
        if (await FileSystemEntity.type(
              '${databaseFile.path}$suffix',
              followLinks: false,
            ) !=
            FileSystemEntityType.notFound) {
          throw StateError('LOCAL_PROFILE_BOOTSTRAP_ARTIFACTS_REQUIRE_REVIEW');
        }
      }
      record = _record(identity, schemaVersion, const Uuid().v4(), 'CREATING');
      await _persist(record);
    }
    final creating = record?['phase'] == 'CREATING';
    final recordedSchema = record?['schema'] as int?;
    final predecessor = recordedSchema == schemaVersion ? null : recordedSchema;
    final permit = creating || predecessor != null
        ? LocalProfileOpenPermit._(
            databaseFile.path,
            identity,
            schemaVersion,
            creating,
            predecessor,
          )
        : null;
    late T result;
    var opened = false;
    try {
      result = await open(permit);
      opened = true;
      // Current-schema encrypted staged profiles created before this journal
      // can be recorded only AFTER their read-only integrity check succeeds.
      if (record?['phase'] != 'READY' || predecessor != null) {
        await _persist(
          _record(
            identity,
            schemaVersion,
            record?['nonce'] as String? ?? const Uuid().v4(),
            'READY',
          ),
        );
      }
      return result;
    } catch (_) {
      if (opened) await closeOnFailure(result);
      rethrow;
    } finally {
      permit?._active = false;
    }
  }

  Map<String, Object?> _record(
    LocalDatabaseIdentity id,
    int schema,
    String nonce,
    String phase,
  ) => {
    'v': 1,
    'profile': id.uid,
    'namespace': id.namespace,
    'file': id.fileName,
    'alias': id.keyAlias,
    'schema': schema,
    'nonce': nonce,
    'phase': phase,
  };

  Future<void> _persist(Map<String, Object?> record) async {
    final encoded = jsonEncode(record);
    await _storage.write(key: storageKey, value: encoded);
    if (await _storage.read(key: storageKey) != encoded) {
      throw StateError('LOCAL_PROFILE_BOOTSTRAP_JOURNAL_NOT_PERSISTED');
    }
  }
}

/// Authorization issued only after validating the local bootstrap journal.
final class LocalProfileOpenPermit {
  LocalProfileOpenPermit._(
    this._path,
    this._identity,
    this._schema,
    this._creating,
    this._predecessor,
  );

  final String _path;
  final LocalDatabaseIdentity _identity;
  final int _schema;
  final bool _creating;
  final int? _predecessor;
  bool _active = true;

  bool _isCurrent(int schema) =>
      _active &&
      schema == _schema &&
      LocalProfileAdmission.isCurrentFile(
        p.join(p.dirname(_path), LocalProfileAdmission.fileName),
      );

  bool _matchesFile(File file) =>
      p.normalize(p.absolute(file.path)) == p.normalize(p.absolute(_path));

  bool permits(File file, int schema) =>
      _creating && _isCurrent(schema) && _matchesFile(file);

  bool permitsUpgrade(File file, int from, int to) =>
      _matchesFile(file) && permitsUpgradeFor(_identity, from, to);

  bool permitsUpgradeFor(LocalDatabaseIdentity identity, int from, int to) =>
      identity == _identity && from == _predecessor && _isCurrent(to);
}
