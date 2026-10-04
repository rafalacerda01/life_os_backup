import 'dart:io';

import 'package:drift/native.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/local_database_identity.dart';
import 'package:life_os/core/database/user_database_factory.dart';

class TestSessionDatabase extends AppDatabase {
  TestSessionDatabase(LocalDatabaseIdentity identity, File file)
    : super.forUser(identity: identity, executor: NativeDatabase(file));

  bool closed = false;
  int closeCalls = 0;

  @override
  Future<void> closeDatabase() async {
    closeCalls++;
    await super.closeDatabase();
    closed = true;
  }
}

/// Test-only file storage. Production encryption has separate real-factory tests.
class TestUserDatabaseFactory extends UserDatabaseFactory {
  TestUserDatabaseFactory()
    : directory = Directory.systemTemp.createTempSync('session_auth_test_');

  final Directory directory;
  final List<TestSessionDatabase> databases = [];
  final List<String> openedUserIds = [];
  TestSessionDatabase? last;
  final Map<String, AppDatabase> _inspectionViews = {};

  AppDatabase inspectClosed(String uid, String? Function() sessionReader) {
    return _inspectionViews.putIfAbsent(uid, () {
      // A test-only reader verifies persisted rows after the real session DB
      // was closed. It is never published through databaseProvider.
      final db = AppDatabase(
        executor: NativeDatabase(LocalDatabaseIdentity(uid).fileIn(directory)),
      );
      db.localMutations.bindSessionReader(sessionReader);
      return db;
    });
  }

  TestSessionDatabase inspect(String uid, {String? Function()? sessionReader}) {
    final identity = LocalDatabaseIdentity(uid);
    final existing = databases.where(
      (db) => db.identity == identity && !db.closed,
    );
    if (existing.isNotEmpty) return existing.last;
    final database = TestSessionDatabase(identity, identity.fileIn(directory));
    if (sessionReader != null)
      database.localMutations.bindSessionReader(sessionReader);
    databases.add(database);
    return database;
  }

  @override
  Future<AppDatabase> open(LocalDatabaseIdentity identity) async {
    await _inspectionViews.remove(identity.uid)?.close();
    openedUserIds.add(identity.uid);
    last = inspect(identity.uid);
    return last!;
  }

  Future<void> dispose() async {
    for (final view in _inspectionViews.values) {
      await view.close();
    }
    _inspectionViews.clear();
    for (final database in databases) {
      if (!database.closed) await database.closeDatabase();
    }
    directory.deleteSync(recursive: true);
  }
}
