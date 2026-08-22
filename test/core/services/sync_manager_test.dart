import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/services/sync_manager.dart';
import 'package:life_os/core/services/sync_operation_result.dart';
import 'package:life_os/core/services/sync_queue_store.dart';
import 'package:life_os/core/services/sync_remote_data_source.dart';

class FakeSyncQueueStore implements SyncQueueStore {
  final List<SyncQueueTableData> items;

  final List<int> markedAsSynced = [];

  FakeSyncQueueStore(this.items);

  @override
  Future<List<SyncQueueTableData>> getPendingSyncItems() async {
    return List.unmodifiable(
      items.where((item) => !markedAsSynced.contains(item.id)),
    );
  }

  @override
  Future<int> markSyncItemAsSynced(int id) async {
    markedAsSynced.add(id);
    return 1;
  }
}

class FakeSyncRemoteDataSource implements SyncRemoteDataSource {
  final Future<SyncOperationResult> Function(
    String uid,
    SyncQueueTableData item,
  )
  handler;

  final List<String> processedItems = [];

  FakeSyncRemoteDataSource(this.handler);

  @override
  Future<SyncOperationResult> process(
    String uid,
    SyncQueueTableData item,
  ) async {
    processedItems.add(
      '$uid:${item.collection}:${item.docId}:${item.operationType}',
    );

    return handler(uid, item);
  }
}

SyncQueueTableData createSyncItem({
  int id = 1,
  String collection = 'habits',
  String docId = 'habit-1',
  String operationType = 'create',
  String payloadJson = '{"title":"Hábito"}',
}) {
  return SyncQueueTableData(
    id: id,
    collection: collection,
    docId: docId,
    operationType: operationType,
    payloadJson: payloadJson,
    createdAt: DateTime.now().millisecondsSinceEpoch,
    isSynced: false,
  );
}

SyncQueueTableData createHealthSyncItem({
  required int id,
  required Map<String, dynamic> payload,
}) {
  return SyncQueueTableData(
    id: id,
    collection: 'health_info',
    docId: '2026-08-21',
    operationType: 'update',
    payloadJson: jsonEncode(payload),
    createdAt: DateTime.now().millisecondsSinceEpoch,
    isSynced: false,
  );
}

class FakeHealthMergeRemoteDataSource implements SyncRemoteDataSource {
  int calls = 0;
  bool failFirstCall = true;
  final Map<String, dynamic> firestoreDoc = <String, dynamic>{};

  @override
  Future<SyncOperationResult> process(
    String uid,
    SyncQueueTableData item,
  ) async {
    calls += 1;

    if (failFirstCall && calls == 1) {
      return const SyncOperationResult.retryable(code: 'UNAVAILABLE');
    }

    final payload = Map<String, dynamic>.from(jsonDecode(item.payloadJson));
    firestoreDoc.addAll(payload);
    return const SyncOperationResult.success();
  }
}

void main() {
  group('SyncManager', () {
    test('processa operação com sucesso e marca como sincronizada', () async {
      final item = createSyncItem();

      final store = FakeSyncQueueStore([item]);

      final remote = FakeSyncRemoteDataSource((uid, item) async {
        return const SyncOperationResult.success();
      });

      final manager = SyncManager(
        queueStore: store,
        remoteDataSource: remote,
        currentUserId: () => 'user-123',
      );

      await manager.processPendingItems();

      expect(remote.processedItems, ['user-123:habits:habit-1:create']);

      expect(store.markedAsSynced, [1]);
    });

    test('mantém operação pendente em erro recuperável', () async {
      final item = createSyncItem();

      final store = FakeSyncQueueStore([item]);

      final remote = FakeSyncRemoteDataSource((uid, item) async {
        return const SyncOperationResult.retryable(code: 'UNAVAILABLE');
      });

      final manager = SyncManager(
        queueStore: store,
        remoteDataSource: remote,
        currentUserId: () => 'user-123',
      );

      await manager.processPendingItems();

      expect(store.markedAsSynced, isEmpty);
      expect(remote.processedItems.length, 1);
    });

    test('não processa a fila sem usuário autenticado', () async {
      final item = createSyncItem();

      final store = FakeSyncQueueStore([item]);

      final remote = FakeSyncRemoteDataSource(
        (uid, item) => Future.value(const SyncOperationResult.success()),
      );

      final manager = SyncManager(
        queueStore: store,
        remoteDataSource: remote,
        currentUserId: () => null,
      );

      await manager.processPendingItems();

      expect(remote.processedItems, isEmpty);
      expect(store.markedAsSynced, isEmpty);
    });

    test('terminaliza erro permanente e não o reprocessa', () async {
      final first = createSyncItem(id: 1);
      final second = createSyncItem(id: 2, docId: 'habit-2');

      final store = FakeSyncQueueStore([first, second]);

      final remote = FakeSyncRemoteDataSource((uid, item) async {
        if (item.id == 1) {
          return const SyncOperationResult.permissionDenied();
        }

        return const SyncOperationResult.success();
      });

      final manager = SyncManager(
        queueStore: store,
        remoteDataSource: remote,
        currentUserId: () => 'user-123',
      );

      await manager.processPendingItems();

      expect(store.markedAsSynced, [1, 2]);
      expect(remote.processedItems, [
        'user-123:habits:habit-1:create',
        'user-123:habits:habit-2:create',
      ]);

      await manager.processPendingItems();

      expect(store.markedAsSynced, [1, 2]);
      expect(remote.processedItems, [
        'user-123:habits:habit-1:create',
        'user-123:habits:habit-2:create',
      ]);
    });

    test('não executa duas sincronizações concorrentes', () async {
      final item = createSyncItem();

      final store = FakeSyncQueueStore([item]);

      final remote = FakeSyncRemoteDataSource((uid, item) async {
        return const SyncOperationResult.success();
      });

      final manager = SyncManager(
        queueStore: store,
        remoteDataSource: remote,
        currentUserId: () => 'user-123',
      );

      await Future.wait([
        manager.processPendingItems(),
        manager.processPendingItems(),
      ]);

      expect(remote.processedItems.length, 1);
      expect(store.markedAsSynced, [1]);
    });

    test(
      'processa item inserido enquanto outro lote ainda está em andamento',
      () async {
        final mood = createHealthSyncItem(id: 1, payload: {'mood': 'Radiante'});
        final water = createHealthSyncItem(
          id: 2,
          payload: {'waterIntakeMl': 250},
        );
        final store = FakeSyncQueueStore([mood]);
        final firstStarted = Completer<void>();
        final releaseFirst = Completer<void>();
        final remote = FakeSyncRemoteDataSource((uid, item) async {
          if (item.id == mood.id) {
            firstStarted.complete();
            await releaseFirst.future;
          }

          return const SyncOperationResult.success();
        });
        final manager = SyncManager(
          queueStore: store,
          remoteDataSource: remote,
          currentUserId: () => 'user-123',
        );

        final firstRun = manager.processPendingItems();
        await firstStarted.future;

        store.items.add(water);
        await manager.processPendingItems();
        releaseFirst.complete();
        await firstRun;

        expect(store.markedAsSynced, [1, 2]);
        expect(remote.processedItems, [
          'user-123:health_info:2026-08-21:update',
          'user-123:health_info:2026-08-21:update',
        ]);
      },
    );

    test(
      'health_info permanece pendente em falha recuperável e preserva merge',
      () async {
        final mood = createHealthSyncItem(
          id: 1,
          payload: {'mood': 'Radiante', 'date': '2026-08-21T10:00:00.000Z'},
        );
        final water = createHealthSyncItem(
          id: 2,
          payload: {'waterIntakeMl': 250, 'date': '2026-08-21T10:05:00.000Z'},
        );

        final store = FakeSyncQueueStore([mood, water]);
        final remote = FakeHealthMergeRemoteDataSource();

        final manager = SyncManager(
          queueStore: store,
          remoteDataSource: remote,
          currentUserId: () => 'user-123',
        );

        await manager.processPendingItems();

        expect(remote.calls, 1);
        expect(store.markedAsSynced, isEmpty);
        expect(remote.firestoreDoc, isEmpty);

        await manager.processPendingItems();

        expect(remote.calls, 3);
        expect(store.markedAsSynced, [1, 2]);
        expect(remote.firestoreDoc, {
          'mood': 'Radiante',
          'date': '2026-08-21T10:05:00.000Z',
          'waterIntakeMl': 250,
        });
      },
    );
  });
}
