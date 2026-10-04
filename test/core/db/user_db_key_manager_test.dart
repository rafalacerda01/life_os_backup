import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:life_os/core/database/local_database_identity.dart';
import 'package:life_os/core/db/db_key_manager.dart';
import 'package:life_os/core/db/user_db_key_manager.dart';

import 'fake_secure_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final a = LocalDatabaseIdentity('user-a');
  final b = LocalDatabaseIdentity('user-b');
  late FakeSecureStorage storage;
  late UserDbKeyManager manager;
  String key(int byte) => base64UrlEncode(List.filled(32, byte));

  setUp(() {
    storage = FakeSecureStorage();
    manager = UserDbKeyManager(storage: storage);
  });

  test(
    'generates distinct persisted 256-bit keys without touching legacy',
    () async {
      storage.values['db_encryption_key'] = 'legacy-preserved';
      final keyA = await manager.getEncryptionKey(a, allowCreate: true);
      final keyB = await manager.getEncryptionKey(b, allowCreate: true);
      expect(base64Url.decode(keyA).length, 32);
      expect(base64Url.decode(keyB).length, 32);
      expect(keyA, isNot(keyB));
      expect(storage.values[a.keyAlias], keyA);
      expect(storage.values[b.keyAlias], keyB);
      expect(storage.values['db_encryption_key'], 'legacy-preserved');
      expect(storage.reads.containsKey('db_encryption_key'), isFalse);
      expect(storage.writes.containsKey('db_encryption_key'), isFalse);
      expect(storage.deletes.containsKey('db_encryption_key'), isFalse);
    },
  );

  test(
    'concurrent same-identity loads generate and persist only one key',
    () async {
      final started = Completer<void>();
      final release = Completer<void>();
      storage.beforeRead = (alias) async {
        if (!started.isCompleted) {
          started.complete();
          await release.future;
        }
      };
      final first = manager.getEncryptionKey(a, allowCreate: true);
      await started.future;
      final others = List.generate(
        8,
        (_) => manager.getEncryptionKey(
          LocalDatabaseIdentity(' user-a '),
          allowCreate: true,
        ),
      );
      release.complete();
      final keys = await Future.wait([first, ...others]);
      expect(keys.toSet(), hasLength(1));
      expect(storage.writes[a.keyAlias], 1);
      expect(storage.reads[a.keyAlias], 2);
    },
  );

  test('an in-flight A load does not block B', () async {
    storage.values[a.keyAlias] = key(1);
    storage.values[b.keyAlias] = key(2);
    final started = Completer<void>();
    final release = Completer<void>();
    storage.beforeRead = (alias) async {
      if (alias == a.keyAlias) {
        started.complete();
        await release.future;
      }
    };
    final first = manager.getEncryptionKey(a, allowCreate: false);
    await started.future;
    expect(await manager.getEncryptionKey(b, allowCreate: false), key(2));
    release.complete();
    expect(await first, key(1));
  });

  test(
    'missing key with allowCreate false fails closed without writing',
    () async {
      await expectLater(
        manager.getEncryptionKey(a, allowCreate: false),
        throwsStateError,
      );
      expect(storage.writes, isEmpty);
      expect(storage.values, isEmpty);
    },
  );

  test(
    'invalid stored key fails closed even when creation is allowed',
    () async {
      storage.values[a.keyAlias] = 'corrupted';
      await expectLater(
        manager.getEncryptionKey(a, allowCreate: true),
        throwsStateError,
      );
      expect(storage.values[a.keyAlias], 'corrupted');
      expect(storage.writes, isEmpty);
    },
  );

  test('clearing A cache preserves B cache and both persisted keys', () async {
    storage.values[a.keyAlias] = key(1);
    storage.values[b.keyAlias] = key(2);
    await manager.getEncryptionKey(a, allowCreate: false);
    await manager.getEncryptionKey(b, allowCreate: false);
    manager.clearCache(a);
    expect(await manager.getEncryptionKey(a, allowCreate: false), key(1));
    expect(await manager.getEncryptionKey(b, allowCreate: false), key(2));
    expect(storage.reads[a.keyAlias], 2);
    expect(storage.reads[b.keyAlias], 1);
    expect(storage.deletes, isEmpty);
  });

  test(
    'explicit clearAllCaches reloads without removing stored keys',
    () async {
      storage.values[a.keyAlias] = key(1);
      storage.values[b.keyAlias] = key(2);
      await manager.getEncryptionKey(a, allowCreate: false);
      await manager.getEncryptionKey(b, allowCreate: false);
      manager.clearAllCaches();
      await manager.getEncryptionKey(a, allowCreate: false);
      await manager.getEncryptionKey(b, allowCreate: false);
      expect(storage.reads[a.keyAlias], 2);
      expect(storage.reads[b.keyAlias], 2);
      expect(storage.values, hasLength(2));
    },
  );

  test('delete A removes only A key and invalidates its cache', () async {
    storage.values.addAll({
      a.keyAlias: key(1),
      b.keyAlias: key(2),
      'db_encryption_key': 'legacy-preserved',
    });
    await manager.getEncryptionKey(a, allowCreate: false);
    await manager.getEncryptionKey(b, allowCreate: false);
    await manager.deleteKey(a);
    await expectLater(
      manager.getEncryptionKey(a, allowCreate: false),
      throwsStateError,
    );
    expect(await manager.getEncryptionKey(b, allowCreate: false), key(2));
    expect(storage.deletes, {a.keyAlias: 1});
    expect(storage.values['db_encryption_key'], 'legacy-preserved');
  });

  test(
    'cache clearing during a load does not repopulate stale cache',
    () async {
      storage.values[a.keyAlias] = key(1);
      final started = Completer<void>();
      final release = Completer<void>();
      storage.beforeRead = (_) async {
        started.complete();
        await release.future;
      };
      final first = manager.getEncryptionKey(a, allowCreate: false);
      await started.future;
      manager.clearCache(a);
      release.complete();
      expect(await first, key(1));
      storage.beforeRead = null;
      storage.values[a.keyAlias] = key(2);
      expect(await manager.getEncryptionKey(a, allowCreate: false), key(2));
    },
  );

  test('delete waits for an in-flight load and leaves no cached key', () async {
    storage.values[a.keyAlias] = key(1);
    final started = Completer<void>();
    final release = Completer<void>();
    storage.beforeRead = (_) async {
      if (!started.isCompleted) {
        started.complete();
        await release.future;
      }
    };
    final load = manager.getEncryptionKey(a, allowCreate: false);
    await started.future;
    final deletion = manager.deleteKey(a);
    release.complete();
    await load;
    await deletion;
    expect(storage.values.containsKey(a.keyAlias), isFalse);
    await expectLater(
      manager.getEncryptionKey(a, allowCreate: false),
      throwsStateError,
    );
  });

  test('failed persistence is not cached as a usable key', () async {
    storage.discardWrites = true;
    await expectLater(
      manager.getEncryptionKey(a, allowCreate: true),
      throwsStateError,
    );
    await expectLater(
      manager.getEncryptionKey(a, allowCreate: false),
      throwsStateError,
    );
    expect(storage.values, isEmpty);
  });

  test('unconfirmed deletion fails closed', () async {
    storage.values[a.keyAlias] = key(1);
    storage.discardDeletes = true;
    await expectLater(manager.deleteKey(a), throwsStateError);
    expect(storage.values[a.keyAlias], key(1));
  });

  test('storage IO failure is sanitized and cannot create a key', () async {
    storage.failRead = true;
    await expectLater(
      manager.getEncryptionKey(a, allowCreate: true),
      throwsA(
        isA<StateError>().having(
          (error) => error.toString(),
          'sanitized',
          isNot(contains('technical-storage-marker')),
        ),
      ),
    );
    expect(storage.writes, isEmpty);
  });

  test(
    'legacy DbKeyManager API stays readable after scoped creation and deletion',
    () async {
      FlutterSecureStorage.setMockInitialValues({'db_encryption_key': key(1)});
      DbKeyManager.clearCache();
      addTearDown(DbKeyManager.clearCache);
      final scoped = UserDbKeyManager();
      final keyA = await scoped.getEncryptionKey(a, allowCreate: true);
      final keyB = await scoped.getEncryptionKey(b, allowCreate: true);
      expect(keyA, isNot(key(1)));
      expect(keyB, isNot(key(1)));
      expect(await DbKeyManager.getEncryptionKey(allowCreate: false), key(1));
      await scoped.deleteKey(a);
      DbKeyManager.clearCache();
      expect(await DbKeyManager.getEncryptionKey(allowCreate: false), key(1));
      expect(await scoped.getEncryptionKey(b, allowCreate: false), keyB);
    },
  );
}
