import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/database_encryption.dart';
import 'package:life_os/core/database/database_sync_policy.dart';
import 'package:life_os/core/database/local_database_identity.dart';
import 'package:life_os/core/database/user_database_factory.dart';
import 'package:life_os/core/db/user_db_key_manager.dart';
import 'package:sqlite3/sqlite3.dart' as sql;
import '../db/fake_secure_storage.dart';

void main() {
  final identity = LocalDatabaseIdentity(
    'local-v1-123e4567-e89b-42d3-a456-426614174000',
  );
  late Directory root;
  late FakeSecureStorage storage;
  late UserDbKeyManager keys;
  late UserDatabaseFactory local;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('lifeos-local-factory-');
    storage = FakeSecureStorage();
    keys = UserDbKeyManager(storage: storage);
    local = UserDatabaseFactory(
      keyManager: keys,
      directoryProvider: () async => root,
      syncPolicy: DatabaseSyncPolicy.localOnly,
    );
  });
  tearDown(() async => root.delete(recursive: true));
  Future<void> seedTask(AppDatabase db) async {
    await db
        .into(db.taskTable)
        .insert(
          TaskTableCompanion.insert(
            id: 'synthetic-task',
            title: 'preserved',
            priority: 'medium',
            date: DateTime.utc(2026, 11, 17),
          ),
        );
  }

  test(
    'fresh local profile is encrypted and reopens with queue guard',
    () async {
      final db = await local.open(identity);
      await seedTask(db);
      expect(db.isLocalOnly, true);
      expect(
        DatabaseEncryptionBootstrap.hasPlaintextHeader(identity.fileIn(root)),
        false,
      );
      final originalKey = Map.of(storage.values);
      await db.close();
      keys.clearAllCaches();
      final reopened = await local.open(identity);
      try {
        expect(
          (await reopened.select(reopened.taskTable).get()).single.title,
          'preserved',
        );
        expect(await reopened.select(reopened.syncQueueTable).get(), isEmpty);
        expect(
          await reopened
              .customSelect(
                "SELECT name FROM sqlite_temp_master WHERE type='trigger'",
              )
              .get(),
          hasLength(3),
        );
        expect(storage.values, originalKey);
      } finally {
        await reopened.close();
      }
    },
  );
  test(
    'current encrypted source with older schema is refused before modification',
    () async {
      final seed = await UserDatabaseFactory(
        keyManager: keys,
        directoryProvider: () async => root,
      ).open(identity);
      await seedTask(seed);
      await seed.customStatement('PRAGMA user_version=10');
      await seed.close();
      final file = identity.fileIn(root);
      final before = await file.readAsBytes();
      final material = Map.of(storage.values);
      keys.clearAllCaches();
      await expectLater(
        local.open(identity),
        throwsA(
          predicate(
            (Object? error) => error.toString().contains(
              'LOCAL_PROFILE_SCHEMA_MIGRATION_REQUIRED',
            ),
          ),
        ),
      );
      expect(await file.readAsBytes(), before);
      expect(storage.values, material);
      expect(storage.deletes, isEmpty);
    },
  );
  test(
    'plaintext cannot trigger a conversion or key creation in local mode',
    () async {
      final file = identity.fileIn(root);
      final db = sql.sqlite3.open(file.path);
      db.execute('PRAGMA user_version=11');
      db.execute('CREATE TABLE retained(value TEXT)');
      db.execute("INSERT INTO retained VALUES ('SYNTHETIC-RETAIN')");
      db.dispose();
      final before = await file.readAsBytes();
      await expectLater(local.open(identity), throwsStateError);
      expect(await file.readAsBytes(), before);
      expect(storage.reads, isEmpty);
      expect(storage.writes, isEmpty);
      expect(await root.list().length, 1);
    },
  );
  for (final suffix in [
    '.plaintext-backup',
    '.plaintext-backup-wal',
    '.plaintext-backup-shm',
    '.plaintext-backup-journal',
    '.encryption-candidate',
    '.encryption-candidate-wal',
    '.encryption-candidate-shm',
    '.encryption-candidate-journal',
  ]) {
    test(
      'migration artifact $suffix is preserved without reading keys',
      () async {
        final artifact = File('${identity.fileIn(root).path}$suffix');
        await artifact.writeAsString('SYNTHETIC-MIGRATION-ARTIFACT');
        await expectLater(local.open(identity), throwsStateError);
        expect(await artifact.readAsString(), 'SYNTHETIC-MIGRATION-ARTIFACT');
        expect(storage.reads, isEmpty);
        expect(storage.writes, isEmpty);
        expect(storage.deletes, isEmpty);
        expect(await identity.fileIn(root).exists(), false);
      },
    );
  }
  test(
    'encrypted profile with missing key never creates a replacement',
    () async {
      final db = await local.open(identity);
      await seedTask(db);
      await db.close();
      final file = identity.fileIn(root);
      final before = await file.readAsBytes();
      storage.values.clear();
      keys.clearAllCaches();
      storage.writes.clear();
      await expectLater(local.open(identity), throwsStateError);
      expect(await file.readAsBytes(), before);
      expect(storage.writes, isEmpty);
    },
  );
}
