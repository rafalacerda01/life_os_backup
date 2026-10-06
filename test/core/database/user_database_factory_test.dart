import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/database_encryption.dart';
import 'package:life_os/core/database/local_database_identity.dart';
import 'package:life_os/core/database/user_database_factory.dart';
import 'package:life_os/core/db/user_db_key_manager.dart';
import 'package:sqlite3/sqlite3.dart';

import '../db/fake_secure_storage.dart';

void main() {
  final a = LocalDatabaseIdentity('user-a');
  final b = LocalDatabaseIdentity('user-b');
  late Directory directory;
  late FakeSecureStorage storage;
  late UserDbKeyManager keys;
  late UserDatabaseFactory factory;
  final databases = <AppDatabase>[];

  Future<AppDatabase> open(LocalDatabaseIdentity identity) async {
    final db = await factory.open(identity);
    databases.add(db);
    return db;
  }

  Future<void> close(AppDatabase db) async {
    await db.closeDatabase();
    databases.remove(db);
  }

  Future<void> seed(AppDatabase db, String id) => db
      .into(db.taskTable)
      .insert(
        TaskTableCompanion.insert(
          id: id,
          title: id,
          priority: 'medium',
          date: DateTime.utc(2026, 10, 4),
        ),
      )
      .then((_) {});

  setUp(() {
    directory = Directory.systemTemp.createTempSync('life_os_user_database_');
    storage = FakeSecureStorage();
    keys = UserDbKeyManager(storage: storage);
    factory = UserDatabaseFactory(
      keyManager: keys,
      directoryProvider: () async => directory,
    );
  });

  tearDown(() async {
    for (final db in databases.toList()) {
      await close(db);
    }
    directory.deleteSync(recursive: true);
  });

  test(
    'missing A creates scoped key and encrypted schema v9 with current PRAGMAs',
    () async {
      final db = await open(a);
      expect(db.identity, a);
      await seed(db, 'task-a');
      expect(db.schemaVersion, 9);
      expect(db.allTables, hasLength(14));
      expect(
        (await db.customSelect('PRAGMA user_version').get())
            .single
            .data
            .values
            .single,
        9,
      );
      expect(
        (await db.customSelect('PRAGMA journal_mode').get())
            .single
            .data
            .values
            .single,
        'wal',
      );
      expect(
        (await db.customSelect('PRAGMA synchronous').get())
            .single
            .data
            .values
            .single,
        1,
      );
      expect(
        (await db.customSelect('PRAGMA foreign_keys').get())
            .single
            .data
            .values
            .single,
        1,
      );
      expect(storage.values.containsKey(a.keyAlias), isTrue);
      await close(db);
      expect(a.fileIn(directory).existsSync(), isTrue);
      expect(
        DatabaseEncryptionBootstrap.hasPlaintextHeader(a.fileIn(directory)),
        isFalse,
      );
      expect(File('${directory.path}/life_os.sqlite').existsSync(), isFalse);
    },
  );

  test(
    'close A then open B and reopen A preserves separate rows and keys',
    () async {
      final dbA = await open(a);
      await seed(dbA, 'task-a');
      final keyA = storage.values[a.keyAlias];
      await close(dbA);
      keys.clearCache(a);
      final dbB = await open(b);
      expect(await dbB.select(dbB.taskTable).get(), isEmpty);
      await seed(dbB, 'task-b');
      await close(dbB);
      keys.clearCache(b);
      final reopenedA = await open(a);
      expect(
        (await reopenedA.select(reopenedA.taskTable).get()).single.id,
        'task-a',
      );
      expect(storage.values[a.keyAlias], keyA);
      expect(storage.writes[a.keyAlias], 1);
      expect(storage.values[b.keyAlias], isNot(keyA));
      await close(reopenedA);
      final reopenedB = await open(b);
      expect(
        (await reopenedB.select(reopenedB.taskTable).get()).single.id,
        'task-b',
      );
    },
  );

  test(
    'existing encrypted A with missing key fails closed and leaves bytes intact',
    () async {
      final db = await open(a);
      await seed(db, 'task-a');
      await close(db);
      final before = a.fileIn(directory).readAsBytesSync();
      await keys.deleteKey(a);
      final writes = storage.writes[a.keyAlias];
      await expectLater(open(a), throwsStateError);
      expect(storage.values.containsKey(a.keyAlias), isFalse);
      expect(storage.writes[a.keyAlias], writes);
      expect(a.fileIn(directory).readAsBytesSync(), before);
    },
  );

  test('deleting scoped A key does not make B unreadable', () async {
    final dbA = await open(a);
    await seed(dbA, 'task-a');
    await close(dbA);
    final dbB = await open(b);
    await seed(dbB, 'task-b');
    await close(dbB);
    await keys.deleteKey(a);
    keys.clearCache(b);
    final reopenedB = await open(b);
    expect(
      (await reopenedB.select(reopenedB.taskTable).get()).single.id,
      'task-b',
    );
  });

  test(
    'existing plaintext scoped DB without key is not rekeyed or changed',
    () async {
      final file = a.fileIn(directory);
      final raw = sqlite3.open(file.path);
      raw.execute('CREATE TABLE preserved (value TEXT)');
      raw.execute("INSERT INTO preserved VALUES ('unowned')");
      raw.dispose();
      final before = file.readAsBytesSync();
      await expectLater(open(a), throwsStateError);
      expect(storage.writes, isEmpty);
      expect(file.readAsBytesSync(), before);
    },
  );

  test('scoped recovery artifact without key stays untouched', () async {
    final file = a.fileIn(directory);
    final backup = File('${file.path}.plaintext-backup');
    backup.writeAsStringSync('unresolved-recovery');
    await expectLater(open(a), throwsStateError);
    expect(storage.writes, isEmpty);
    expect(file.existsSync(), isFalse);
    expect(backup.readAsStringSync(), 'unresolved-recovery');
  });

  test('B rejects A key and cannot be read without encryption key', () async {
    final dbA = await open(a);
    await seed(dbA, 'task-a');
    await close(dbA);
    final dbB = await open(b);
    await seed(dbB, 'task-b');
    await close(dbB);
    final raw = sqlite3.open(b.fileIn(directory).path, mode: OpenMode.readOnly);
    try {
      expect(
        () => raw.select('SELECT * FROM task_table'),
        throwsA(isA<SqliteException>()),
      );
    } finally {
      raw.dispose();
    }
    final wrongKey = sqlite3.open(
      b.fileIn(directory).path,
      mode: OpenMode.readOnly,
    );
    try {
      DatabaseEncryptionBootstrap.configureEncryptedConnection(
        wrongKey,
        storage.values[a.keyAlias]!,
      );
      expect(
        () => wrongKey.select('SELECT * FROM task_table'),
        throwsA(isA<SqliteException>()),
      );
    } finally {
      wrongKey.dispose();
    }
  });

  test(
    'factory never opens copies deletes or consumes unowned legacy storage',
    () async {
      final legacy = File('${directory.path}/life_os.sqlite');
      final wal = File('${legacy.path}-wal');
      legacy.writeAsStringSync('unowned legacy bytes');
      wal.writeAsStringSync('unowned wal bytes');
      storage.values['db_encryption_key'] = 'legacy-key-preserved';
      final dbA = await open(a);
      expect(await dbA.select(dbA.taskTable).get(), isEmpty);
      await close(dbA);
      final dbB = await open(b);
      expect(await dbB.select(dbB.taskTable).get(), isEmpty);
      await close(dbB);
      expect(legacy.readAsStringSync(), 'unowned legacy bytes');
      expect(wal.readAsStringSync(), 'unowned wal bytes');
      expect(storage.values['db_encryption_key'], 'legacy-key-preserved');
      expect(storage.reads.containsKey('db_encryption_key'), isFalse);
      expect(storage.writes.containsKey('db_encryption_key'), isFalse);
      expect(storage.deletes.containsKey('db_encryption_key'), isFalse);
    },
  );

  test(
    'existing AppDatabase executor injection and schema remain compatible',
    () async {
      final db = AppDatabase(executor: NativeDatabase.memory());
      databases.add(db);
      expect(db.identity, isNull);
      expect(db.schemaVersion, 9);
      await seed(db, 'injected-task');
      expect((await db.select(db.taskTable).get()).single.id, 'injected-task');
      expect(directory.listSync(), isEmpty);
    },
  );

  for (final suffix in ['-wal', '-shm', '-journal']) {
    test(
      'orphan $suffix with persisted key fails closed without new main',
      () async {
        await keys.getEncryptionKey(a, allowCreate: true);
        final file = a.fileIn(directory);
        final sidecar = File('${file.path}$suffix')
          ..writeAsStringSync('orphan-bytes');
        await expectLater(open(a), throwsStateError);
        expect(file.existsSync(), isFalse);
        expect(sidecar.readAsStringSync(), 'orphan-bytes');
        expect(storage.writes[a.keyAlias], 1);
      },
    );
  }

  test('valid plaintext backup recovery stays supported', () async {
    await keys.getEncryptionKey(a, allowCreate: true);
    final backup = File('${a.fileIn(directory).path}.plaintext-backup');
    final raw = sqlite3.open(backup.path);
    raw.execute('CREATE TABLE preserved (value TEXT)');
    raw.execute("INSERT INTO preserved VALUES ('fixture')");
    raw.dispose();
    final db = await open(a);
    expect(
      (await db.customSelect('SELECT value FROM preserved').get())
          .single
          .data['value'],
      'fixture',
    );
    expect(backup.existsSync(), isFalse);
  });

  test(
    'candidate without source or backup retains fail-closed recovery',
    () async {
      await keys.getEncryptionKey(a, allowCreate: true);
      final file = a.fileIn(directory);
      final candidate = File('${file.path}.encryption-candidate')
        ..writeAsStringSync('unresolved');
      await expectLater(open(a), throwsStateError);
      expect(file.existsSync(), isFalse);
      expect(candidate.readAsStringSync(), 'unresolved');
    },
  );
}
