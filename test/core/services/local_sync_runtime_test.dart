import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/database_provider.dart';
import 'package:life_os/core/database/database_sync_policy.dart';
import 'package:life_os/core/database/local_database_identity.dart';
import 'package:life_os/core/services/firebase_auth_provider.dart';
import 'package:life_os/core/services/sync_manager.dart';
import 'package:life_os/core/services/sync_manager_provider.dart';
import 'package:life_os/core/services/sync_operation_result.dart';
import 'package:life_os/core/services/sync_queue_store.dart';
import 'package:life_os/core/services/sync_remote_data_source.dart';
import 'package:life_os/features/auth/presentation/providers/auth_provider.dart'
    show firestoreProvider;

class _Remote implements SyncRemoteDataSource {
  int calls = 0;
  @override
  Future<SyncOperationResult> process(
    String uid,
    SyncQueueTableData item,
  ) async {
    calls++;
    return const SyncOperationResult.success();
  }
}

class _Store extends AppDatabaseSyncQueueStore {
  _Store(super.db);
  int cleanupCalls = 0, readCalls = 0;
  @override
  Future<int> cleanupSucceededSyncItems(String uid, int older) {
    cleanupCalls++;
    return super.cleanupSucceededSyncItems(uid, older);
  }

  @override
  Future<List<SyncQueueTableData>> getPendingSyncItems(String uid) {
    readCalls++;
    return super.getPendingSyncItems(uid);
  }
}

void main() {
  const uid = 'local-v1-123e4567-e89b-42d3-a456-426614174000';
  final identity = LocalDatabaseIdentity(uid);
  AppDatabase localMemory() {
    final db = AppDatabase.forUser(
      identity: identity,
      executor: NativeDatabase.memory(),
      syncPolicy: DatabaseSyncPolicy.localOnly,
    );
    addTearDown(db.close);
    return db;
  }

  test(
    'provider creates local manager without reading Firebase providers',
    () async {
      final db = localMemory();
      var firebaseReads = 0;
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          firebaseAuthProvider.overrideWith((ref) {
            firebaseReads++;
            throw StateError('MUST_NOT_READ_AUTH');
          }),
          firestoreProvider.overrideWith((ref) {
            firebaseReads++;
            throw StateError('MUST_NOT_READ_FIRESTORE');
          }),
        ],
      );
      addTearDown(container.dispose);
      final manager = container.read(syncManagerProvider);
      expect(manager.isForDatabase(db), true);
      expect(manager.remoteEnabled, false);
      expect(await manager.processPendingItems(), false);
      expect(firebaseReads, 0);
    },
  );
  test(
    'generic manager cannot enable remote processing for a local queue',
    () async {
      final db = localMemory();
      final store = _Store(db);
      final remote = _Remote();
      var ownerReads = 0;
      final manager = SyncManager(
        queueStore: store,
        remoteDataSource: remote,
        currentUserId: () {
          ownerReads++;
          return uid;
        },
      );
      addTearDown(manager.dispose);
      expect(manager.remoteEnabled, false);
      expect(await manager.processPendingItems(), false);
      expect(await manager.prepareForLocalDataDiscard(), false);
      expect(store.cleanupCalls, 0);
      expect(store.readCalls, 0);
      expect(remote.calls, 0);
      expect(ownerReads, 0);
      expect(db.isLocalOnly, true);
    },
  );
  test(
    'local manager preserves historical payload, status and attempt metadata',
    () async {
      final root = await Directory.systemTemp.createTemp('lifeos-local-sync-');
      addTearDown(() => root.delete(recursive: true));
      final file = File('${root.path}/synthetic.sqlite');
      final seed = AppDatabase.forUser(
        identity: identity,
        executor: NativeDatabase(file),
      );
      await seed.insertSyncItem(
        ownerUid: uid,
        collection: 'tasks',
        docId: 'historical',
        operationType: 'create',
        payloadJson: '{"preserve":true}',
        createdAt: 123,
      );
      final original = (await seed.select(seed.syncQueueTable).get()).single;
      await seed.close();
      final db = AppDatabase.forUser(
        identity: identity,
        executor: NativeDatabase(file),
        syncPolicy: DatabaseSyncPolicy.localOnly,
      );
      final store = _Store(db), remote = _Remote();
      final manager = SyncManager(
        queueStore: store,
        remoteDataSource: remote,
        currentUserId: () => uid,
      );
      try {
        expect(await manager.processPendingItems(), false);
        expect(await manager.prepareForLocalDataDiscard(), false);
        expect((await db.select(db.syncQueueTable).get()).single, original);
        expect(store.cleanupCalls, 0);
        expect(store.readCalls, 0);
        expect(remote.calls, 0);
      } finally {
        manager.dispose();
        await db.close();
      }
    },
  );
  test(
    'local factory rejects remote-enabled database instead of disguising it',
    () {
      final db = AppDatabase.forUser(
        identity: identity,
        executor: NativeDatabase.memory(),
      );
      addTearDown(db.close);
      expect(() => SyncManager.local(db), throwsArgumentError);
    },
  );
}
