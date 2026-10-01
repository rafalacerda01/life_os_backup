import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/services/sync_manager.dart';
import 'package:life_os/core/services/sync_operation_result.dart';
import 'package:life_os/core/services/sync_queue_store.dart';
import 'package:life_os/core/services/sync_remote_data_source.dart';
import 'package:life_os/core/services/sync_ui_event.dart';

class FakeSyncQueueStore
    implements SyncQueueStore, SyncQueueDiscardSafetyStore {
  final List<SyncQueueTableData> items;

  final List<int> markedAsSynced = [];
  final List<int> rejected = [];
  final List<int> retried = [];
  final List<(String, int)> cleanupRequests = [];
  final List<String> events = [];
  bool cleanupFails = false;
  Future<void> Function()? cleanupOperation;
  Future<void> Function()? rejectionReadOperation;
  bool rejectionReadFails = false;

  FakeSyncQueueStore(this.items);

  @override
  Future<bool> hasRejectedSyncItems(String ownerUid) async {
    await rejectionReadOperation?.call();
    if (rejectionReadFails) throw StateError('technical-rejection-read-marker');
    return items.any(
      (item) =>
          item.ownerUid == ownerUid &&
          (item.status == SyncQueuePersistenceStatus.rejected ||
              rejected.contains(item.id)),
    );
  }

  @override
  Future<int> cleanupSucceededSyncItems(
    String ownerUid,
    int olderThanEpochMs,
  ) async {
    cleanupRequests.add((ownerUid, olderThanEpochMs));
    events.add('cleanup:$ownerUid');
    await cleanupOperation?.call();
    if (cleanupFails) throw StateError('technical-cleanup-marker');
    return 0;
  }

  @override
  Future<List<SyncQueueTableData>> getPendingSyncItems(String ownerUid) async {
    events.add('read:$ownerUid');
    return List.unmodifiable(
      items.where(
        (item) =>
            item.status == SyncQueuePersistenceStatus.pending &&
            !markedAsSynced.contains(item.id) &&
            !rejected.contains(item.id),
      ),
    );
  }

  @override
  Future<int> markSyncItemAsSucceeded(int id, String ownerUid) async {
    markedAsSynced.add(id);
    _updateItem(id, ownerUid, SyncQueuePersistenceStatus.succeeded, true);
    return 1;
  }

  @override
  Future<int> markSyncItemRejected(
    int id,
    String ownerUid,
    String errorCode,
  ) async {
    rejected.add(id);
    _updateItem(id, ownerUid, SyncQueuePersistenceStatus.rejected, false);
    return 1;
  }

  @override
  Future<int> markSyncItemRetryableFailure(
    int id,
    String ownerUid,
    String errorCode,
  ) async {
    retried.add(id);
    _updateItem(id, ownerUid, SyncQueuePersistenceStatus.pending, false);
    return 1;
  }

  void _updateItem(int id, String ownerUid, String status, bool isSynced) {
    final index = items.indexWhere(
      (item) => item.id == id && item.ownerUid == ownerUid,
    );
    if (index == -1) return;
    final item = items[index];
    items[index] = item.copyWith(
      status: status,
      isSynced: isSynced,
      attemptCount: item.attemptCount + 1,
    );
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
  int attemptCount = 0,
  String status = SyncQueuePersistenceStatus.pending,
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
    status: status,
    attemptCount: attemptCount,
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

SyncManager _recordUiEvents(
  FakeSyncQueueStore store,
  FakeSyncRemoteDataSource remote,
  List<SyncUiEvent> events, {
  String? Function()? currentUserId,
}) {
  final manager = SyncManager(
    queueStore: store,
    remoteDataSource: remote,
    currentUserId: currentUserId ?? () => 'user-123',
  );
  final subscription = manager.uiEvents.listen(events.add);
  addTearDown(() async {
    manager.dispose();
    await subscription.cancel();
  });
  return manager;
}

void main() {
  group('SyncManager recovery UI events', () {
    test('first-attempt success emits no recovery feedback', () async {
      final events = <SyncUiEvent>[];
      final manager = _recordUiEvents(
        FakeSyncQueueStore([createSyncItem()]),
        FakeSyncRemoteDataSource(
          (_, _) async => const SyncOperationResult.success(),
        ),
        events,
      );

      expect(await manager.processPendingItems(), isTrue);
      expect(events, isEmpty);
    });

    test(
      'retryable alone emits no resumed or recoveryCompleted event',
      () async {
        final events = <SyncUiEvent>[];
        final store = FakeSyncQueueStore([createSyncItem()]);
        final manager = _recordUiEvents(
          store,
          FakeSyncRemoteDataSource(
            (_, _) async => const SyncOperationResult.retryable(),
          ),
          events,
        );

        expect(await manager.processPendingItems(), isFalse);
        expect(store.items.single.attemptCount, 1);
        expect(store.items.single.status, SyncQueuePersistenceStatus.pending);
        expect(events, isEmpty);
      },
    );

    test(
      'retry then success emits resumed and recoveryCompleted exactly once',
      () async {
        final events = <SyncUiEvent>[];
        var calls = 0;
        final manager = _recordUiEvents(
          FakeSyncQueueStore([createSyncItem()]),
          FakeSyncRemoteDataSource(
            (_, _) async => ++calls == 1
                ? const SyncOperationResult.retryable()
                : const SyncOperationResult.success(),
          ),
          events,
        );

        expect(await manager.processPendingItems(), isFalse);
        expect(events, isEmpty);
        expect(await manager.processPendingItems(), isTrue);
        expect(await manager.processPendingItems(), isTrue);
        expect(events.map((event) => event.type), [
          SyncUiEventType.resumed,
          SyncUiEventType.recoveryCompleted,
        ]);
        expect(events.map((event) => event.ownerUid), everyElement('user-123'));
        expect(calls, 2);
      },
    );

    testWidgets('multiple automatic retries do not spam recovery events', (
      tester,
    ) async {
      final events = <SyncUiEvent>[];
      var calls = 0;
      final manager = _recordUiEvents(
        FakeSyncQueueStore([createSyncItem()]),
        FakeSyncRemoteDataSource(
          (_, _) async => ++calls <= 3
              ? const SyncOperationResult.retryable(code: 'BACKEND_429')
              : const SyncOperationResult.success(),
        ),
        events,
      );

      expect(await manager.processPendingItems(), isFalse);
      for (final delay in [
        const Duration(seconds: 5),
        const Duration(seconds: 15),
      ]) {
        await tester.pump(delay);
        await tester.pump();
        expect(events, isEmpty);
      }
      await tester.pump(const Duration(seconds: 30));
      await tester.pump();
      expect(calls, 4);
      expect(events.map((event) => event.type), [
        SyncUiEventType.resumed,
        SyncUiEventType.recoveryCompleted,
      ]);
    });

    test('persisted retry attempts recover after manager restart', () async {
      final store = FakeSyncQueueStore([createSyncItem(attemptCount: 2)]);
      final events = <SyncUiEvent>[];
      final manager = _recordUiEvents(
        store,
        FakeSyncRemoteDataSource(
          (_, _) async => const SyncOperationResult.success(),
        ),
        events,
      );

      expect(await manager.processPendingItems(), isTrue);
      await Future<void>.value();
      expect(events.map((event) => event.type), [
        SyncUiEventType.resumed,
        SyncUiEventType.recoveryCompleted,
      ]);
      expect(store.items.single.status, SyncQueuePersistenceStatus.succeeded);
    });

    test(
      'new rejection blocks recoveryCompleted even when drain returns true',
      () async {
        final store = FakeSyncQueueStore([
          createSyncItem(attemptCount: 1),
          createSyncItem(id: 2),
        ]);
        final events = <SyncUiEvent>[];
        final manager = _recordUiEvents(
          store,
          FakeSyncRemoteDataSource(
            (_, item) async => item.id == 1
                ? const SyncOperationResult.success()
                : const SyncOperationResult.invalidPayload(),
          ),
          events,
        );

        expect(await manager.processPendingItems(), isTrue);
        expect(await manager.processPendingItems(), isTrue);
        expect(events.map((event) => event.type), [SyncUiEventType.resumed]);
        expect(await store.hasRejectedSyncItems('user-123'), isTrue);
        expect(store.rejected, [2]);
      },
    );

    test('old persisted rejection blocks recoveryCompleted', () async {
      final store = FakeSyncQueueStore([
        createSyncItem(attemptCount: 1),
        createSyncItem(id: 2, status: SyncQueuePersistenceStatus.rejected),
      ]);
      final events = <SyncUiEvent>[];
      final manager = _recordUiEvents(
        store,
        FakeSyncRemoteDataSource(
          (_, _) async => const SyncOperationResult.success(),
        ),
        events,
      );

      expect(await manager.processPendingItems(), isTrue);
      expect(events.map((event) => event.type), [SyncUiEventType.resumed]);
      expect(store.items.last.status, SyncQueuePersistenceStatus.rejected);
      expect(store.markedAsSynced, [1]);
    });

    test('rejection for another UID does not block current recovery', () async {
      final events = <SyncUiEvent>[];
      final manager = _recordUiEvents(
        FakeSyncQueueStore([
          createSyncItem(attemptCount: 1),
          createSyncItem(
            id: 2,
            ownerUid: 'user-b',
            status: SyncQueuePersistenceStatus.rejected,
          ),
        ]),
        FakeSyncRemoteDataSource(
          (_, _) async => const SyncOperationResult.success(),
        ),
        events,
      );

      expect(await manager.processPendingItems(), isTrue);
      await Future<void>.value();
      expect(events.map((event) => event.type), [
        SyncUiEventType.resumed,
        SyncUiEventType.recoveryCompleted,
      ]);
    });

    test(
      'another retryable delays completion without another resumed event',
      () async {
        final events = <SyncUiEvent>[];
        var secondCalls = 0;
        final store = FakeSyncQueueStore([
          createSyncItem(attemptCount: 1),
          createSyncItem(id: 2),
        ]);
        final manager = _recordUiEvents(
          store,
          FakeSyncRemoteDataSource(
            (_, item) async => item.id == 2 && ++secondCalls == 1
                ? const SyncOperationResult.retryable()
                : const SyncOperationResult.success(),
          ),
          events,
        );

        expect(await manager.processPendingItems(), isFalse);
        expect(events.map((event) => event.type), [SyncUiEventType.resumed]);
        expect(store.items.last.status, SyncQueuePersistenceStatus.pending);
        expect(await manager.processPendingItems(), isTrue);
        await Future<void>.value();
        expect(events.map((event) => event.type), [
          SyncUiEventType.resumed,
          SyncUiEventType.recoveryCompleted,
        ]);
      },
    );

    test(
      'UID change during remote call suppresses old recovery events',
      () async {
        var uid = 'user-123';
        final started = Completer<void>();
        final release = Completer<void>();
        final events = <SyncUiEvent>[];
        final manager = _recordUiEvents(
          FakeSyncQueueStore([createSyncItem(attemptCount: 1)]),
          FakeSyncRemoteDataSource((_, _) async {
            started.complete();
            await release.future;
            return const SyncOperationResult.success();
          }),
          events,
          currentUserId: () => uid,
        );

        final drain = manager.processPendingItems();
        await started.future;
        uid = 'user-b';
        release.complete();
        expect(await drain, isFalse);
        expect(events, isEmpty);
      },
    );

    test(
      'UID change during completion check suppresses recoveryCompleted',
      () async {
        var uid = 'user-123';
        final store = FakeSyncQueueStore([createSyncItem(attemptCount: 1)]);
        store.rejectionReadOperation = () async {
          uid = 'user-b';
        };
        final events = <SyncUiEvent>[];
        final manager = _recordUiEvents(
          store,
          FakeSyncRemoteDataSource(
            (_, _) async => const SyncOperationResult.success(),
          ),
          events,
          currentUserId: () => uid,
        );

        expect(await manager.processPendingItems(), isFalse);
        expect(events.map((event) => event.type), [SyncUiEventType.resumed]);
      },
    );

    test(
      'new pending item during completion check prevents recoveryCompleted',
      () async {
        final store = FakeSyncQueueStore([createSyncItem(attemptCount: 1)]);
        store.rejectionReadOperation = () async {
          store.items.add(createSyncItem(id: 2));
          store.rejectionReadOperation = null;
        };
        final events = <SyncUiEvent>[];
        final manager = _recordUiEvents(
          store,
          FakeSyncRemoteDataSource(
            (_, _) async => const SyncOperationResult.success(),
          ),
          events,
        );

        expect(await manager.processPendingItems(), isTrue);
        expect(events.map((event) => event.type), [SyncUiEventType.resumed]);
        expect(await manager.processPendingItems(), isTrue);
        await Future<void>.value();
        expect(events.map((event) => event.type), [
          SyncUiEventType.resumed,
          SyncUiEventType.recoveryCompleted,
        ]);
      },
    );

    test(
      'drain requested during completion check preserves single-flight and FIFO',
      () async {
        final store = FakeSyncQueueStore([createSyncItem(attemptCount: 1)]);
        final started = Completer<void>();
        final release = Completer<void>();
        store.rejectionReadOperation = () async {
          store.rejectionReadOperation = null;
          started.complete();
          await release.future;
        };
        final events = <SyncUiEvent>[];
        final remote = FakeSyncRemoteDataSource(
          (_, _) async => const SyncOperationResult.success(),
        );
        final manager = _recordUiEvents(store, remote, events);

        final first = manager.processPendingItems();
        await started.future;
        store.items.add(createSyncItem(id: 2, docId: 'habit-2'));
        final second = manager.processPendingItems();
        expect(identical(first, second), isTrue);
        expect(events.map((event) => event.type), [SyncUiEventType.resumed]);
        release.complete();
        expect(await first, isTrue);
        expect(await second, isTrue);
        await Future<void>.value();

        expect(store.markedAsSynced, [1, 2]);
        expect(remote.processedItems, [
          'user-123:habits:habit-1:create',
          'user-123:habits:habit-2:create',
        ]);
        expect(events.map((event) => event.type), [
          SyncUiEventType.resumed,
          SyncUiEventType.recoveryCompleted,
        ]);
      },
    );

    test(
      'failed completion read cannot claim recoveryCompleted or change drain result',
      () async {
        final store = FakeSyncQueueStore([createSyncItem(attemptCount: 1)])
          ..rejectionReadFails = true;
        final events = <SyncUiEvent>[];
        final manager = _recordUiEvents(
          store,
          FakeSyncRemoteDataSource(
            (_, _) async => const SyncOperationResult.success(),
          ),
          events,
        );

        expect(await manager.processPendingItems(), isTrue);
        expect(events.map((event) => event.type), [SyncUiEventType.resumed]);
        store.rejectionReadFails = false;
        expect(await manager.processPendingItems(), isTrue);
        await Future<void>.value();
        expect(events.map((event) => event.type), [
          SyncUiEventType.resumed,
          SyncUiEventType.recoveryCompleted,
        ]);
      },
    );

    test(
      'broadcast supports multiple listeners and closes on dispose',
      () async {
        final events = <SyncUiEvent>[];
        final manager = _recordUiEvents(
          FakeSyncQueueStore([createSyncItem(attemptCount: 1)]),
          FakeSyncRemoteDataSource(
            (_, _) async => const SyncOperationResult.success(),
          ),
          events,
        );
        final secondEvents = <SyncUiEvent>[];
        final closed = Completer<void>();
        final subscription = manager.uiEvents.listen(
          secondEvents.add,
          onDone: closed.complete,
        );
        addTearDown(subscription.cancel);

        expect(await manager.processPendingItems(), isTrue);
        await Future<void>.value();
        expect(secondEvents.map((event) => event.type), [
          SyncUiEventType.resumed,
          SyncUiEventType.recoveryCompleted,
        ]);
        manager.dispose();
        await closed.future;
        expect(await manager.processPendingItems(), isFalse);
      },
    );

    test(
      'dispose during remote call prevents emission on the closed stream',
      () async {
        final started = Completer<void>();
        final release = Completer<void>();
        final events = <SyncUiEvent>[];
        final manager = _recordUiEvents(
          FakeSyncQueueStore([createSyncItem(attemptCount: 1)]),
          FakeSyncRemoteDataSource((_, _) async {
            started.complete();
            await release.future;
            return const SyncOperationResult.success();
          }),
          events,
        );
        final drain = manager.processPendingItems();
        await started.future;
        manager.dispose();
        release.complete();
        await drain;
        expect(events, isEmpty);
        expect(await manager.processPendingItems(), isFalse);
      },
    );
  });

  group('SyncManager safe local discard', () {
    test('pending success permits local discard', () async {
      final store = FakeSyncQueueStore([createSyncItem()]);
      final manager = SyncManager(
        queueStore: store,
        remoteDataSource: FakeSyncRemoteDataSource(
          (_, _) async => const SyncOperationResult.success(),
        ),
        currentUserId: () => 'user-123',
      );
      addTearDown(manager.dispose);

      expect(await manager.prepareForLocalDataDiscard(), isTrue);
      expect(store.markedAsSynced, [1]);
    });

    test('retryable pending blocks local discard', () async {
      final store = FakeSyncQueueStore([createSyncItem()]);
      final manager = SyncManager(
        queueStore: store,
        remoteDataSource: FakeSyncRemoteDataSource(
          (_, _) async => const SyncOperationResult.retryable(),
        ),
        currentUserId: () => 'user-123',
      );
      addTearDown(manager.dispose);

      expect(await manager.prepareForLocalDataDiscard(), isFalse);
      expect(store.retried, [1]);
      expect(store.markedAsSynced, isEmpty);
    });

    for (final testCase in <String, SyncOperationResult>{
      'quotaExceeded': const SyncOperationResult.quotaExceeded(),
      'permissionDenied': const SyncOperationResult.permissionDenied(),
      'invalidPayload': const SyncOperationResult.invalidPayload(),
      'unsupportedOperation': const SyncOperationResult.unsupportedOperation(),
    }.entries) {
      test('${testCase.key} blocks discard including second attempt', () async {
        final store = FakeSyncQueueStore([
          createSyncItem(),
          createSyncItem(id: 2, docId: 'habit-2'),
        ]);
        final remote = FakeSyncRemoteDataSource(
          (_, item) async => item.id == 1
              ? testCase.value
              : const SyncOperationResult.success(),
        );
        final manager = SyncManager(
          queueStore: store,
          remoteDataSource: remote,
          currentUserId: () => 'user-123',
        );
        addTearDown(manager.dispose);

        expect(await manager.prepareForLocalDataDiscard(), isFalse);
        expect(store.rejected, [1]);
        expect(store.markedAsSynced, [2]);
        expect(await manager.prepareForLocalDataDiscard(), isFalse);
        expect(store.cleanupRequests, hasLength(1));
        expect(remote.processedItems, hasLength(2));
        expect(await manager.processPendingItems(), isTrue);
        expect(remote.processedItems, hasLength(2));
      });
    }

    test(
      'old persisted rejection blocks discard before succeeded cleanup',
      () async {
        final db = AppDatabase(executor: NativeDatabase.memory());
        addTearDown(db.close);
        final id = await db.insertSyncItem(
          ownerUid: 'user-123',
          collection: 'habits',
          docId: 'habit-1',
          operationType: 'create',
          payloadJson: '{}',
          createdAt: 1,
        );
        await db.markSyncItemRejected(id, 'user-123', 'INVALID_PAYLOAD');
        await db.customStatement(
          'UPDATE sync_queue_table SET last_attempt_at = 1 WHERE id = ?',
          [id],
        );
        final remote = FakeSyncRemoteDataSource(
          (_, _) async => const SyncOperationResult.success(),
        );
        final manager = SyncManager(
          queueStore: AppDatabaseSyncQueueStore(db),
          remoteDataSource: remote,
          currentUserId: () => 'user-123',
        );
        addTearDown(manager.dispose);

        expect(await manager.prepareForLocalDataDiscard(), isFalse);
        expect(await manager.prepareForLocalDataDiscard(), isFalse);
        expect(await db.hasRejectedSyncItems('user-123'), isTrue);
        expect(await db.getSyncItemById(id), isNotNull);
        expect(remote.processedItems, isEmpty);
      },
    );

    test(
      'normal drain preserves old rejected, expires old succeeded and blocks future discard',
      () async {
        final db = AppDatabase(executor: NativeDatabase.memory());
        addTearDown(db.close);
        final ids = <String, int>{};
        for (final docId in ['rejected', 'succeeded', 'pending']) {
          ids[docId] = await db.insertSyncItem(
            ownerUid: 'user-a',
            collection: 'habits',
            docId: docId,
            operationType: 'create',
            payloadJson: '{}',
            createdAt: 1,
          );
        }
        await db.markSyncItemRejected(
          ids['rejected']!,
          'user-a',
          'INVALID_PAYLOAD',
        );
        await db.markSyncItemAsSucceeded(ids['succeeded']!, 'user-a');
        await db.customStatement(
          'UPDATE sync_queue_table SET last_attempt_at = 1 '
          'WHERE id IN (?, ?)',
          [ids['rejected']!, ids['succeeded']!],
        );
        final rejectionBefore = await db.getSyncItemById(ids['rejected']!);
        final remote = FakeSyncRemoteDataSource(
          (_, _) async => const SyncOperationResult.success(),
        );
        final manager = SyncManager(
          queueStore: AppDatabaseSyncQueueStore(db),
          remoteDataSource: remote,
          currentUserId: () => 'user-a',
        );
        addTearDown(manager.dispose);

        expect(await manager.processPendingItems(), isTrue);
        expect(
          await db.getSyncItemById(ids['rejected']!),
          equals(rejectionBefore),
        );
        expect(await db.hasRejectedSyncItems('user-a'), isTrue);
        expect(await db.getSyncItemById(ids['succeeded']!), isNull);
        final confirmed =
            await db.getSyncItemById(ids['pending']!) as SyncQueueTableData;
        expect(confirmed.status, SyncQueuePersistenceStatus.succeeded);
        expect(remote.processedItems, ['user-a:habits:pending:create']);

        expect(await manager.prepareForLocalDataDiscard(), isFalse);
        expect(await manager.prepareForLocalDataDiscard(), isFalse);
        expect(await manager.processPendingItems(), isTrue);
        expect(await db.hasRejectedSyncItems('user-a'), isTrue);
        expect(
          await db.getSyncItemById(ids['rejected']!),
          equals(rejectionBefore),
        );
        expect(remote.processedItems, ['user-a:habits:pending:create']);
      },
    );

    test(
      'persisted rejection of another owner does not block discard',
      () async {
        final db = AppDatabase(executor: NativeDatabase.memory());
        addTearDown(db.close);
        final id = await db.insertSyncItem(
          ownerUid: 'user-b',
          collection: 'habits',
          docId: 'habit-1',
          operationType: 'create',
          payloadJson: '{}',
        );
        await db.markSyncItemRejected(id, 'user-b', 'INVALID_PAYLOAD');
        final manager = SyncManager(
          queueStore: AppDatabaseSyncQueueStore(db),
          remoteDataSource: FakeSyncRemoteDataSource(
            (_, _) async => const SyncOperationResult.success(),
          ),
          currentUserId: () => 'user-a',
        );
        addTearDown(manager.dispose);

        expect(await manager.prepareForLocalDataDiscard(), isTrue);
        expect(await db.hasRejectedSyncItems('user-a'), isFalse);
        expect(await db.hasRejectedSyncItems('user-b'), isTrue);
      },
    );

    test('UID change during drain blocks local discard', () async {
      var uid = 'user-123';
      final started = Completer<void>();
      final release = Completer<void>();
      final store = FakeSyncQueueStore([createSyncItem()]);
      final manager = SyncManager(
        queueStore: store,
        remoteDataSource: FakeSyncRemoteDataSource((_, _) async {
          started.complete();
          await release.future;
          return const SyncOperationResult.success();
        }),
        currentUserId: () => uid,
      );
      addTearDown(manager.dispose);

      final discard = manager.prepareForLocalDataDiscard();
      await started.future;
      uid = 'user-b';
      release.complete();
      expect(await discard, isFalse);
      expect(store.markedAsSynced, isEmpty);
    });
  });

  group('SyncManager', () {
    test(
      'cleans succeeded once for current UID with seven-day cutoff before FIFO',
      () async {
        final store = FakeSyncQueueStore([]);
        final remote = FakeSyncRemoteDataSource(
          (_, _) async => const SyncOperationResult.success(),
        );
        final manager = SyncManager(
          queueStore: store,
          remoteDataSource: remote,
          currentUserId: () => ' user-a ',
        );
        addTearDown(manager.dispose);
        final before = DateTime.now()
            .subtract(const Duration(days: 7))
            .millisecondsSinceEpoch;

        expect(await manager.processPendingItems(), isTrue);

        final after = DateTime.now()
            .subtract(const Duration(days: 7))
            .millisecondsSinceEpoch;
        expect(store.cleanupRequests, hasLength(1));
        expect(store.cleanupRequests.single.$1, 'user-a');
        expect(
          store.cleanupRequests.single.$2,
          inInclusiveRange(before, after),
        );
        expect(store.events, ['cleanup:user-a', 'read:user-a']);
      },
    );

    test('cleanup failure does not block success or drain', () async {
      final store = FakeSyncQueueStore([createSyncItem()])..cleanupFails = true;
      final remote = FakeSyncRemoteDataSource(
        (_, _) async => const SyncOperationResult.success(),
      );
      final manager = SyncManager(
        queueStore: store,
        remoteDataSource: remote,
        currentUserId: () => 'user-123',
      );
      addTearDown(manager.dispose);

      expect(await manager.processPendingItems(), isTrue);
      expect(store.markedAsSynced, [1]);
      expect(store.retried, isEmpty);
      expect(store.cleanupRequests, hasLength(1));
      expect(store.events, ['cleanup:user-123', 'read:user-123']);
      expect(remote.processedItems, hasLength(1));
    });

    test(
      'UID change during cleanup does not clean or process new session',
      () async {
        var currentUid = 'user-a';
        final started = Completer<void>();
        final release = Completer<void>();
        final store = FakeSyncQueueStore([createSyncItem(ownerUid: 'user-a')]);
        store.cleanupOperation = () async {
          started.complete();
          await release.future;
        };
        final remote = FakeSyncRemoteDataSource(
          (_, _) async => const SyncOperationResult.success(),
        );
        final manager = SyncManager(
          queueStore: store,
          remoteDataSource: remote,
          currentUserId: () => currentUid,
        );
        addTearDown(manager.dispose);

        final processing = manager.processPendingItems();
        await started.future;
        currentUid = 'user-b';
        release.complete();

        expect(await processing, isFalse);
        expect(store.cleanupRequests.map((request) => request.$1), ['user-a']);
        expect(store.events, ['cleanup:user-a']);
        expect(remote.processedItems, isEmpty);
        expect(store.markedAsSynced, isEmpty);
      },
    );

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
      expect(store.cleanupRequests.single.$1, 'user-123');
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
      expect(store.cleanupRequests, isEmpty);
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
      expect(store.cleanupRequests.map((request) => request.$1), ['user-b']);
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
