import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/database_sync_policy.dart';
import 'package:life_os/core/database/local_database_identity.dart';
import 'package:life_os/core/database/local_mutation_gate.dart';
import 'package:life_os/core/database/remote_send_permit.dart';
import 'package:life_os/core/database/user_database_factory.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  const uid = 'local-v1-123e4567-e89b-42d3-a456-426614174000';
  final identity = LocalDatabaseIdentity(uid);
  AppDatabase memory({
    DatabaseSyncPolicy policy = DatabaseSyncPolicy.localOnly,
  }) {
    final db = AppDatabase.forUser(
      identity: identity,
      executor: NativeDatabase.memory(),
      syncPolicy: policy,
    );
    addTearDown(db.close);
    return db;
  }

  TaskTableCompanion task(String id) => TaskTableCompanion.insert(
    id: id,
    title: id,
    priority: 'medium',
    date: DateTime.utc(2026, 11, 17),
  );
  SyncQueueTableCompanion queued() => SyncQueueTableCompanion.insert(
    ownerUid: const Value(uid),
    collection: 'tasks',
    docId: 'historical',
    operationType: 'create',
    payloadJson: '{"synthetic":true}',
    createdAt: 123,
  );
  Future<void> save(AppDatabase db, {String owner = uid, bool fail = false}) =>
      db.transactionWithSync(
        localOperation: () async {
          await db.into(db.taskTable).insert(task('local-task'));
          if (fail) throw StateError('SYNTHETIC_FAILURE');
        },
        ownerUid: owner,
        collection: 'tasks',
        docId: 'local-task',
        operationType: 'create',
        payloadJson: '{"synthetic":true}',
      );
  Matcher queueBlocked() => throwsA(
    predicate(
      (Object? error) =>
          error.toString().contains(LocalRemoteSyncDisabled.code),
    ),
  );

  test(
    'local transaction commits the task without any queued upload',
    () async {
      final db = memory();
      await save(db);
      expect((await db.select(db.taskTable).get()).single.id, 'local-task');
      expect(await db.select(db.syncQueueTable).get(), isEmpty);
      expect(db.schemaVersion, 11);
    },
  );
  test(
    'local failure rolls back all writes without queue side effects',
    () async {
      final db = memory();
      await expectLater(save(db, fail: true), throwsStateError);
      expect(await db.select(db.taskTable).get(), isEmpty);
      expect(await db.select(db.syncQueueTable).get(), isEmpty);
    },
  );
  test(
    'different owner cannot write through the local transaction API',
    () async {
      final db = memory();
      await expectLater(
        save(db, owner: 'legacy-uid'),
        throwsA(isA<LocalMutationUnavailable>()),
      );
      expect(await db.select(db.taskTable).get(), isEmpty);
    },
  );
  test('local connection cannot grant remote permits', () {
    final db = memory();
    expect(
      () => db.localMutations.captureRemoteSend(expectedUid: uid),
      throwsA(isA<RemoteSessionStopped>()),
    );
  });
  test(
    'queue helper fails explicitly instead of silently discarding work',
    () async {
      final db = memory();
      await expectLater(
        db.insertSyncItem(
          ownerUid: uid,
          collection: 'tasks',
          docId: 'x',
          operationType: 'create',
          payloadJson: '{}',
        ),
        queueBlocked(),
      );
    },
  );
  test('direct DAO cannot enqueue around the helper guard', () async {
    final db = memory();
    await expectLater(
      db.into(db.syncQueueTable).insert(queued()),
      queueBlocked(),
    );
    expect(await db.select(db.syncQueueTable).get(), isEmpty);
  });
  test('raw SQL cannot enqueue around the DAO guard', () async {
    final db = memory();
    await expectLater(
      db.customStatement(
        'INSERT INTO sync_queue_table (collection,doc_id,operation_type,payload_json,created_at) '
        "VALUES ('tasks','x','create','{}',123)",
      ),
      queueBlocked(),
    );
  });
  test(
    'batch cannot partially commit a task before attempting queue insert',
    () async {
      final db = memory();
      await expectLater(
        db.batch((b) {
          b.insert(db.taskTable, task('batched-task'));
          b.insert(db.syncQueueTable, queued());
        }),
        queueBlocked(),
      );
      expect(await db.select(db.taskTable).get(), isEmpty);
      expect(await db.select(db.syncQueueTable).get(), isEmpty);
    },
  );
  test(
    'queue protections are TEMP and do not change the persisted schema',
    () async {
      final db = memory();
      expect(
        await db
            .customSelect("SELECT name FROM sqlite_master WHERE type='trigger'")
            .get(),
        isEmpty,
      );
      expect(
        await db
            .customSelect(
              "SELECT name FROM sqlite_temp_master WHERE type='trigger'",
            )
            .get(),
        hasLength(3),
      );
      expect(
        (await db.customSelect('PRAGMA user_version').getSingle()).read<int>(
          'user_version',
        ),
        11,
      );
    },
  );
  test(
    'explicit remote-enabled connection retains its previous behavior',
    () async {
      final db = memory(policy: DatabaseSyncPolicy.remoteEnabled);
      await save(db);
      expect(await db.select(db.taskTable).get(), hasLength(1));
      expect(await db.select(db.syncQueueTable).get(), hasLength(1));
      expect(
        db.localMutations.captureRemoteSend(expectedUid: uid).isCurrent,
        isTrue,
      );
    },
  );
  for (final candidate in [
    LocalDatabaseIdentity('firebase-uid'),
    LocalDatabaseIdentity(
      uid,
      generation: '00000000-0000-4000-8000-000000000001',
    ),
    LocalDatabaseIdentity.bound(
      projectId: 'synthetic',
      databaseId: '(default)',
      uid: uid,
      generation: '00000000-0000-4000-8000-000000000001',
    ),
  ]) {
    test(
      'factory rejects non-local address ${candidate.namespace} before IO',
      () async {
        var directoryCalls = 0;
        final factory = UserDatabaseFactory(
          syncPolicy: DatabaseSyncPolicy.localOnly,
          directoryProvider: () async {
            directoryCalls++;
            throw StateError('MUST_NOT_READ');
          },
        );
        await expectLater(factory.open(candidate), throwsArgumentError);
        expect(directoryCalls, 0);
      },
    );
  }
  test(
    'historical queue stays byte-equivalent and all queue mutations fail',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'lifeos-queue-policy-',
      );
      addTearDown(() => root.delete(recursive: true));
      final file = File('${root.path}/synthetic.sqlite');
      final seed = AppDatabase.forUser(
        identity: identity,
        executor: NativeDatabase(file),
      );
      await seed.into(seed.syncQueueTable).insert(queued());
      await seed.into(seed.taskTable).insert(task('preserved-task'));
      final original = (await seed.select(seed.syncQueueTable).get()).single;
      await seed.close();
      final db = AppDatabase.forUser(
        identity: identity,
        executor: NativeDatabase(file),
        syncPolicy: DatabaseSyncPolicy.localOnly,
      );
      try {
        await expectLater(
          db
              .update(db.syncQueueTable)
              .write(
                const SyncQueueTableCompanion(payloadJson: Value('changed')),
              ),
          queueBlocked(),
        );
        await expectLater(db.delete(db.syncQueueTable).go(), queueBlocked());
        await expectLater(db.clearAllData(), queueBlocked());
        expect((await db.select(db.syncQueueTable).get()).single, original);
        expect(
          (await db.select(db.taskTable).get()).single.id,
          'preserved-task',
        );
      } finally {
        await db.close();
      }
    },
  );
  test(
    'unqualified prior schema is refused without changing the source file',
    () async {
      final root = await Directory.systemTemp.createTemp('lifeos-old-schema-');
      addTearDown(() => root.delete(recursive: true));
      final file = File('${root.path}/synthetic.sqlite');
      final sql = sqlite.sqlite3.open(file.path);
      sql.execute('PRAGMA user_version=10');
      sql.dispose();
      final original = await file.readAsBytes();
      final db = AppDatabase.forUser(
        identity: identity,
        executor: NativeDatabase(file),
        syncPolicy: DatabaseSyncPolicy.localOnly,
      );
      try {
        await expectLater(
          db.customSelect('SELECT 1').get(),
          throwsA(
            predicate(
              (Object? error) => error.toString().contains(
                'LOCAL_PROFILE_SCHEMA_MIGRATION_REQUIRED',
              ),
            ),
          ),
        );
      } finally {
        await db.close();
      }
      expect(await file.readAsBytes(), original);
    },
  );
}
