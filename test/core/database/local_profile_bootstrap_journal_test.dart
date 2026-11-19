import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/database_encryption.dart';
import 'package:life_os/core/database/database_sync_policy.dart';
import 'package:life_os/core/database/local_database_identity.dart';
import 'package:life_os/core/database/local_profile_admission.dart';
import 'package:life_os/core/database/local_profile_bootstrap_journal.dart';
import 'package:life_os/core/database/user_database_factory.dart';
import 'package:life_os/core/db/user_db_key_manager.dart';
import 'package:sqlite3/sqlite3.dart' as sql;

import '../db/fake_secure_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final identity = LocalDatabaseIdentity(
    'local-v1-123e4567-e89b-42d3-a456-426614174000',
  );
  late Directory root;
  late FakeSecureStorage storage;
  late UserDbKeyManager keys;
  const schema = AppDatabase.currentLocalSchemaVersion;
  const journalKey = LocalProfileBootstrapJournal.storageKey;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('local-bootstrap-journal-');
    storage = FakeSecureStorage();
    keys = UserDbKeyManager(storage: storage);
  });
  tearDown(() async => root.delete(recursive: true));
  UserDatabaseFactory factory() => UserDatabaseFactory(
    keyManager: keys,
    directoryProvider: () async => root,
    syncPolicy: DatabaseSyncPolicy.localOnly,
  );

  Future<void> interrupt({
    bool createFile = false,
    bool addTable = false,
  }) async {
    await expectLater(
      LocalProfileAdmission(root).run(
        () => LocalProfileBootstrapJournal(storage).run<void>(
          identity: identity,
          databaseFile: identity.fileIn(root),
          schemaVersion: schema,
          open: (permit) async {
            if (createFile) {
              await DatabaseEncryptionBootstrap().prepareLocalProfile(
                databaseFile: identity.fileIn(root),
                expectedSchemaVersion: schema,
                keyProvider: ({required allowCreate}) =>
                    keys.getEncryptionKey(identity, allowCreate: allowCreate),
                creationPermit: permit,
              );
              if (addTable) {
                final db = sql.sqlite3.open(identity.fileIn(root).path);
                final key = await keys.getEncryptionKey(
                  identity,
                  allowCreate: false,
                );
                DatabaseEncryptionBootstrap.configureEncryptedConnection(
                  db,
                  key,
                );
                db.execute('CREATE TABLE sentinel (payload TEXT)');
                db.execute(
                  "INSERT INTO sentinel VALUES ('synthetic-preserve')",
                );
                db.dispose();
              }
            }
            throw StateError('synthetic-crash');
          },
          closeOnFailure: (_) async {},
        ),
      ),
      throwsStateError,
    );
  }

  test('fresh schema and journal are ready before factory returns', () async {
    final db = await factory().open(identity);
    try {
      expect(jsonDecode(storage.values[journalKey]!)['phase'], 'READY');
      expect(
        (await db.customSelect('PRAGMA user_version').getSingle())
            .data
            .values
            .single,
        schema,
      );
      expect(
        DatabaseEncryptionBootstrap.hasPlaintextHeader(identity.fileIn(root)),
        false,
      );
    } finally {
      await db.closeDatabase();
    }
  });

  test('recovers interruption before key or file creation', () async {
    await interrupt();
    expect(storage.values.keys, [journalKey]);
    expect(jsonDecode(storage.values[journalKey]!)['phase'], 'CREATING');
    final db = await factory().open(identity);
    await db.closeDatabase();
    expect(jsonDecode(storage.values[journalKey]!)['phase'], 'READY');
  });

  test(
    'recovers owned encrypted empty schema zero preserving original key',
    () async {
      await interrupt(createFile: true);
      final key = storage.values[identity.keyAlias];
      keys.clearAllCaches();
      final db = await factory().open(identity);
      await db.closeDatabase();
      expect(storage.values[identity.keyAlias], key);
      expect(storage.writes[identity.keyAlias], 1);
      expect(jsonDecode(storage.values[journalKey]!)['phase'], 'READY');
      expect(storage.deletes, isEmpty);
    },
  );

  test(
    'schema zero with content is refused even with a creating journal',
    () async {
      await interrupt(createFile: true, addTable: true);
      final before = await identity.fileIn(root).readAsBytes();
      final material = Map.of(storage.values);
      await expectLater(factory().open(identity), throwsStateError);
      expect(await identity.fileIn(root).readAsBytes(), before);
      expect(storage.values, material);
      expect(storage.deletes, isEmpty);
    },
  );

  test('schema zero without journal cannot be adopted', () async {
    await DatabaseEncryptionBootstrap().prepareLocalProfile(
      databaseFile: identity.fileIn(root),
      expectedSchemaVersion: schema,
      keyProvider: ({required allowCreate}) =>
          keys.getEncryptionKey(identity, allowCreate: allowCreate),
    );
    final before = await identity.fileIn(root).readAsBytes();
    await expectLater(factory().open(identity), throwsStateError);
    expect(await identity.fileIn(root).readAsBytes(), before);
    expect(storage.values.containsKey(journalKey), false);
  });

  test(
    'ready journal with missing database cannot silently recreate it',
    () async {
      final db = await factory().open(identity);
      await db.closeDatabase();
      // Synthetic fault injection only; production never deletes this file.
      await identity.fileIn(root).delete();
      final material = Map.of(storage.values);
      await expectLater(factory().open(identity), throwsStateError);
      expect(await identity.fileIn(root).exists(), false);
      expect(storage.values, material);
    },
  );

  test('key without file or journal refuses new empty database', () async {
    await keys.getEncryptionKey(identity, allowCreate: true);
    final material = Map.of(storage.values);
    await expectLater(factory().open(identity), throwsStateError);
    expect(await identity.fileIn(root).exists(), false);
    expect(storage.values, material);
  });

  for (final value in ['not-json', '{}', '{"v":2}', 'null']) {
    test('malformed journal is preserved: $value', () async {
      storage.values[journalKey] = value;
      await expectLater(factory().open(identity), throwsStateError);
      expect(storage.values, {journalKey: value});
      expect(await identity.fileIn(root).exists(), false);
    });
  }

  test('journal profile substitution refuses before file/key writes', () async {
    await interrupt();
    final record =
        jsonDecode(storage.values[journalKey]!) as Map<String, dynamic>;
    record['profile'] = 'local-v1-123e4567-e89b-42d3-a456-426614174001';
    storage.values[journalKey] = jsonEncode(record);
    final material = Map.of(storage.values);
    await expectLater(factory().open(identity), throwsStateError);
    expect(storage.values, material);
    expect(await identity.fileIn(root).exists(), false);
  });

  test('journal persistence failure cannot create key or file', () async {
    storage.discardWrites = true;
    await expectLater(factory().open(identity), throwsStateError);
    expect(await identity.fileIn(root).exists(), false);
    expect(storage.values, isEmpty);
  });

  test(
    'creating journal recovers schema committed before ready marker',
    () async {
      final db = await factory().open(identity);
      await db
          .into(db.taskTable)
          .insert(
            TaskTableCompanion.insert(
              id: 'owned',
              title: 'synthetic-preserved',
              priority: 'medium',
              date: DateTime.utc(2026),
            ),
          );
      await db.closeDatabase();
      final key = storage.values[identity.keyAlias];
      final record =
          jsonDecode(storage.values[journalKey]!) as Map<String, dynamic>;
      record['phase'] = 'CREATING';
      storage.values[journalKey] = jsonEncode(record);
      final reopened = await factory().open(identity);
      try {
        expect(
          (await reopened.select(reopened.taskTable).get()).single.title,
          'synthetic-preserved',
        );
        expect(storage.values[identity.keyAlias], key);
        expect(jsonDecode(storage.values[journalKey]!)['phase'], 'READY');
      } finally {
        await reopened.closeDatabase();
      }
    },
  );

  test(
    'dropped tables leave free pages and cannot qualify as new empty schema',
    () async {
      await interrupt(createFile: true, addTable: true);
      final raw = sql.sqlite3.open(identity.fileIn(root).path);
      final key = await keys.getEncryptionKey(identity, allowCreate: false);
      try {
        DatabaseEncryptionBootstrap.configureEncryptedConnection(raw, key);
        raw.execute('DROP TABLE sentinel');
        expect(raw.select('SELECT name FROM sqlite_master'), isEmpty);
        expect(
          raw.select('PRAGMA freelist_count').single.values.single as int,
          greaterThan(0),
        );
      } finally {
        raw.dispose();
      }
      final before = await identity.fileIn(root).readAsBytes();
      await expectLater(factory().open(identity), throwsStateError);
      expect(await identity.fileIn(root).readAsBytes(), before);
    },
  );

  test(
    'expired creation permit cannot authorize another file or later work',
    () async {
      late LocalProfileOpenPermit captured;
      await expectLater(
        LocalProfileAdmission(root).run(
          () => LocalProfileBootstrapJournal(storage).run<void>(
            identity: identity,
            databaseFile: identity.fileIn(root),
            schemaVersion: schema,
            open: (permit) async {
              captured = permit!;
              expect(captured.permits(identity.fileIn(root), schema), true);
              expect(
                captured.permits(File('${root.path}/other.sqlite'), schema),
                false,
              );
              expect(
                captured.permits(identity.fileIn(root), schema + 1),
                false,
              );
              throw StateError('synthetic-crash');
            },
            closeOnFailure: (_) async {},
          ),
        ),
        throwsStateError,
      );
      expect(captured.permits(identity.fileIn(root), schema), false);
      await LocalProfileAdmission(root).run(() async {
        expect(captured.permits(identity.fileIn(root), schema), false);
      });
    },
  );

  test(
    'ready marker failure closes candidate and retains creating record',
    () async {
      var closed = false;
      await expectLater(
        LocalProfileAdmission(root).run(
          () => LocalProfileBootstrapJournal(storage).run<int>(
            identity: identity,
            databaseFile: identity.fileIn(root),
            schemaVersion: schema,
            open: (_) async {
              storage.discardWrites = true;
              return 7;
            },
            closeOnFailure: (value) async {
              expect(value, 7);
              closed = true;
            },
          ),
        ),
        throwsStateError,
      );
      expect(closed, true);
      expect(jsonDecode(storage.values[journalKey]!)['phase'], 'CREATING');
    },
  );

  test(
    'ready reopen is read-only for journal and preserves key material',
    () async {
      final db = await factory().open(identity);
      await db.closeDatabase();
      final writes = Map.of(storage.writes);
      final material = Map.of(storage.values);
      final reopened = await factory().open(identity);
      await reopened.closeDatabase();
      expect(storage.writes, writes);
      expect(storage.values, material);
    },
  );
}
