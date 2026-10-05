import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:life_os/core/db/user_db_key_manager.dart';

import 'local_database_identity.dart';

/// The caller must close/drain the identity before invoking this primitive.
class UserDatabaseStorageDestroyer {
  UserDatabaseStorageDestroyer({
    Future<Directory> Function()? directoryProvider,
    UserDbKeyManager? keyManager,
    Future<void> Function(File)? deleteFile,
  }) : _directoryProvider =
           directoryProvider ?? getApplicationDocumentsDirectory,
       _keyManager = keyManager ?? UserDbKeyManager.instance,
       _deleteFile = deleteFile ?? _deleteExistingFile;

  final Future<Directory> Function() _directoryProvider;
  final UserDbKeyManager _keyManager;
  final Future<void> Function(File) _deleteFile;

  static List<File> artifacts(
    LocalDatabaseIdentity identity,
    Directory directory,
  ) {
    final path = identity.fileIn(directory).path;
    return [
      for (final artifact in ['', '.encryption-candidate', '.plaintext-backup'])
        for (final sidecar in ['', '-wal', '-shm', '-journal'])
          File('$path$artifact$sidecar'),
    ];
  }

  Future<void> destroy(LocalDatabaseIdentity identity) async {
    final files = artifacts(identity, await _directoryProvider());
    for (final file in files) {
      await _deleteFile(file);
    }
    for (final file in files) {
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw StateError('ACCOUNT_STORAGE_FILES_REMAIN');
      }
    }
    // Never remove the sole decryption key while any target artifact remains.
    await _keyManager.deleteKey(identity);
  }

  static Future<void> _deleteExistingFile(File file) async {
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    if (type != FileSystemEntityType.file) {
      throw StateError('ACCOUNT_STORAGE_UNEXPECTED_ARTIFACT');
    }
    await file.delete();
  }
}
