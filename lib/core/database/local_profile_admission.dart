import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// Serializes bootstrap across SQLite connections, isolates and OS processes.
/// The coordination file is always zero bytes: no schema, profile or key.
/// Qualification on each native platform remains a separate requirement.
final class LocalProfileAdmission {
  LocalProfileAdmission(
    this.directory, {
    this.timeout = const Duration(seconds: 15),
  });

  static const fileName = 'life_os_local_admission_v1.sqlite';
  static final Object _zoneKey = Object();
  final Directory directory;
  final Duration timeout;

  String get _path => p.normalize(p.absolute(p.join(directory.path, fileName)));

  static bool isCurrentFile(String path) {
    final lease = Zone.current[_zoneKey] as _AdmissionLease?;
    return lease != null &&
        lease.active &&
        lease.path == p.normalize(p.absolute(path));
  }

  static void requireCurrent(Directory directory) {
    if (!isCurrentFile(p.join(directory.path, fileName))) {
      throw StateError('LOCAL_PROFILE_ADMISSION_REQUIRED');
    }
  }

  Future<T> run<T>(Future<T> Function() action) async {
    if (isCurrentFile(_path)) return action();
    if (!await directory.exists()) {
      throw StateError('LOCAL_PROFILE_DIRECTORY_UNAVAILABLE');
    }
    final clock = Stopwatch()..start();
    while (true) {
      await _checkFile();
      Database? database;
      try {
        database = sqlite3.open(_path);
        database.execute('PRAGMA busy_timeout=0');
        // This file contains no data and is never committed. MEMORY avoids
        // creating an on-disk rollback journal merely to hold SQLite's lock.
        final mode = database.select('PRAGMA journal_mode=MEMORY');
        if (mode.single.values.single != 'memory') {
          throw StateError('LOCAL_PROFILE_ADMISSION_JOURNAL_MODE_INVALID');
        }
        // Never initializes a schema or writes coordination metadata.
        database.execute('BEGIN EXCLUSIVE');
        final pages =
            database.select('PRAGMA page_count').single.values.single as int;
        final free =
            database.select('PRAGMA freelist_count').single.values.single
                as int;
        if (pages > 1 ||
            free != 0 ||
            database.select('PRAGMA application_id').single.values.single !=
                0) {
          throw StateError('LOCAL_PROFILE_ADMISSION_FILE_INVALID');
        }
        await _checkFile();
        if (database.select('PRAGMA user_version').single.values.single != 0 ||
            database.select('SELECT name FROM sqlite_master').isNotEmpty) {
          throw StateError('LOCAL_PROFILE_ADMISSION_FILE_INVALID');
        }
      } on SqliteException catch (error) {
        database?.dispose();
        if (error.resultCode != 5 && error.resultCode != 6) rethrow;
        if (clock.elapsed >= timeout) {
          throw StateError('LOCAL_PROFILE_ADMISSION_BUSY');
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
        continue;
      } catch (_) {
        database?.dispose();
        rethrow;
      }
      final lease = _AdmissionLease(_path);
      try {
        return await runZoned(action, zoneValues: {_zoneKey: lease});
      } finally {
        lease.active = false;
        try {
          database.execute('ROLLBACK');
        } finally {
          database.dispose();
        }
      }
    }
  }

  Future<void> _checkFile() async {
    final type = await FileSystemEntity.type(_path, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        (type != FileSystemEntityType.file ||
            await File(_path).length() != 0)) {
      throw StateError('LOCAL_PROFILE_ADMISSION_FILE_INVALID');
    }
    for (final suffix in ['-wal', '-shm', '-journal']) {
      if (await FileSystemEntity.type('$_path$suffix', followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw StateError('LOCAL_PROFILE_ADMISSION_FILE_INVALID');
      }
    }
  }
}

final class _AdmissionLease {
  _AdmissionLease(this.path);
  final String path;
  bool active = true;
}
