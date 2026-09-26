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
  final List<int> rejected = [];
  final List<int> retried = [];

  FakeSyncQueueStore(this.items);

  @override
  Future<List<SyncQueueTableData>> getPendingSyncItems(String ownerUid) async {
    return List.unmodifiable(
      items.where(
        (item) =>
            !markedAsSynced.contains(item.id) && !rejected.contains(item.id),
      ),
    );
  }

  @override
  Future<int> markSyncItemAsSucceeded(int id, String ownerUid) async {
    markedAsSynced.add(id);
    return 1;
  }

  @override
  Future<int> markSyncItemRejected(
    int id,
    String ownerUid,
    String errorCode,
  ) async {
    rejected.add(id);
    return 1;
  }

  @override
  Future<int> markSyncItemRetryableFailure(
    int id,
    String ownerUid,
    String errorCode,
  ) async {
    retried.add(id);
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
  String? ownerUid = 'user-123',
}) {
  return SyncQueueTableData(
    id: id,
    ownerUid: ownerUid,
    collection: collection,
    docId: docId,
    operationType: operationType,
    payloadJson: payloadJson,
    createdAt: DateTime.now().millisecondsSinceEpoch,
    isSynced: false,
    status: SyncQueuePersistenceStatus.pending,
    attemptCount: 0,
  );
}

SyncQueueTableData createHealthSyncItem({
  required int id,
  required Map<String, dynamic> payload,
}) {
  return SyncQueueTableData(
    id: id,
    ownerUid: 'user-123',
    collection: 'health_info',
    docId: '2026-08-21',
    operationType: 'update',
    payloadJson: jsonEncode(payload),
    createdAt: DateTime.now().millisecondsSinceEpoch,
    isSynced: false,
    status: SyncQueuePersistenceStatus.pending,
    attemptCount: 0,
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
      manager.dispose();
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

    test('não processa item pertencente a outro UID', () async {
      final item = createSyncItem(ownerUid: 'user-a');
      final store = FakeSyncQueueStore([item]);
      final remote = FakeSyncRemoteDataSource(
        (uid, item) => Future.value(const SyncOperationResult.success()),
      );
      final manager = SyncManager(
        queueStore: store,
        remoteDataSource: remote,
        currentUserId: () => 'user-b',
      );

      await manager.processPendingItems();

      expect(remote.processedItems, isEmpty);
      expect(store.markedAsSynced, isEmpty);
      expect(store.rejected, isEmpty);
    });

    test('não processa item legado sem ownership', () async {
      final item = createSyncItem(ownerUid: null);
      final store = FakeSyncQueueStore([item]);
      final remote = FakeSyncRemoteDataSource(
        (uid, item) => Future.value(const SyncOperationResult.success()),
      );
      final manager = SyncManager(
        queueStore: store,
        remoteDataSource: remote,
        currentUserId: () => 'user-123',
      );

      await manager.processPendingItems();

      expect(remote.processedItems, isEmpty);
      expect(store.markedAsSynced, isEmpty);
    });

    test('troca de usuário durante processamento não confirma item', () async {
      var currentUid = 'user-123';
      final started = Completer<void>();
      final release = Completer<void>();
      final store = FakeSyncQueueStore([createSyncItem()]);
      final remote = FakeSyncRemoteDataSource((uid, item) async {
        started.complete();
        await release.future;
        return const SyncOperationResult.success();
      });
      final manager = SyncManager(
        queueStore: store,
        remoteDataSource: remote,
        currentUserId: () => currentUid,
      );

      final processing = manager.processPendingItems();
      await started.future;
      currentUid = 'user-456';
      release.complete();

      expect(await processing, isFalse);
      expect(store.markedAsSynced, isEmpty);
    });

    for (final testCase in <String, SyncOperationResult>{
      'quotaExceeded': const SyncOperationResult.quotaExceeded(),
      'invalidPayload': const SyncOperationResult.invalidPayload(),
      'unsupportedOperation': const SyncOperationResult.unsupportedOperation(),
    }.entries) {
      test('${testCase.key} rejeita sem marcar sucesso', () async {
        final store = FakeSyncQueueStore([createSyncItem()]);
        final remote = FakeSyncRemoteDataSource(
          (uid, item) async => testCase.value,
        );
        final manager = SyncManager(
          queueStore: store,
          remoteDataSource: remote,
          currentUserId: () => 'user-123',
        );

        await manager.processPendingItems();

        expect(store.rejected, [1]);
        expect(store.markedAsSynced, isEmpty);
      });
    }

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

      expect(store.markedAsSynced, [2]);
      expect(store.rejected, [1]);
      expect(remote.processedItems, [
        'user-123:habits:habit-1:create',
        'user-123:habits:habit-2:create',
      ]);

      await manager.processPendingItems();

      expect(store.markedAsSynced, [2]);
      expect(store.rejected, [1]);
      expect(remote.processedItems, [
        'user-123:habits:habit-1:create',
        'user-123:habits:habit-2:create',
      ]);
    });

    test('invalidPayload rejeita item e continua a FIFO', () async {
      final store = FakeSyncQueueStore([
        createSyncItem(id: 1),
        createSyncItem(id: 2, docId: 'habit-2'),
      ]);
      final remote = FakeSyncRemoteDataSource(
        (uid, item) async => item.id == 1
            ? const SyncOperationResult.invalidPayload()
            : const SyncOperationResult.success(),
      );
      final manager = SyncManager(
        queueStore: store,
        remoteDataSource: remote,
        currentUserId: () => 'user-123',
      );

      expect(await manager.processPendingItems(), isTrue);
      expect(store.rejected, [1]);
      expect(store.markedAsSynced, [2]);
      expect(store.retried, isEmpty);
      expect(remote.processedItems, [
        'user-123:habits:habit-1:create',
        'user-123:habits:habit-2:create',
      ]);
      manager.dispose();
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
        final secondRun = manager.processPendingItems();
        releaseFirst.complete();
        await Future.wait([firstRun, secondRun]);

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

    testWidgets('retry automático conclui item após cinco segundos', (
      tester,
    ) async {
      final store = FakeSyncQueueStore([createSyncItem()]);
      var calls = 0;
      final remote = FakeSyncRemoteDataSource((uid, item) async {
        calls++;
        return calls == 1
            ? const SyncOperationResult.retryable(code: 'UNAVAILABLE')
            : const SyncOperationResult.success();
      });
      final manager = SyncManager(
        queueStore: store,
        remoteDataSource: remote,
        currentUserId: () => 'user-123',
      );

      expect(await manager.processPendingItems(), isFalse);
      expect(calls, 1);
      expect(store.markedAsSynced, isEmpty);
      expect(store.retried, [1]);

      await tester.pump(const Duration(seconds: 4));
      expect(calls, 1);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(calls, 2);
      expect(store.markedAsSynced, [1]);
      manager.dispose();
    });

    testWidgets('backoff cresce até cinco minutos', (tester) async {
      final store = FakeSyncQueueStore([createSyncItem()]);
      final remote = FakeSyncRemoteDataSource(
        (uid, item) async =>
            const SyncOperationResult.retryable(code: 'UNAVAILABLE'),
      );
      final manager = SyncManager(
        queueStore: store,
        remoteDataSource: remote,
        currentUserId: () => 'user-123',
      );

      await manager.processPendingItems();
      for (final (index, delay) in [
        const Duration(seconds: 5),
        const Duration(seconds: 15),
        const Duration(seconds: 30),
        const Duration(minutes: 1),
        const Duration(minutes: 5),
      ].indexed) {
        await tester.pump(delay - const Duration(seconds: 1));
        expect(remote.processedItems.length, index + 1);
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
        expect(remote.processedItems.length, index + 2);
      }
      expect(store.retried, hasLength(6));
      manager.dispose();
    });

    testWidgets('sucesso reseta o backoff para nova operação', (tester) async {
      final store = FakeSyncQueueStore([createSyncItem()]);
      var calls = 0;
      final remote = FakeSyncRemoteDataSource((uid, item) async {
        calls++;
        return calls.isOdd
            ? const SyncOperationResult.retryable(code: 'UNAVAILABLE')
            : const SyncOperationResult.success();
      });
      final manager = SyncManager(
        queueStore: store,
        remoteDataSource: remote,
        currentUserId: () => 'user-123',
      );

      await manager.processPendingItems();
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(store.markedAsSynced, [1]);

      store.items.add(createSyncItem(id: 2, docId: 'habit-2'));
      await manager.processPendingItems();
      expect(calls, 3);
      await tester.pump(const Duration(seconds: 4));
      expect(calls, 3);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(calls, 4);
      expect(store.markedAsSynced, [1, 2]);
      manager.dispose();
    });

    testWidgets('troca de sessão não executa retry do UID antigo', (
      tester,
    ) async {
      var currentUid = 'user-123';
      final store = FakeSyncQueueStore([createSyncItem()]);
      final remote = FakeSyncRemoteDataSource(
        (uid, item) async =>
            const SyncOperationResult.retryable(code: 'UNAVAILABLE'),
      );
      final manager = SyncManager(
        queueStore: store,
        remoteDataSource: remote,
        currentUserId: () => currentUid,
      );

      await manager.processPendingItems();
      currentUid = 'user-b';
      await tester.pump(const Duration(seconds: 10));
      await tester.pump();
      expect(remote.processedItems, hasLength(1));
      expect(store.markedAsSynced, isEmpty);
      manager.dispose();
    });

    testWidgets('dispose cancela retry pendente', (tester) async {
      final store = FakeSyncQueueStore([createSyncItem()]);
      final remote = FakeSyncRemoteDataSource(
        (uid, item) async =>
            const SyncOperationResult.retryable(code: 'UNAVAILABLE'),
      );
      final manager = SyncManager(
        queueStore: store,
        remoteDataSource: remote,
        currentUserId: () => 'user-123',
      );

      await manager.processPendingItems();
      manager.dispose();
      await tester.pump(const Duration(seconds: 10));
      expect(remote.processedItems, hasLength(1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('trigger manual substitui timer sem terceira chamada', (
      tester,
    ) async {
      final store = FakeSyncQueueStore([createSyncItem()]);
      var calls = 0;
      final remote = FakeSyncRemoteDataSource((uid, item) async {
        calls++;
        return calls == 1
            ? const SyncOperationResult.retryable(code: 'UNAVAILABLE')
            : const SyncOperationResult.success();
      });
      final manager = SyncManager(
        queueStore: store,
        remoteDataSource: remote,
        currentUserId: () => 'user-123',
      );

      await manager.processPendingItems();
      await tester.pump(const Duration(seconds: 2));
      expect(await manager.processPendingItems(), isTrue);
      expect(calls, 2);
      await tester.pump(const Duration(seconds: 10));
      expect(calls, 2);
      expect(store.markedAsSynced, [1]);
      manager.dispose();
    });
  });
}
