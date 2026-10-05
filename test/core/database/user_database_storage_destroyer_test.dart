import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/local_database_identity.dart';
import 'package:life_os/core/database/session_database_coordinator.dart';
import 'package:life_os/core/database/user_database_factory.dart';
import 'package:life_os/core/database/user_database_storage_destroyer.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/db/user_db_key_manager.dart';

import '../db/fake_secure_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final a = LocalDatabaseIdentity('a');
  final b = LocalDatabaseIdentity('b');
  late Directory directory;
  late FakeSecureStorage storage;
  late UserDbKeyManager keys;
  late UserDatabaseStorageDestroyer destroyer;

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('account_destroy_');
    storage = FakeSecureStorage();
    keys = UserDbKeyManager(storage: storage);
    await keys.getEncryptionKey(a, allowCreate: true);
    await keys.getEncryptionKey(b, allowCreate: true);
    storage.values['db_encryption_key'] = 'unowned';
    destroyer = UserDatabaseStorageDestroyer(
      directoryProvider: () async => directory,
      keyManager: keys,
    );
  });
  tearDown(() => directory.deleteSync(recursive: true));

  for (final artifact in ['', '.encryption-candidate', '.plaintext-backup']) {
    for (final suffix in ['', '-wal', '-shm', '-journal']) {
      test(
        'removes exact A artifact $artifact$suffix and preserves B and legacy',
        () async {
          final target = File('${a.fileIn(directory).path}$artifact$suffix')
            ..writeAsStringSync('A');
          final other = File('${b.fileIn(directory).path}$artifact$suffix')
            ..writeAsStringSync('B');
          final legacy = File(
            '${directory.path}/life_os.sqlite$artifact$suffix',
          )..writeAsStringSync('legacy');
          final keyB = storage.values[b.keyAlias];
          await destroyer.destroy(a);
          expect(target.existsSync(), isFalse);
          expect(other.readAsStringSync(), 'B');
          expect(legacy.readAsStringSync(), 'legacy');
          expect(storage.values.containsKey(a.keyAlias), isFalse);
          expect(storage.values[b.keyAlias], keyB);
          expect(storage.values['db_encryption_key'], 'unowned');
          expect(storage.deletes.keys, [a.keyAlias]);
        },
      );
    }
  }

  test('deletes all 12 files before deleting the key', () async {
    final files = UserDatabaseStorageDestroyer.artifacts(a, directory);
    for (final file in files) {
      file.writeAsStringSync('A');
    }
    final deleted = <String>[];
    destroyer = UserDatabaseStorageDestroyer(
      directoryProvider: () async => directory,
      keyManager: keys,
      deleteFile: (file) async {
        expect(storage.values.containsKey(a.keyAlias), isTrue);
        deleted.add(file.path);
        await file.delete();
      },
    );
    await destroyer.destroy(a);
    expect(deleted, files.map((file) => file.path).toList());
    expect(files.every((file) => !file.existsSync()), isTrue);
    expect(storage.values.containsKey(a.keyAlias), isFalse);
  });

  test(
    'partial WAL deletion failure retains key and retry removes every artifact',
    () async {
      for (final file in UserDatabaseStorageDestroyer.artifacts(a, directory)) {
        file.writeAsStringSync('A');
      }
      var fail = true;
      destroyer = UserDatabaseStorageDestroyer(
        directoryProvider: () async => directory,
        keyManager: keys,
        deleteFile: (file) async {
          if (fail && file.path.endsWith('.sqlite-wal'))
            throw StateError('fixture');
          if (file.existsSync()) await file.delete();
        },
      );
      final oldKey = storage.values[a.keyAlias];
      await expectLater(destroyer.destroy(a), throwsStateError);
      expect(a.fileIn(directory).existsSync(), isFalse);
      expect(File('${a.fileIn(directory).path}-wal').existsSync(), isTrue);
      expect(storage.values[a.keyAlias], oldKey);
      expect(storage.deletes, isEmpty);
      fail = false;
      await destroyer.destroy(a);
      expect(
        UserDatabaseStorageDestroyer.artifacts(
          a,
          directory,
        ).any((file) => file.existsSync()),
        isFalse,
      );
      expect(storage.values.containsKey(a.keyAlias), isFalse);
    },
  );

  test('unconfirmed file removal does not remove key', () async {
    a.fileIn(directory).writeAsStringSync('A');
    destroyer = UserDatabaseStorageDestroyer(
      directoryProvider: () async => directory,
      keyManager: keys,
      deleteFile: (_) async {},
    );
    await expectLater(destroyer.destroy(a), throwsStateError);
    expect(storage.values.containsKey(a.keyAlias), isTrue);
    expect(storage.deletes, isEmpty);
  });

  test(
    'key failure after files supports retry without opening or generating a key',
    () async {
      a.fileIn(directory).writeAsStringSync('A');
      storage.discardDeletes = true;
      final writes = Map<String, int>.of(storage.writes);
      await expectLater(destroyer.destroy(a), throwsStateError);
      expect(a.fileIn(directory).existsSync(), isFalse);
      expect(storage.values.containsKey(a.keyAlias), isTrue);
      storage.discardDeletes = false;
      await destroyer.destroy(a);
      await destroyer.destroy(a);
      expect(storage.values.containsKey(a.keyAlias), isFalse);
      expect(storage.writes, writes);
      expect(a.fileIn(directory).existsSync(), isFalse);
      await expectLater(
        keys.getEncryptionKey(a, allowCreate: true),
        throwsStateError,
      );
    },
  );

  test(
    'unexpected directory artifact fails closed without recursive deletion',
    () async {
      Directory(a.fileIn(directory).path).createSync();
      await expectLater(destroyer.destroy(a), throwsStateError);
      expect(storage.deletes, isEmpty);
    },
  );

  test(
    'coordinator drains A, awaits close and rejects stale and new A admission',
    () async {
      String? uid = 'a';
      final factory = UserDatabaseFactory(
        directoryProvider: () async => directory,
        keyManager: keys,
      );
      final coordinator = SessionDatabaseCoordinator(
        currentUserId: () => uid,
        openDatabase: factory.open,
        clearKeyCache: keys.clearCache,
      );
      addTearDown(coordinator.dispose);
      final db = await coordinator.prepare('a');
      final ticket = db.localMutations.capture();
      final started = Completer<void>();
      final release = Completer<void>();
      final mutation = db.localMutations.run(() async {
        started.complete();
        await release.future;
      });
      await started.future;
      var physicalStarted = false;
      final deletion = coordinator.destroy(a, () async {
        physicalStarted = true;
        expect(coordinator.attachedDatabase, isNull);
        await destroyer.destroy(a);
      });
      expect(physicalStarted, isFalse);
      final rejectedOpen = expectLater(
        coordinator.prepare('a'),
        throwsA(isA<SessionDatabaseUnavailable>()),
      );
      release.complete();
      await mutation;
      await deletion;
      await rejectedOpen;
      await expectLater(
        db.localMutations.run(() async => fail('stale'), ticket: ticket),
        throwsA(anything),
      );
      expect(physicalStarted, isTrue);
      expect(a.fileIn(directory).existsSync(), isFalse);
      expect(storage.writes[a.keyAlias], 1);
      uid = null;
    },
  );

  test(
    'destroy A with encrypted B prepared preserves B file key rows and publication',
    () async {
      String? uid = 'a';
      final factory = UserDatabaseFactory(
        directoryProvider: () async => directory,
        keyManager: keys,
      );
      final coordinator = SessionDatabaseCoordinator(
        currentUserId: () => uid,
        openDatabase: factory.open,
        clearKeyCache: keys.clearCache,
      );
      addTearDown(coordinator.dispose);
      final dbA = await coordinator.prepare('a');
      await dbA
          .into(dbA.taskTable)
          .insert(
            TaskTableCompanion.insert(
              id: 'A',
              title: 'A',
              priority: 'normal',
              date: DateTime(2026),
            ),
          );
      uid = 'b';
      final dbB = await coordinator.prepare('b');
      await dbB
          .into(dbB.taskTable)
          .insert(
            TaskTableCompanion.insert(
              id: 'B',
              title: 'B',
              priority: 'normal',
              date: DateTime(2026),
            ),
          );
      final keyB = storage.values[b.keyAlias];
      await coordinator.destroy(a, () => destroyer.destroy(a));
      expect(coordinator.requirePrepared(), same(dbB));
      expect((await dbB.select(dbB.taskTable).get()).single.id, 'B');
      expect(b.fileIn(directory).existsSync(), isTrue);
      expect(storage.values[b.keyAlias], keyB);
      expect(storage.deletes, {a.keyAlias: 1});
    },
  );

  test(
    'new storage fixture reusing UID gets a clean database and a different key',
    () async {
      final oldKey = storage.values[a.keyAlias];
      var factory = UserDatabaseFactory(
        directoryProvider: () async => directory,
        keyManager: keys,
      );
      var db = await factory.open(a);
      await db
          .into(db.taskTable)
          .insert(
            TaskTableCompanion.insert(
              id: 'old',
              title: 'old',
              priority: 'normal',
              date: DateTime(2026),
            ),
          );
      await db.closeDatabase();
      await destroyer.destroy(a);
      keys = UserDbKeyManager(storage: storage);
      factory = UserDatabaseFactory(
        directoryProvider: () async => directory,
        keyManager: keys,
      );
      db = await factory.open(a);
      try {
        expect(await db.select(db.taskTable).get(), isEmpty);
        expect(storage.values[a.keyAlias], isNot(oldKey));
      } finally {
        await db.closeDatabase();
      }
    },
  );
}
