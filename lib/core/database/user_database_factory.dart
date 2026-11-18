import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';
import 'package:life_os/core/db/user_db_key_manager.dart';

import 'app_database.dart';
import 'database_encryption.dart';
import 'local_database_identity.dart';
import 'database_sync_policy.dart';

/// Creates explicitly scoped databases; does not publish a current database.
/// Callers must await closeDatabase() before a future session cutover.
class UserDatabaseFactory {
  UserDatabaseFactory({
    UserDbKeyManager? keyManager,
    Future<Directory> Function()? directoryProvider,
    this.syncPolicy = DatabaseSyncPolicy.remoteEnabled,
  }) : _keyManager = keyManager ?? UserDbKeyManager.instance,
       _directoryProvider =
           directoryProvider ?? getApplicationDocumentsDirectory;

  final UserDbKeyManager _keyManager;
  final DatabaseSyncPolicy syncPolicy;
  final Future<Directory> Function() _directoryProvider;

  Future<AppDatabase> open(LocalDatabaseIdentity identity) async {
    if (syncPolicy == DatabaseSyncPolicy.localOnly &&
        !identity.isLocalInstallation) {
      throw ArgumentError('LOCAL_PROFILE_IDENTITY_REQUIRED');
    }
    final directory = await _directoryProvider();
    final file = identity.fileIn(directory);
    if (!await file.exists() &&
        !await File('${file.path}.plaintext-backup').exists() &&
        !await File('${file.path}.encryption-candidate').exists()) {
      for (final suffix in const ['-wal', '-shm', '-journal']) {
        if (await File('${file.path}$suffix').exists()) {
          throw StateError('USER_DATABASE_ORPHAN_SIDECAR');
        }
      }
    }
    var alreadyExists = false;
    for (final suffix in const [
      '',
      '-wal',
      '-shm',
      '-journal',
      '.encryption-candidate',
      '.plaintext-backup',
    ]) {
      if (await File('${file.path}$suffix').exists()) {
        alreadyExists = true;
        break;
      }
    }
    if (alreadyExists && syncPolicy == DatabaseSyncPolicy.remoteEnabled) {
      await _keyManager.getEncryptionKey(identity, allowCreate: false);
    }
    final bootstrap = DatabaseEncryptionBootstrap();
    Future<String> keyProvider({required bool allowCreate}) => _keyManager
        .getEncryptionKey(identity, allowCreate: allowCreate && !alreadyExists);
    final key = syncPolicy == DatabaseSyncPolicy.localOnly
        ? await bootstrap.prepareLocalProfile(
            databaseFile: file,
            keyProvider: keyProvider,
            expectedSchemaVersion: AppDatabase.currentSchemaVersion,
          )
        : await bootstrap.prepare(databaseFile: file, keyProvider: keyProvider);
    return AppDatabase.forUser(
      identity: identity,
      executor: _openEncryptedDatabase(file, key),
      syncPolicy: syncPolicy,
    );
  }
}

// Keep the isolate callback outside the factory's closure context: it must not
// capture secure storage, providers or an AppDatabase under construction.
QueryExecutor _openEncryptedDatabase(File file, String key) =>
    NativeDatabase.createInBackground(
      file,
      setup: (database) {
        DatabaseEncryptionBootstrap.configureEncryptedConnection(database, key);
        database.execute('PRAGMA journal_mode = WAL;');
        database.execute('PRAGMA synchronous = NORMAL;');
        database.execute('PRAGMA foreign_keys = ON;');
      },
    );
