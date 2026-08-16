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
    return List.unmodifiable(items);
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

    test('para a fila quando ocorre erro permanente', () async {
      final first = createSyncItem(id: 1);
      final second = createSyncItem(id: 2, docId: 'habit-2');

      final store = FakeSyncQueueStore([first, second]);

      final remote = FakeSyncRemoteDataSource((uid, item) async {
        return const SyncOperationResult.permissionDenied();
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
  });
}
