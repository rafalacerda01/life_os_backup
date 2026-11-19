import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/database_encryption.dart';
import 'package:life_os/core/database/database_sync_policy.dart';
import 'package:life_os/core/database/local_database_identity.dart';
import 'package:life_os/core/database/local_profile_bootstrap_journal.dart';
import 'package:life_os/core/database/user_database_factory.dart';
import 'package:life_os/core/db/user_db_key_manager.dart';
import 'package:sqlite3/sqlite3.dart' as sql;

import '../db/fake_secure_storage.dart';

void main() {
  final identity = LocalDatabaseIdentity(
    'local-v1-123e4567-e89b-42d3-a456-426614174000',
  );
  const journalKey = LocalProfileBootstrapJournal.storageKey;
  const nonce = '123e4567-e89b-42d3-a456-426614174001';
  late Directory directory;
  late FakeSecureStorage storage;
  late UserDbKeyManager keys;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('lifeos-schema-upgrade-');
    storage = FakeSecureStorage();
    keys = UserDbKeyManager(storage: storage);
    addTearDown(() => directory.delete(recursive: true));
  });

  UserDatabaseFactory factory(DatabaseSyncPolicy policy) => UserDatabaseFactory(
    keyManager: keys,
    directoryProvider: () async => directory,
    syncPolicy: policy,
  );

  Future<void> seedV11({
    bool writeJournal = true,
    bool conflict = false,
  }) async {
    final db = await factory(DatabaseSyncPolicy.remoteEnabled).open(identity);
    try {
      await db
          .into(db.taskTable)
          .insert(
            TaskTableCompanion.insert(
              id: 'retained-task',
              title: 'Tarefa anterior',
              priority: 'medium',
              date: DateTime.utc(2026, 11, 18),
            ),
          );
      await db
          .into(db.syncQueueTable)
          .insert(
            SyncQueueTableCompanion.insert(
              collection: 'tasks',
              docId: 'retained-task',
              operationType: 'create',
              payloadJson: '{"synthetic":true}',
              createdAt: 1,
            ),
          );
      expect(db.schemaVersion, 11);
      expect(db.allTables, hasLength(17));
      if (conflict) {
        await db.customStatement('CREATE TABLE market_items (old_data TEXT)');
        await db.customStatement(
          "INSERT INTO market_items VALUES ('retained')",
        );
      }
    } finally {
      await db.closeDatabase();
    }
    if (writeJournal) {
      storage.values[journalKey] = jsonEncode({
        'v': 1,
        'profile': identity.uid,
        'namespace': identity.namespace,
        'file': identity.fileName,
        'alias': identity.keyAlias,
        'schema': 11,
        'nonce': nonce,
        'phase': 'READY',
      });
    }
    keys.clearAllCaches();
  }

  T inspect<T>(T Function(sql.Database db) action) {
    final raw = sql.sqlite3.open(
      identity.fileIn(directory).path,
      mode: sql.OpenMode.readOnly,
    );
    try {
      DatabaseEncryptionBootstrap.configureEncryptedConnection(
        raw,
        storage.values[identity.keyAlias]!,
      );
      return action(raw);
    } finally {
      raw.dispose();
    }
  }

  test(
    'verified v11 upgrades once and preserves key, task and historical queue',
    () async {
      await seedV11();
      final key = storage.values[identity.keyAlias];
      final local = factory(DatabaseSyncPolicy.localOnly);
      final profiles = await Future.wait([
        local.open(identity),
        local.open(identity),
      ]);
      try {
        for (final db in profiles) {
          expect(db.schemaVersion, 12);
          expect(db.allTables, hasLength(19));
          expect(
            (await db.select(db.taskTable).get()).single.title,
            'Tarefa anterior',
          );
          expect(
            (await db.select(db.syncQueueTable).get()).single.docId,
            'retained-task',
          );
          expect(await db.select(db.marketItems).get(), isEmpty);
          expect(await db.select(db.marketPurchases).get(), isEmpty);
        }
      } finally {
        for (final db in profiles) {
          await db.closeDatabase();
        }
      }
      final file = identity.fileIn(directory);
      expect(DatabaseEncryptionBootstrap.hasPlaintextHeader(file), false);
      expect(inspect((db) => db.userVersion), 12);
      expect(
        inspect(
          (db) => db.select('PRAGMA integrity_check').single.values.single,
        ),
        'ok',
      );
      final journal =
          jsonDecode(storage.values[journalKey]!) as Map<String, dynamic>;
      expect(journal['schema'], 12);
      expect(journal['phase'], 'READY');
      expect(journal['nonce'], nonce);
      expect(storage.values[identity.keyAlias], key);
      expect(storage.writes[identity.keyAlias], 1);
      expect(storage.writes[journalKey], 1);
      expect(storage.deletes, isEmpty);
    },
  );

  test('reopen finalizes the journal after a committed upgrade', () async {
    await seedV11();
    final previousJournal = storage.values[journalKey];
    final local = factory(DatabaseSyncPolicy.localOnly);
    storage.discardWrites = true;
    await expectLater(local.open(identity), throwsA(isA<StateError>()));
    expect(inspect((db) => db.userVersion), 12);
    expect(storage.values[journalKey], previousJournal);
    final committed = await identity.fileIn(directory).readAsBytes();
    storage.discardWrites = false;
    final reopened = await local.open(identity);
    try {
      expect(
        (await reopened.select(reopened.taskTable).get()).single.title,
        'Tarefa anterior',
      );
      expect(await reopened.select(reopened.marketItems).get(), isEmpty);
    } finally {
      await reopened.closeDatabase();
    }
    expect(await identity.fileIn(directory).readAsBytes(), committed);
    expect(jsonDecode(storage.values[journalKey]!)['schema'], 12);
  });

  test(
    'v11 without journal is preserved and never admitted for upgrade',
    () async {
      await seedV11(writeJournal: false);
      final before = await identity.fileIn(directory).readAsBytes();
      final secureBefore = Map.of(storage.values);
      await expectLater(
        factory(DatabaseSyncPolicy.localOnly).open(identity),
        throwsStateError,
      );
      expect(await identity.fileIn(directory).readAsBytes(), before);
      expect(inspect((db) => db.userVersion), 11);
      expect(storage.values, secureBefore);
    },
  );

  test(
    'existing conflicting table does not become part of the new schema',
    () async {
      await seedV11(conflict: true);
      final before = await identity.fileIn(directory).readAsBytes();
      final secureBefore = Map.of(storage.values);
      await expectLater(
        factory(DatabaseSyncPolicy.localOnly).open(identity),
        throwsA(
          predicate(
            (Object? error) => error.toString().contains(
              'LOCAL_PROFILE_SCHEMA_MIGRATION_CONFLICT',
            ),
          ),
        ),
      );
      expect(inspect((db) => db.userVersion), 11);
      expect(
        inspect(
          (db) =>
              db.select('SELECT old_data FROM market_items').single['old_data'],
        ),
        'retained',
      );
      expect(await identity.fileIn(directory).readAsBytes(), before);
      expect(storage.values, secureBefore);
    },
  );
}
