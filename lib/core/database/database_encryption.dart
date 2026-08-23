import 'dart:async';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

typedef DatabaseKeyProvider =
    Future<String> Function({required bool allowCreate});

enum DatabaseEncryptionMigrationStage { candidateValidated, sourceBackedUp }

enum _DatabaseFileKind { missing, plaintext, opaque }

class DatabaseEncryptionBootstrap {
  DatabaseEncryptionBootstrap({Sqlite3? sqlite, this._migrationObserver})
    : _sqlite = sqlite ?? sqlite3;

  static const String cipher = 'chacha20';
  static const List<int> _sqliteHeader = <int>[
    0x53,
    0x51,
    0x4c,
    0x69,
    0x74,
    0x65,
    0x20,
    0x66,
    0x6f,
    0x72,
    0x6d,
    0x61,
    0x74,
    0x20,
    0x33,
    0x00,
  ];

  final Sqlite3 _sqlite;
  final void Function(DatabaseEncryptionMigrationStage stage)?
  _migrationObserver;

  Future<String> prepare({
    required File databaseFile,
    required DatabaseKeyProvider keyProvider,
  }) async {
    await _recoverInterruptedReplacement(databaseFile);

    final kind = _classify(databaseFile);

    switch (kind) {
      case _DatabaseFileKind.missing:
        final key = await keyProvider(allowCreate: true);
        _validateKey(key);
        _createEncryptedDatabase(databaseFile, key);
        return key;

      case _DatabaseFileKind.plaintext:
        _preparePlaintextSource(databaseFile);
        final key = await keyProvider(allowCreate: true);
        _validateKey(key);
        await _migratePlaintextCopy(databaseFile, key);
        return key;

      case _DatabaseFileKind.opaque:
        final key = await keyProvider(allowCreate: false);
        _validateKey(key);
        _validateEncryptedDatabase(databaseFile, key);
        await _removeCompletedMigrationArtifacts(databaseFile);
        return key;
    }
  }

  static void configureEncryptedConnection(Database database, String key) {
    _validateKey(key);
    final escapedKey = _escapeSqlString(key);

    database.execute("PRAGMA cipher = '$cipher';");
    database.execute('PRAGMA legacy = 0;');
    database.execute("PRAGMA key = '$escapedKey';");
    database.execute('PRAGMA temp_store = MEMORY;');
  }

  static bool hasPlaintextHeader(File file) {
    if (!file.existsSync() || file.lengthSync() < _sqliteHeader.length) {
      return false;
    }

    final handle = file.openSync();

    try {
      final bytes = handle.readSync(_sqliteHeader.length);

      for (var index = 0; index < _sqliteHeader.length; index += 1) {
        if (bytes[index] != _sqliteHeader[index]) return false;
      }

      return true;
    } finally {
      handle.closeSync();
    }
  }

  _DatabaseFileKind _classify(File file) {
    if (!file.existsSync()) return _DatabaseFileKind.missing;

    if (file.lengthSync() == 0) {
      throw StateError('DATABASE_FILE_EMPTY');
    }

    return hasPlaintextHeader(file)
        ? _DatabaseFileKind.plaintext
        : _DatabaseFileKind.opaque;
  }

  void _createEncryptedDatabase(File file, String key) {
    file.parent.createSync(recursive: true);
    final database = _sqlite.open(file.path);

    try {
      _assertSqlite3MultipleCiphers(database);
      configureEncryptedConnection(database, key);
      database.execute('PRAGMA journal_mode = DELETE;');
      database.execute('VACUUM;');
      _assertHealthy(database);
    } finally {
      database.dispose();
    }

    _validateEncryptedDatabase(file, key);
  }

  void _preparePlaintextSource(File file) {
    final database = _sqlite.open(file.path, mode: OpenMode.readWrite);

    try {
      _assertSqlite3MultipleCiphers(database);
      _assertHealthy(database);
      database.execute('PRAGMA wal_checkpoint(TRUNCATE);');
      final journalMode = database.select('PRAGMA journal_mode = DELETE;');

      if (journalMode.isEmpty ||
          journalMode.first.values.first.toString().toLowerCase() != 'delete') {
        throw StateError('DATABASE_WAL_DISABLE_FAILED');
      }

      _assertHealthy(database);
    } finally {
      database.dispose();
    }

    _removeSidecars(file);
  }

  Future<void> _migratePlaintextCopy(File source, String key) async {
    final candidate = _candidateFor(source);
    final backup = _backupFor(source);

    if (candidate.existsSync() || backup.existsSync()) {
      throw StateError('DATABASE_MIGRATION_ARTIFACT_CONFLICT');
    }

    await source.copy(candidate.path);

    try {
      final database = _sqlite.open(candidate.path, mode: OpenMode.readWrite);

      try {
        _assertSqlite3MultipleCiphers(database);
        _assertHealthy(database);
        database.execute('PRAGMA journal_mode = DELETE;');
        final escapedKey = _escapeSqlString(key);
        database.execute("PRAGMA cipher = '$cipher';");
        database.execute('PRAGMA legacy = 0;');
        database.execute("PRAGMA rekey = '$escapedKey';");
        _assertHealthy(database);
      } finally {
        database.dispose();
      }

      _validateEncryptedDatabase(candidate, key);
      _migrationObserver?.call(
        DatabaseEncryptionMigrationStage.candidateValidated,
      );
      await _replaceWithValidatedCandidate(
        source: source,
        candidate: candidate,
        backup: backup,
        key: key,
      );
    } catch (_) {
      if (candidate.existsSync() && source.existsSync()) {
        await candidate.delete();
      }
      rethrow;
    } finally {
      _removeSidecars(candidate);
    }
  }

  Future<void> _replaceWithValidatedCandidate({
    required File source,
    required File candidate,
    required File backup,
    required String key,
  }) async {
    await source.rename(backup.path);

    try {
      _migrationObserver?.call(DatabaseEncryptionMigrationStage.sourceBackedUp);
      await candidate.rename(source.path);
    } catch (_) {
      await backup.rename(source.path);
      rethrow;
    }

    try {
      _validateEncryptedDatabase(source, key);
      await backup.delete();
    } catch (_) {
      if (source.existsSync()) {
        await source.rename(candidate.path);
      }
      if (backup.existsSync()) {
        await backup.rename(source.path);
      }
      rethrow;
    }
  }

  void _validateEncryptedDatabase(File file, String key) {
    if (hasPlaintextHeader(file)) {
      throw StateError('DATABASE_ENCRYPTION_NOT_APPLIED');
    }

    final database = _sqlite.open(file.path, mode: OpenMode.readOnly);

    try {
      configureEncryptedConnection(database, key);
      _assertSqlite3MultipleCiphers(database);
      _assertHealthy(database);
      database.select('SELECT count(*) FROM sqlite_master;');
    } finally {
      database.dispose();
    }
  }

  void _assertSqlite3MultipleCiphers(Database database) {
    final rows = database.select('PRAGMA cipher;');

    if (rows.isEmpty) {
      throw StateError('SQLITE3MC_NOT_AVAILABLE');
    }
  }

  void _assertHealthy(Database database) {
    final result = database.select('PRAGMA quick_check;');

    if (result.length != 1 || result.first.values.first != 'ok') {
      throw StateError('DATABASE_INTEGRITY_CHECK_FAILED');
    }
  }

  Future<void> _recoverInterruptedReplacement(File source) async {
    final candidate = _candidateFor(source);
    final backup = _backupFor(source);

    if (!source.existsSync() && backup.existsSync()) {
      await backup.rename(source.path);
    }

    if (!source.existsSync() && candidate.existsSync()) {
      throw StateError('DATABASE_MIGRATION_SOURCE_MISSING');
    }

    if (source.existsSync() && candidate.existsSync() && !backup.existsSync()) {
      await candidate.delete();
      _removeSidecars(candidate);
    }
  }

  Future<void> _removeCompletedMigrationArtifacts(File source) async {
    final backup = _backupFor(source);
    final candidate = _candidateFor(source);

    if (backup.existsSync()) await backup.delete();
    if (candidate.existsSync()) await candidate.delete();
    _removeSidecars(backup);
    _removeSidecars(candidate);
  }

  static File _candidateFor(File source) =>
      File('${source.path}.encryption-candidate');

  static File _backupFor(File source) =>
      File('${source.path}.plaintext-backup');

  static void _removeSidecars(File file) {
    for (final suffix in const ['-wal', '-shm', '-journal']) {
      final sidecar = File('${file.path}$suffix');
      if (sidecar.existsSync()) sidecar.deleteSync();
    }
  }

  static void _validateKey(String key) {
    if (key.trim().isEmpty) throw StateError('DATABASE_KEY_INVALID');
  }

  static String _escapeSqlString(String value) => value.replaceAll("'", "''");
}
