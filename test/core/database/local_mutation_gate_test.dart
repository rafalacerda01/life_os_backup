import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/local_mutation_gate.dart';
import 'package:life_os/core/services/sync_manager.dart';
import 'package:life_os/core/services/sync_operation_result.dart';
import 'package:life_os/core/services/sync_queue_store.dart';
import 'package:life_os/core/services/sync_remote_data_source.dart';
import 'package:life_os/features/notifications/data/daos/notification_dao.dart';
import 'package:life_os/features/health/services/cycle_reminder_mutation_gate.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

class _Remote extends Fake implements SyncRemoteDataSource {
  SyncOperationResult result = const SyncOperationResult.success();
  int calls = 0;

  @override
  Future<SyncOperationResult> process(
    String uid,
    SyncQueueTableData item,
  ) async {
    calls++;
    return result;
  }
}

void main() {
  test(
    'scoped read result is rejected if owner changes while SQL is pending',
    () async {
      String? currentUid = 'a';
      final gate = LocalMutationGate(ownerUid: 'a');
      gate.bindSessionReader(() => currentUid);
      final release = Completer<String>();
      final read = gate.read(() => release.future);
      final rejected = expectLater(
        read,
        throwsA(isA<LocalMutationUnavailable>()),
      );
      currentUid = 'b';
      release.complete('private A result');
      await rejected;
    },
  );

  test(
    'definitive detach rejects scoped reads and never reopens old gate',
    () async {
      final gate = LocalMutationGate(ownerUid: 'a');
      gate.bindSessionReader(() => 'a');
      gate.openPreparedSession();
      await gate.sealAndDrainForDetach();
      await expectLater(
        gate.read(() async => 'private'),
        throwsA(isA<LocalMutationUnavailable>()),
      );
      expect(
        gate.openPreparedSession,
        throwsA(isA<LocalMutationUnavailable>()),
      );
    },
  );

  late AppDatabase db;
  late String? uid;

  setUp(() async {
    uid = 'user-a';
    db = AppDatabase(executor: NativeDatabase.memory());
    db.localMutations.bindSessionReader(() => uid);
    db.localMutations.openPreparedSession(
      admission: db.localMutations.capture(expectedUid: uid),
    );
    await db.customSelect('SELECT 1').get();
  });
  tearDown(() => db.close());

  Future<void> write(String id, {Future<void> Function()? beforeEnqueue}) =>
      db.transactionWithSync(
        ownerUid: uid!,
        collection: 'tasks',
        docId: id,
        operationType: 'create',
        payloadJson: '{}',
        localOperation: () async {
          await db
              .into(db.taskTable)
              .insert(
                TaskTableCompanion.insert(
                  id: id,
                  title: 'Task',
                  priority: 'normal',
                  date: DateTime.utc(2026, 10, 2),
                ),
              );
          await beforeEnqueue?.call();
        },
      );

  Future<void> coldWrite(AppDatabase cold, {LocalMutationTicket? admission}) =>
      cold.transactionWithSync(
        ownerUid: 'user-a',
        collection: 'tasks',
        docId: 'cold-task',
        operationType: 'create',
        payloadJson: '{}',
        admission: admission,
        localOperation: () => cold
            .into(cold.taskTable)
            .insert(
              TaskTableCompanion.insert(
                id: 'cold-task',
                title: 'Task',
                priority: 'normal',
                date: DateTime.utc(2026, 10, 2),
              ),
            ),
      );

  test(
    'first authenticated bind seals writes but allows lazy schema creation',
    () async {
      final cold = AppDatabase(executor: NativeDatabase.memory());
      addTearDown(cold.close);
      cold.localMutations.bindSessionReader(() => 'user-a');
      await expectLater(
        coldWrite(cold),
        throwsA(isA<LocalMutationUnavailable>()),
      );
      // Reads initialize Drift internally without granting a domain lease.
      expect(await cold.select(cold.taskTable).get(), isEmpty);
      expect(await cold.select(cold.syncQueueTable).get(), isEmpty);
      expect(
        (await cold.customSelect('PRAGMA user_version').get()).single.read<int>(
          'user_version',
        ),
        8,
      );
      await expectLater(
        cold
            .into(cold.taskTable)
            .insert(
              TaskTableCompanion.insert(
                id: 'raw-before-preparation',
                title: 'Task',
                priority: 'normal',
                date: DateTime.utc(2026, 10, 2),
              ),
            ),
        throwsA(isA<LocalMutationUnavailable>()),
      );
      final preparation = cold.localMutations.capture(expectedUid: 'user-a');
      cold.localMutations.openPreparedSession(admission: preparation);
      await coldWrite(cold);
      expect(await cold.select(cold.taskTable).get(), hasLength(1));
      expect(await cold.getPendingSyncItems('user-a'), hasLength(1));
    },
  );

  test(
    'first bind invalidates pre-bind ticket even with matching UID',
    () async {
      final cold = AppDatabase(executor: NativeDatabase.memory());
      addTearDown(cold.close);
      final old = cold.localMutations.capture(expectedUid: 'user-a');
      cold.localMutations.bindSessionReader(() => 'user-a');
      final preparation = cold.localMutations.capture(expectedUid: 'user-a');
      cold.localMutations.openPreparedSession(admission: preparation);
      await expectLater(
        coldWrite(cold, admission: old),
        throwsA(isA<LocalMutationUnavailable>()),
      );
      expect(await cold.select(cold.taskTable).get(), isEmpty);
      expect(await cold.select(cold.syncQueueTable).get(), isEmpty);
      await coldWrite(cold, admission: preparation);
      expect(await cold.getPendingSyncItems('user-a'), hasLength(1));
    },
  );

  test(
    'first null bind denies derived writes until later login is prepared',
    () async {
      final cold = AppDatabase(executor: NativeDatabase.memory());
      addTearDown(cold.close);
      String? currentUid;
      cold.localMutations.bindSessionReader(() => currentUid);
      final dao = NotificationDao(cold);
      final incoming = NotificationsTableCompanion.insert(
        id: 'cold-exam',
        title: 'Exam',
        description: 'Reminder',
        priority: 'normal',
        moduleType: 'studies',
        route: '/study',
        createdAt: DateTime.utc(2026, 10, 2),
      );
      await expectLater(
        dao.upsertPreservingState(incoming),
        throwsA(isA<LocalMutationUnavailable>()),
      );
      expect(await dao.getAllNotifications(), isEmpty);
      final signedOutTicket = cold.localMutations.capture();
      currentUid = 'user-a';
      cold.localMutations.observeSession(currentUid);
      await expectLater(
        coldWrite(cold),
        throwsA(isA<LocalMutationUnavailable>()),
      );
      final preparation = cold.localMutations.capture(expectedUid: currentUid);
      cold.localMutations.openPreparedSession(admission: preparation);
      await expectLater(
        cold.localMutations.run(() => coldWrite(cold), ticket: signedOutTicket),
        throwsA(isA<LocalMutationUnavailable>()),
      );
      await coldWrite(cold);
      expect(await cold.getPendingSyncItems('user-a'), hasLength(1));
    },
  );

  test(
    'v7 migration runs internally while first-bound session remains sealed',
    () async {
      final raw = sqlite3.sqlite3.openInMemory();
      raw.execute('''
      CREATE TABLE sync_queue_table (
        id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
        collection TEXT NOT NULL,
        doc_id TEXT NOT NULL,
        operation_type TEXT NOT NULL,
        payload_json TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        is_synced INTEGER NOT NULL DEFAULT 0
      )
    ''');
      raw.execute(
        "INSERT INTO sync_queue_table (collection, doc_id, operation_type, payload_json, created_at, is_synced) VALUES ('tasks', 'legacy', 'create', '{}', 1, 1)",
      );
      raw.execute('PRAGMA user_version = 7');
      final cold = AppDatabase(executor: NativeDatabase.opened(raw));
      addTearDown(cold.close);
      cold.localMutations.bindSessionReader(() => 'user-a');
      final row = (await cold.select(cold.syncQueueTable).get()).single;
      expect(row.docId, 'legacy');
      expect(row.ownerUid, isNull);
      expect(row.status, SyncQueuePersistenceStatus.succeeded);
      expect(
        (await cold.customSelect('PRAGMA user_version').get()).single.read<int>(
          'user_version',
        ),
        8,
      );
      await expectLater(
        cold.insertSyncItem(
          ownerUid: 'user-a',
          collection: 'tasks',
          docId: 'new',
          operationType: 'create',
          payloadJson: '{}',
        ),
        throwsA(isA<LocalMutationUnavailable>()),
      );
      expect(await cold.select(cold.syncQueueTable).get(), [row]);
    },
  );

  test(
    'quiesce waits for one whole local mutation and enqueue lease',
    () async {
      final started = Completer<void>();
      final release = Completer<void>();
      final admitted = write(
        'before',
        beforeEnqueue: () async {
          started.complete();
          await release.future;
        },
      );
      await started.future;
      final barrier = db.localMutations.beginQuiesce('user-a');
      var drained = false;
      final drain = barrier.drain().then((_) => drained = true);
      expect(drained, isFalse);
      release.complete();
      await admitted;
      await drain;
      expect(await db.select(db.taskTable).get(), hasLength(1));
      expect(await db.getPendingSyncItems('user-a'), hasLength(1));
      barrier.finish(signOutConfirmed: false);
    },
  );

  test('new mutation waits and resumes after same-session abort', () async {
    final barrier = db.localMutations.beginQuiesce('user-a');
    final waiting = write('waiting');
    expect(await db.select(db.taskTable).get(), isEmpty);
    expect(await db.getPendingSyncItems('user-a'), isEmpty);
    barrier.finish(signOutConfirmed: false);
    await waiting;
    expect(await db.select(db.taskTable).get(), hasLength(1));
    expect(await db.getPendingSyncItems('user-a'), hasLength(1));
    await write('after-abort');
    expect(await db.getPendingSyncItems('user-a'), hasLength(2));
  });

  test('post-quiesce Cycle action does not occupy cleanup tail', () async {
    final cycle = CycleReminderMutationGate(db.localMutations);
    final barrier = db.localMutations.beginQuiesce('user-a');
    var entered = false;
    final waiting = cycle.run('user-a', () async {
      entered = true;
      await write('cycle');
    });
    await cycle.runCleanup('user-a', () async {
      expect(entered, isFalse);
    });
    await barrier.drain();
    expect(await db.getPendingSyncItems('user-a'), isEmpty);
    barrier.finish(signOutConfirmed: false);
    await waiting;
    expect(entered, isTrue);
    expect(await db.getPendingSyncItems('user-a'), hasLength(1));
  });

  test(
    'stale preparation cannot reopen after external same-UID boundary',
    () async {
      final preparation = db.localMutations.capture();
      uid = null;
      db.localMutations.observeSession(uid);
      uid = 'user-a';
      db.localMutations.observeSession(uid);
      expect(
        () => db.localMutations.openPreparedSession(admission: preparation),
        throwsA(isA<LocalMutationUnavailable>()),
      );
      await expectLater(
        write('unprepared'),
        throwsA(isA<LocalMutationUnavailable>()),
      );
      db.localMutations.openPreparedSession(
        admission: db.localMutations.capture(),
      );
      await write('prepared');
    },
  );

  test(
    'successful seal rejects waiting and old tickets even after same-UID login',
    () async {
      final old = db.localMutations.capture();
      final barrier = db.localMutations.beginQuiesce('user-a');
      final waiting = write('late');
      final rejected = expectLater(
        waiting,
        throwsA(isA<LocalMutationUnavailable>()),
      );
      await barrier.cleanup(db.clearAllData);
      uid = null;
      barrier.finish(signOutConfirmed: true);
      await rejected;
      expect(await db.select(db.taskTable).get(), isEmpty);
      uid = 'user-a';
      db.localMutations.openPreparedSession();
      await expectLater(
        db.localMutations.run(() => write('old'), ticket: old),
        throwsA(isA<LocalMutationUnavailable>()),
      );
      await write('new');
      expect((await db.select(db.taskTable).get()).single.id, 'new');
    },
  );

  test('UID change rolls back an already admitted transaction', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    final admitted = write(
      'old',
      beforeEnqueue: () async {
        started.complete();
        await release.future;
      },
    );
    final failed = expectLater(
      admitted,
      throwsA(isA<LocalMutationUnavailable>()),
    );
    await started.future;
    final barrier = db.localMutations.beginQuiesce('user-a');
    uid = 'user-b';
    db.localMutations.observeSession(uid);
    release.complete();
    await failed;
    expect(await db.select(db.taskTable).get(), isEmpty);
    expect(await db.select(db.syncQueueTable).get(), isEmpty);
    barrier.finish(signOutConfirmed: false);
    db.localMutations.openPreparedSession();
    await write('b');
  });

  test('raw SQL and batches cannot bypass quiescence', () async {
    final barrier = db.localMutations.beginQuiesce('user-a');
    await expectLater(
      db.delete(db.taskTable).go(),
      throwsA(isA<LocalMutationUnavailable>()),
    );
    await expectLater(
      db.batch((batch) => batch.deleteAll(db.taskTable)),
      throwsA(isA<LocalMutationUnavailable>()),
    );
    barrier.finish(signOutConfirmed: false);
  });

  test('transient UID change never reopens the old authority', () async {
    final old = db.localMutations.capture();
    final barrier = db.localMutations.beginQuiesce('user-a');
    uid = null;
    db.localMutations.observeSession(uid);
    uid = 'user-a';
    db.localMutations.observeSession(uid);
    await expectLater(
      barrier.drain(),
      throwsA(isA<LocalMutationUnavailable>()),
    );
    barrier.finish(signOutConfirmed: false);
    await expectLater(write('old'), throwsA(isA<LocalMutationUnavailable>()));
    db.localMutations.openPreparedSession();
    await expectLater(
      db.localMutations.run(() => write('old'), ticket: old),
      throwsA(isA<LocalMutationUnavailable>()),
    );
    await write('new');
  });

  test(
    'derived Notifications refuse quiescence but can rebuild after abort',
    () async {
      final dao = NotificationDao(db);
      final incoming = NotificationsTableCompanion.insert(
        id: 'exam_1',
        title: 'Exam',
        description: 'Reminder',
        priority: 'normal',
        moduleType: 'studies',
        route: '/study',
        createdAt: DateTime.utc(2026, 10, 2),
      );
      final old = db.localMutations.capture();
      final barrier = db.localMutations.beginQuiesce('user-a');
      await expectLater(
        dao.upsertPreservingState(incoming),
        throwsA(isA<LocalMutationUnavailable>()),
      );
      expect(await dao.getAllNotifications(), isEmpty);
      barrier.finish(signOutConfirmed: false);
      expect(await dao.upsertPreservingState(incoming), isTrue);
      final logout = db.localMutations.beginQuiesce('user-a');
      await logout.cleanup(db.clearAllData);
      uid = null;
      logout.finish(signOutConfirmed: true);
      uid = 'user-a';
      db.localMutations.openPreparedSession();
      await expectLater(
        dao.upsertPreservingState(incoming, admission: old),
        throwsA(isA<LocalMutationUnavailable>()),
      );
      expect(await dao.getAllNotifications(), isEmpty);
    },
  );

  test(
    'SyncManager acknowledgements and cleanup drain under quiescence',
    () async {
      await write('pending');
      final remote = _Remote();
      final manager = SyncManager(
        queueStore: AppDatabaseSyncQueueStore(db),
        remoteDataSource: remote,
        currentUserId: () => uid,
      );
      addTearDown(manager.dispose);
      final barrier = db.localMutations.beginQuiesce('user-a');
      await barrier.drain();
      expect(await manager.prepareForLocalDataDiscard(), isTrue);
      expect(remote.calls, 1);
      expect(
        (await db.select(db.syncQueueTable).get()).single.status,
        SyncQueuePersistenceStatus.succeeded,
      );
      await barrier.cleanup(db.clearAllData);
      expect(await db.select(db.taskTable).get(), isEmpty);
      barrier.finish(signOutConfirmed: false);
    },
  );

  test('permanent rejection still blocks discard and is not retried', () async {
    await write('pending');
    final remote = _Remote()
      ..result = const SyncOperationResult.invalidPayload();
    final manager = SyncManager(
      queueStore: AppDatabaseSyncQueueStore(db),
      remoteDataSource: remote,
      currentUserId: () => uid,
    );
    addTearDown(manager.dispose);
    final barrier = db.localMutations.beginQuiesce('user-a');
    expect(await manager.prepareForLocalDataDiscard(), isFalse);
    expect(await manager.prepareForLocalDataDiscard(), isFalse);
    expect(remote.calls, 1);
    expect(await db.hasRejectedSyncItems('user-a'), isTrue);
    barrier.finish(signOutConfirmed: false);
  });

  test('retryable acknowledgement stays pending during quiescence', () async {
    await write('pending');
    final remote = _Remote()
      ..result = const SyncOperationResult.retryable(code: 'NETWORK_ERROR');
    final manager = SyncManager(
      queueStore: AppDatabaseSyncQueueStore(db),
      remoteDataSource: remote,
      currentUserId: () => uid,
    );
    addTearDown(manager.dispose);
    final barrier = db.localMutations.beginQuiesce('user-a');
    expect(await manager.prepareForLocalDataDiscard(), isFalse);
    expect((await db.getPendingSyncItems('user-a')).single.attemptCount, 1);
    barrier.finish(signOutConfirmed: false);
  });

  test('sealed cleanup recovery never reopens producer admission', () async {
    final barrier = db.localMutations.beginQuiesce('user-a');
    uid = null;
    barrier.finish(signOutConfirmed: true);
    await db.clearAllData();
    await expectLater(
      db.transaction(() async {}),
      throwsA(isA<LocalMutationUnavailable>()),
    );
  });

  test(
    'lazy database initialization is internal after admission closes',
    () async {
      final lazy = AppDatabase(executor: NativeDatabase.memory());
      addTearDown(lazy.close);
      lazy.localMutations.bindSessionReader(() => uid);
      lazy.localMutations.openPreparedSession(
        admission: lazy.localMutations.capture(expectedUid: uid),
      );
      final barrier = lazy.localMutations.beginQuiesce('user-a');
      await barrier.cleanup(() => lazy.customSelect('SELECT 1').get());
      await barrier.drain();
      expect(await lazy.select(lazy.syncQueueTable).get(), isEmpty);
      await expectLater(
        lazy.customStatement('DELETE FROM sync_queue_table'),
        throwsA(isA<LocalMutationUnavailable>()),
      );
      barrier.finish(signOutConfirmed: false);
    },
  );

  test('escaped asynchronous zone cannot reuse a finished old lease', () async {
    final release = Completer<void>();
    late Future<void> lateWrite;
    await db.localMutations.run(() async {
      lateWrite = release.future.then((_) => write('escaped'));
    });
    final failed = expectLater(
      lateWrite,
      throwsA(isA<LocalMutationUnavailable>()),
    );
    final barrier = db.localMutations.beginQuiesce('user-a');
    uid = null;
    barrier.finish(signOutConfirmed: true);
    uid = 'user-a';
    db.localMutations.openPreparedSession();
    release.complete();
    await failed;
    expect(await db.select(db.taskTable).get(), isEmpty);
  });
}
