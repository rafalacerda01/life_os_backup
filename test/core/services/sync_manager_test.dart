import 'dart:async';
import 'dart:io';
import 'package:drift/drift.dart' show Value;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/core/database/database_provider.dart';
import 'package:life_os/core/services/sync_manager_provider.dart';
import 'package:life_os/features/auth/presentation/providers/auth_provider.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:life_os/core/database/remote_send_permit.dart';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/services/sync_manager.dart';
import 'package:life_os/core/services/sync_operation_result.dart';
import 'package:life_os/core/services/sync_queue_store.dart';
import 'package:life_os/core/services/sync_remote_data_source.dart';
import 'package:life_os/core/services/sync_ui_event.dart';

// Synthetic Firestore boundary; the actual datasource and Manager are exercised.
class _P1Firestore extends Fake implements FirebaseFirestore {
  final data = <String, Map<String, dynamic>>{};
  final sends = <String>[];
  Object? beforeError;
  Object? afterError;
  Future<void> Function(String path)? beforeWrite;
  @override
  CollectionReference<Map<String, dynamic>> collection(String path) =>
      _P1Collection(this, path);
}

// SDK sealed interfaces are implemented only by this IO-free test fake.
// ignore: subtype_of_sealed_class
class _P1Collection extends Fake
    implements CollectionReference<Map<String, dynamic>> {
  final _P1Firestore owner;
  @override
  final String path;
  _P1Collection(this.owner, this.path);
  @override
  DocumentReference<Map<String, dynamic>> doc([String? path]) =>
      _P1Document(owner, '${this.path}/$path');
}

// SDK sealed interfaces are implemented only by this IO-free test fake.
// ignore: subtype_of_sealed_class
class _P1Document extends Fake
    implements DocumentReference<Map<String, dynamic>> {
  final _P1Firestore owner;
  @override
  final String path;
  _P1Document(this.owner, this.path);
  @override
  CollectionReference<Map<String, dynamic>> collection(String path) =>
      _P1Collection(owner, '${this.path}/$path');
  @override
  Future<void> update(Map<Object, Object?> data) =>
      set(data.cast<String, dynamic>(), SetOptions(merge: true));

  @override
  Future<void> set(Map<String, dynamic> data, [SetOptions? options]) async {
    owner.sends.add(path);
    await owner.beforeWrite?.call(path);
    final before = owner.beforeError;
    if (before != null) throw before;
    owner.data[path] = {...?owner.data[path], ...data};
    final after = owner.afterError;
    if (after != null) throw after;
  }
}

class _P1User extends Fake implements User {
  @override
  final String uid;
  _P1User(this.uid);
}

class _P1Auth extends Fake implements FirebaseAuth {
  String? uid;
  _P1Auth(this.uid);
  @override
  User? get currentUser => uid == null ? null : _P1User(uid!);
}

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
    _updateItem(
      id,
      ownerUid,
      SyncQueuePersistenceStatus.pending,
      false,
      errorCode: errorCode,
    );
    return 1;
  }

  void _updateItem(
    int id,
    String ownerUid,
    String status,
    bool isSynced, {
    String? errorCode,
  }) {
    final index = items.indexWhere(
      (item) => item.id == id && item.ownerUid == ownerUid,
    );
    if (index == -1) return;
    final item = items[index];
    items[index] = item.copyWith(
      status: status,
      isSynced: isSynced,
      attemptCount: item.attemptCount + 1,
      lastErrorCode: Value(errorCode ?? item.lastErrorCode),
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

class _UnusedFirestore extends Fake implements FirebaseFirestore {}

class _NoUserAuth extends Fake implements FirebaseAuth {
  @override
  User? get currentUser => null;
}

void main() {
  group('preserving session detach', () {
    testWidgets('aborted logout rearms retry for A only', (tester) async {
      final store = FakeSyncQueueStore([createSyncItem()]);
      var online = false;
      final remote = FakeSyncRemoteDataSource(
        (_, _) async => online
            ? const SyncOperationResult.success()
            : const SyncOperationResult.retryable(code: 'NETWORK_ERROR'),
      );
      final manager = SyncManager(
        queueStore: store,
        remoteDataSource: remote,
        currentUserId: () => 'user-123',
      );
      addTearDown(manager.dispose);
      await manager.processPendingItems();
      await manager.prepareForSessionDetach('user-123');
      await tester.pump(const Duration(seconds: 5));
      expect(remote.processedItems, hasLength(1));
      online = true;
      expect(manager.resumeForPreparedSession('user-123'), isTrue);
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(remote.processedItems, hasLength(2));
      expect(store.items.single.status, SyncQueuePersistenceStatus.succeeded);
    });

    test(
      'pause does not inspect, upload or discard pending/rejected rows',
      () async {
        final store = FakeSyncQueueStore([
          createSyncItem(),
          createSyncItem(id: 2, status: SyncQueuePersistenceStatus.rejected),
        ]);
        final before = List<SyncQueueTableData>.of(store.items);
        final remote = FakeSyncRemoteDataSource(
          (_, _) async => const SyncOperationResult.success(),
        );
        final manager = SyncManager(
          queueStore: store,
          remoteDataSource: remote,
          currentUserId: () => 'user-123',
        );
        addTearDown(manager.dispose);
        expect(await manager.prepareForSessionDetach('user-123'), isTrue);
        expect(await manager.processPendingItems(), isFalse);
        expect(store.items, before);
        expect(store.events, isEmpty);
        expect(remote.processedItems, isEmpty);
        expect(await manager.prepareForLocalDataDiscard(), isFalse);
      },
    );
    for (final result in [
      const SyncOperationResult.success(),
      const SyncOperationResult.retryable(code: 'NETWORK_ERROR'),
    ]) {
      test(
        'pause fences in-flight ${result.status.name} and stops next item',
        () async {
          final started = Completer<void>();
          final response = Completer<SyncOperationResult>();
          final store = FakeSyncQueueStore([
            createSyncItem(),
            createSyncItem(id: 2),
          ]);
          final before = List<SyncQueueTableData>.of(store.items);
          final remote = FakeSyncRemoteDataSource((_, _) {
            started.complete();
            return response.future;
          });
          final manager = SyncManager(
            queueStore: store,
            remoteDataSource: remote,
            currentUserId: () => 'user-123',
          );
          addTearDown(manager.dispose);
          final processing = manager.processPendingItems();
          await started.future;
          final detach = manager.prepareForSessionDetach('user-123');
          expect(await detach, isTrue);
          expect(await manager.processPendingItems(), isFalse);
          response.complete(result);
          expect(await processing, isFalse);
          expect(await detach, isTrue);
          expect(store.items, before);
          expect(remote.processedItems, hasLength(1));
        },
      );
    }
    test(
      'only the same prepared session resumes after an aborted logout',
      () async {
        String? uid = 'user-123';
        final store = FakeSyncQueueStore([createSyncItem()]);
        final remote = FakeSyncRemoteDataSource(
          (_, _) async => const SyncOperationResult.success(),
        );
        final manager = SyncManager(
          queueStore: store,
          remoteDataSource: remote,
          currentUserId: () => uid,
        );
        addTearDown(manager.dispose);
        expect(await manager.prepareForSessionDetach('other-user'), isFalse);
        expect(await manager.prepareForSessionDetach(uid), isTrue);
        uid = 'other-user';
        expect(manager.resumeForPreparedSession(uid), isFalse);
        expect(await manager.processPendingItems(), isFalse);
        uid = 'user-123';
        expect(manager.resumeForPreparedSession(uid), isTrue);
        expect(await manager.processPendingItems(), isTrue);
        expect(remote.processedItems.single, startsWith('user-123:'));
        expect(store.items.single.status, SyncQueuePersistenceStatus.succeeded);
      },
    );
    test('dispose fences a late same-UID remote result', () async {
      final started = Completer<void>();
      final response = Completer<SyncOperationResult>();
      final store = FakeSyncQueueStore([createSyncItem()]);
      final before = store.items.single;
      final remote = FakeSyncRemoteDataSource((_, _) {
        started.complete();
        return response.future;
      });
      final manager = SyncManager(
        queueStore: store,
        remoteDataSource: remote,
        currentUserId: () => 'user-123',
      );
      final processing = manager.processPendingItems();
      await started.future;
      manager.dispose();
      response.complete(const SyncOperationResult.success());
      expect(await processing, isFalse);
      expect(store.items.single, before);
      expect(manager.resumeForPreparedSession('user-123'), isFalse);
    });
    testWidgets('pause cancels A retry and old manager cannot run under B', (
      tester,
    ) async {
      String? uid = 'user-123';
      final store = FakeSyncQueueStore([createSyncItem()]);
      final remote = FakeSyncRemoteDataSource(
        (_, _) async =>
            const SyncOperationResult.retryable(code: 'NETWORK_ERROR'),
      );
      final manager = SyncManager(
        queueStore: store,
        remoteDataSource: remote,
        currentUserId: () => uid,
      );
      addTearDown(manager.dispose);
      await manager.processPendingItems();
      expect(remote.processedItems, hasLength(1));
      await manager.prepareForSessionDetach(uid);
      uid = 'user-b';
      await tester.pump(const Duration(minutes: 6));
      expect(await manager.processPendingItems(), isFalse);
      expect(remote.processedItems, hasLength(1));
      expect(store.items.single.ownerUid, 'user-123');
      expect(store.items.single.status, SyncQueuePersistenceStatus.pending);
    });
  });

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

        expect(store.markedAsSynced, [1]);
        expect(store.items.singleWhere((item) => item.id == water.id), water);
        expect(remote.processedItems, [
          'user-123:health_info:2026-08-21:update',
        ]);
        expect(await manager.processPendingItems(), isFalse);
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

        expect(remote.calls, 2);
        expect(store.markedAsSynced, [1]);
        expect(store.items.singleWhere((item) => item.id == water.id), water);
        expect(remote.firestoreDoc, {
          'mood': 'Radiante',
          'date': '2026-08-21T10:00:00.000Z',
        });
        expect(await manager.processPendingItems(), isFalse);
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

  group('Water V1 preservada sem bloquear módulos vivos', () {
    for (final mixed in [false, true]) {
      test(
        'fila ${mixed ? 'mista' : 'absoluta'} intacta, outros módulos progridem, descarte negado',
        () async {
          final db = AppDatabase(executor: NativeDatabase.memory());
          addTearDown(db.close);
          final payload = mixed
              ? '{"waterIntakeMl":1250,"mood":"Local","date":"2026-08-21T10:00:00.000Z"}'
              : '{ "waterIntakeMl" : 1250, "date" : "2026-08-21T10:00:00.000Z" }';
          final legacyId = await db.insertSyncItem(
            ownerUid: 'user-a',
            collection: 'health_info',
            docId: '2026-08-21',
            operationType: 'update',
            payloadJson: payload,
            createdAt: 1,
          );
          final before = await db.getSyncItemById(legacyId);
          for (final module in [
            'tasks',
            'habits',
            'transactions',
            'study_info',
          ]) {
            await db.insertSyncItem(
              ownerUid: 'user-a',
              collection: module,
              docId: module,
              operationType: 'update',
              payloadJson: '{}',
            );
          }
          for (final body in [
            {'mood': 'Focado'},
            {'hasTakenPillToday': true},
            {
              'menstrualCycle': {'isEnabled': true},
            },
          ]) {
            await db.insertSyncItem(
              ownerUid: 'user-a',
              collection: 'health_info',
              docId: '2026-08-21',
              operationType: 'update',
              payloadJson: jsonEncode(body),
            );
          }
          final remote = FakeSyncRemoteDataSource((_, item) async {
            expect(
              (jsonDecode(item.payloadJson) as Map).containsKey(
                'waterIntakeMl',
              ),
              isFalse,
            );
            return const SyncOperationResult.success();
          });
          final manager = SyncManager(
            queueStore: AppDatabaseSyncQueueStore(db),
            remoteDataSource: remote,
            currentUserId: () => 'user-a',
          );
          addTearDown(manager.dispose);
          final events = <SyncUiEvent>[];
          final subscription = manager.uiEvents.listen(events.add);
          addTearDown(subscription.cancel);
          expect(await manager.processPendingItems(), isFalse);
          expect(remote.processedItems, hasLength(7));
          expect(await db.getSyncItemById(legacyId), before);
          expect(await db.getPendingSyncItems('user-a'), [before]);
          expect(await db.hasRejectedSyncItems('user-a'), isFalse);
          expect(await manager.prepareForLocalDataDiscard(), isFalse);
          expect(await manager.processPendingItems(), isFalse);
          expect(remote.processedItems, hasLength(7));
          expect(await db.getSyncItemById(legacyId), before);
          expect(await db.select(db.waterV2Intents).get(), isEmpty);
          expect(await db.select(db.waterV2DailyStates).get(), isEmpty);
          expect(
            events.where((e) => e.type == SyncUiEventType.recoveryCompleted),
            isEmpty,
          );
        },
      );
    }
    test(
      'UID A-B-A e logout abortado não confirmam resposta antiga ou apagam água',
      () async {
        String? uid = 'user-a';
        final store = FakeSyncQueueStore([
          createSyncItem(
            id: 1,
            ownerUid: 'user-a',
            collection: 'health_info',
            payloadJson: '{"waterIntakeMl":1250}',
          ),
          createSyncItem(id: 2, ownerUid: 'user-a', collection: 'tasks'),
          createSyncItem(id: 3, ownerUid: 'user-b', collection: 'tasks'),
        ]);
        final legacy = store.items.first;
        final reached = Completer<void>();
        final late = Completer<SyncOperationResult>();
        var first = true;
        final remote = FakeSyncRemoteDataSource((_, item) {
          if (first) {
            first = false;
            reached.complete();
            return late.future;
          }
          return Future.value(const SyncOperationResult.success());
        });
        final manager = SyncManager(
          queueStore: store,
          remoteDataSource: remote,
          currentUserId: () => uid,
        );
        addTearDown(manager.dispose);
        final processing = manager.processPendingItems();
        await reached.future;
        expect(await manager.prepareForSessionDetach('user-a'), isTrue);
        uid = 'user-b';
        expect(manager.resumeForPreparedSession('user-a'), isFalse);
        uid = 'user-a';
        expect(manager.resumeForPreparedSession('user-a'), isTrue);
        late.complete(const SyncOperationResult.success());
        expect(await processing, isFalse);
        expect(store.markedAsSynced, isEmpty);
        expect(await manager.processPendingItems(), isFalse);
        expect(store.markedAsSynced, [2]);
        expect(store.items.first, legacy);
        expect(store.items.last.status, SyncQueuePersistenceStatus.pending);
        final managerB = SyncManager(
          queueStore: store,
          remoteDataSource: remote,
          currentUserId: () => 'user-b',
        );
        addTearDown(managerB.dispose);
        expect(await managerB.processPendingItems(), isTrue);
        expect(store.markedAsSynced, [2, 3]);
        expect(store.items.first, legacy);
      },
    );
  });
  test('normal provider wires Water V2 while deployment remains disabled', () {
    final db = AppDatabase(executor: NativeDatabase.memory());
    addTearDown(db.close);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        firestoreProvider.overrideWithValue(_UnusedFirestore()),
        firebaseAuthProvider.overrideWithValue(_NoUserAuth()),
      ],
    );
    addTearDown(container.dispose);
    expect(container.read(syncManagerProvider).waterV2Processor, isNotNull);
    expect(
      container.read(syncManagerProvider).waterV2Processor!.isEnabled,
      isFalse,
    );
  });

  group('P1 R5 pending persistence through the real datasource and Manager', () {
    const payload = '{ "currentValue": 1 }';
    Future<int> enqueue(AppDatabase db, String uid) => db.insertSyncItem(
      ownerUid: uid,
      collection: 'goals',
      docId: 'main',
      operationType: 'update',
      payloadJson: payload,
      createdAt: 1,
    );
    for (final code in ['permission-denied', 'unauthenticated']) {
      test(
        '$code retains A across session change, restart and independent B database',
        () async {
          final dbA = AppDatabase(executor: NativeDatabase.memory()),
              dbB = AppDatabase(executor: NativeDatabase.memory());
          addTearDown(dbA.close);
          addTearDown(dbB.close);
          final idA = await enqueue(dbA, 'uid-a'),
              idB = await enqueue(dbB, 'uid-b');
          final original = await dbA.getSyncItemById(idA);
          final auth = _P1Auth('uid-a');
          final firestore = _P1Firestore()
            ..beforeError = FirebaseException(
              plugin: 'cloud_firestore',
              code: code,
            );
          final source = FirestoreSyncRemoteDataSource(firestore, auth);
          final managerA = SyncManager(
            queueStore: AppDatabaseSyncQueueStore(dbA),
            remoteDataSource: source,
            currentUserId: () => auth.uid,
          );
          addTearDown(managerA.dispose);
          expect(await managerA.processPendingItems(), isFalse);
          final pending =
              (await dbA.getSyncItemById(idA))! as SyncQueueTableData;
          expect(pending.status, SyncQueuePersistenceStatus.pending);
          expect(pending.isSynced, isFalse);
          expect(pending.ownerUid, 'uid-a');
          expect(pending.docId, 'main');
          expect(pending.id, idA);
          expect(pending.payloadJson, payload);
          expect(pending.createdAt, (original as SyncQueueTableData).createdAt);
          expect(pending.attemptCount, 1);
          expect(pending.lastAttemptAt, isNotNull);
          expect(
            pending.lastErrorCode,
            code == 'permission-denied'
                ? 'FIRESTORE_PERMISSION_UNCONFIRMED'
                : 'AUTHENTICATION_REQUIRED',
          );
          expect(await dbA.hasRejectedSyncItems('uid-a'), isFalse);
          expect(await managerA.prepareForSessionDetach('uid-a'), isTrue);
          auth.uid = 'uid-b';
          firestore.beforeError = null;
          final managerB = SyncManager(
            queueStore: AppDatabaseSyncQueueStore(dbB),
            remoteDataSource: source,
            currentUserId: () => auth.uid,
          );
          addTearDown(managerB.dispose);
          expect(await managerB.processPendingItems(), isTrue);
          expect(
            (await dbB.getSyncItemById(idB)).status,
            SyncQueuePersistenceStatus.succeeded,
          );
          expect((await dbB.getSyncItemById(idB)).isSynced, isTrue);
          expect(await dbA.getSyncItemById(idA), pending);
          expect(await dbA.getPendingSyncItems('uid-b'), isEmpty);
          expect(firestore.data['users/uid-a/goals/main'], isNull);
          expect(firestore.data['users/uid-b/goals/main'], {'currentValue': 1});
          managerA.dispose();
          auth.uid = 'uid-a';
          final restarted = SyncManager(
            queueStore: AppDatabaseSyncQueueStore(dbA),
            remoteDataSource: source,
            currentUserId: () => auth.uid,
          );
          addTearDown(restarted.dispose);
          expect(await restarted.processPendingItems(), isTrue);
          final done = (await dbA.getSyncItemById(idA))! as SyncQueueTableData;
          expect(done.status, SyncQueuePersistenceStatus.succeeded);
          expect(done.isSynced, isTrue);
          expect(done.payloadJson, payload);
          expect(done.id, idA);
          expect(done.attemptCount, 2);
          expect(firestore.data['users/uid-b/goals/main'], {'currentValue': 1});
          expect(await dbB.getSyncItemById(idB), isNotNull);
        },
      );
    }
    test(
      'late successful SDK write after detach cannot ACK A or mutate B local queue',
      () async {
        final dbA = AppDatabase(executor: NativeDatabase.memory()),
            dbB = AppDatabase(executor: NativeDatabase.memory());
        addTearDown(dbA.close);
        addTearDown(dbB.close);
        final idA = await enqueue(dbA, 'uid-a'),
            idB = await enqueue(dbB, 'uid-b');
        final originalA = await dbA.getSyncItemById(idA),
            originalB = await dbB.getSyncItemById(idB);
        final auth = _P1Auth('uid-a'),
            reached = Completer<void>(),
            release = Completer<void>();
        final firestore = _P1Firestore()
          ..beforeWrite = (path) async {
            if (path.contains('/uid-a/')) {
              reached.complete();
              await release.future;
            }
          };
        final manager = SyncManager(
          queueStore: AppDatabaseSyncQueueStore(dbA),
          remoteDataSource: FirestoreSyncRemoteDataSource(firestore, auth),
          currentUserId: () => auth.uid,
        );
        addTearDown(manager.dispose);
        final processing = manager.processPendingItems();
        await reached.future;
        expect(await manager.prepareForSessionDetach('uid-a'), isTrue);
        auth.uid = 'uid-b';
        release.complete();
        expect(await processing, isFalse);
        await Future<void>.delayed(Duration.zero);
        expect(await dbA.getSyncItemById(idA), originalA);
        expect(await dbB.getSyncItemById(idB), originalB);
        expect((await dbA.getSyncItemById(idA)).isSynced, isFalse);
        expect(firestore.sends, ['users/uid-a/goals/main']);
      },
    );
    test(
      'unknown after-write result persists without ACK, stable replay then confirms',
      () async {
        final db = AppDatabase(executor: NativeDatabase.memory());
        addTearDown(db.close);
        final id = await enqueue(db, 'uid-a');
        final firestore = _P1Firestore()
          ..afterError = FirebaseException(
            plugin: 'cloud_firestore',
            code: 'deadline-exceeded',
          );
        final manager = SyncManager(
          queueStore: AppDatabaseSyncQueueStore(db),
          remoteDataSource: FirestoreSyncRemoteDataSource(
            firestore,
            _P1Auth('uid-a'),
          ),
          currentUserId: () => 'uid-a',
        );
        addTearDown(manager.dispose);
        expect(await manager.processPendingItems(), isFalse);
        final pending = (await db.getSyncItemById(id))! as SyncQueueTableData;
        expect(pending.status, SyncQueuePersistenceStatus.pending);
        expect(pending.isSynced, isFalse);
        expect(pending.payloadJson, payload);
        expect(pending.lastErrorCode, 'DEADLINE-EXCEEDED');
        expect(firestore.data.length, 1);
        firestore.afterError = null;
        expect(await manager.processPendingItems(), isTrue);
        final done = (await db.getSyncItemById(id))! as SyncQueueTableData;
        expect(done.status, SyncQueuePersistenceStatus.succeeded);
        expect(done.isSynced, isTrue);
        expect(done.id, id);
        expect(done.payloadJson, payload);
        expect(firestore.data.length, 1);
        expect(firestore.sends, hasLength(2));
      },
    );
    testWidgets(
      'ambiguous denial uses existing bounded delays, no tight loop or false ACK',
      (tester) async {
        final store = FakeSyncQueueStore([
          createSyncItem(
            collection: 'goals',
            docId: 'main',
            operationType: 'update',
            payloadJson: payload,
          ),
        ]);
        final remote = FakeSyncRemoteDataSource(
          (_, _) async => const SyncOperationResult.retryable(
            code: 'FIRESTORE_PERMISSION_UNCONFIRMED',
          ),
        );
        final manager = SyncManager(
          queueStore: store,
          remoteDataSource: remote,
          currentUserId: () => 'user-123',
        );
        expect(await manager.processPendingItems(), isFalse);
        for (final seconds in [5, 15, 30, 60, 300, 300]) {
          final calls = remote.processedItems.length;
          await tester.pump(Duration(seconds: seconds - 1));
          expect(remote.processedItems, hasLength(calls));
          await tester.pump(const Duration(seconds: 1));
          expect(remote.processedItems, hasLength(calls + 1));
          expect(store.items.single.status, SyncQueuePersistenceStatus.pending);
          expect(store.items.single.isSynced, isFalse);
          expect(store.items.single.payloadJson, payload);
        }
        expect(store.markedAsSynced, isEmpty);
        expect(store.rejected, isEmpty);
        manager.dispose();
        final calls = remote.processedItems.length;
        await tester.pump(const Duration(minutes: 10));
        expect(remote.processedItems, hasLength(calls));
      },
    );
    test(
      'review indeterminate result preserves pending queue and blocks destructive discard',
      () async {
        final db = AppDatabase(executor: NativeDatabase.memory());
        addTearDown(db.close);
        final id = await db.insertSyncItem(
          ownerUid: 'uid-a',
          collection: 'review_queue',
          docId: 'card-1',
          operationType: 'create',
          payloadJson:
              '{"subjectId":"s","question":"q","answer":"a","createdAt":"2026-10-28T00:00:00Z"}',
        );
        final original = await db.getSyncItemById(id);
        final remote = FakeSyncRemoteDataSource(
          (_, _) async => const SyncOperationResult.retryable(
            code: 'REVIEW_CREATE_UNCONFIRMED',
          ),
        );
        final manager = SyncManager(
          queueStore: AppDatabaseSyncQueueStore(db),
          remoteDataSource: remote,
          currentUserId: () => 'uid-a',
        );
        addTearDown(manager.dispose);
        expect(await manager.processPendingItems(), isFalse);
        expect(await manager.prepareForLocalDataDiscard(), isFalse);
        final row = (await db.getSyncItemById(id))! as SyncQueueTableData;
        expect(row.status, SyncQueuePersistenceStatus.pending);
        expect(row.isSynced, isFalse);
        expect(row.id, id);
        expect(row.payloadJson, (original as SyncQueueTableData).payloadJson);
        expect(await db.hasRejectedSyncItems('uid-a'), isFalse);
        expect(await db.getPendingSyncItems('uid-a'), hasLength(1));
      },
    );
  });
  group('ReviewQueue v1 ACK transport through actual Manager', () {
    Map<String, dynamic> payload() => {
      'creationProtocolVersion': 1,
      'cardId': 'card-1',
      'subjectId': 'subject-1',
      'question': 'Q',
      'answer': 'A',
      'createdAt': '2026-10-28T12:34:56.123456Z',
    };
    Map<String, dynamic> ack() => {
      'success': true,
      'operation': 'create_review_card',
      'version': 1,
      'uid': 'uid-a',
      'operationId': 'card-1',
      'fingerprint':
          'd3ee2953c47ce71eb071d3e27447c1689359ff7c913c8666329991efce20ca99',
      'outcome': 'REPLAYED',
      'effectsCommitted': true,
    };
    for (final mode in [
      'valid',
      'invalid-ack',
      'legacy',
      'fingerprint-conflict',
      'deletion-blocked',
      'timeout',
      'terminal-403',
    ])
      test('$mode preserves FIFO identity and correct status', () async {
        final db = AppDatabase(executor: NativeDatabase.memory());
        addTearDown(db.close);
        final original = payload();
        if (mode == 'legacy') original.remove('creationProtocolVersion');
        final id = await db.insertSyncItem(
          ownerUid: 'uid-a',
          collection: 'review_queue',
          docId: 'card-1',
          operationType: 'create',
          payloadJson: jsonEncode(original),
        );
        final second = await db.insertSyncItem(
          ownerUid: 'uid-a',
          collection: 'review_queue',
          docId: 'card-2',
          operationType: 'create',
          payloadJson: jsonEncode({...payload(), 'cardId': 'card-2'}),
        );
        final firestore = _P1Firestore();
        var calls = 0;
        final source = FirestoreSyncRemoteDataSource(
          firestore,
          _P1Auth('uid-a'),
          captureRemoteSend: (_) => RemoteSendPermit(() => true),
          idTokenProvider: (_, _) async => 'synthetic',
          appCheckTokenProvider: () async => 'synthetic',
          clientFactory: () => MockClient((request) async {
            calls++;
            expect(
              jsonDecode(request.body)['cardId'],
              mode == 'valid' && calls > 1 ? 'card-2' : 'card-1',
            );
            if (mode == 'timeout') throw TimeoutException('synthetic');
            if (mode == 'terminal-403')
              return http.Response('{"code":"PERMISSION_DENIED"}', 403);
            if (mode == 'fingerprint-conflict')
              return http.Response(
                '{"code":"REVIEW_CREATE_FINGERPRINT_CONFLICT"}',
                409,
              );
            if (mode == 'deletion-blocked')
              return http.Response('{"code":"ACCOUNT_DELETION_BLOCKED"}', 503);
            if (mode == 'invalid-ack') return http.Response('{}', 200);
            return http.Response(jsonEncode(ack()), 200);
          }),
        );
        final manager = SyncManager(
          queueStore: AppDatabaseSyncQueueStore(db),
          remoteDataSource: source,
          currentUserId: () => 'uid-a',
        );
        addTearDown(manager.dispose);
        await manager.processPendingItems();
        final row = (await db.getSyncItemById(id))! as SyncQueueTableData;
        expect(row.id, id);
        expect(row.docId, 'card-1');
        expect(row.ownerUid, 'uid-a');
        expect(row.payloadJson, jsonEncode(original));
        expect(
          row.status,
          mode == 'valid'
              ? SyncQueuePersistenceStatus.succeeded
              : mode == 'terminal-403'
              ? SyncQueuePersistenceStatus.rejected
              : SyncQueuePersistenceStatus.pending,
        );
        expect(row.isSynced, mode == 'valid');
        expect(firestore.sends, isEmpty);
        expect(firestore.data, isEmpty);
        if (mode != 'valid' && mode != 'terminal-403') {
          expect(calls, mode == 'legacy' ? 0 : 1);
          expect(
            (await db.getSyncItemById(second) as SyncQueueTableData)
                .attemptCount,
            0,
          );
          expect(await manager.prepareForLocalDataDiscard(), isFalse);
        }
      });
    test(
      'actual Manager detach invalidates late v1 ACK; same UID remains pending',
      () async {
        final db = AppDatabase(executor: NativeDatabase.memory());
        addTearDown(db.close);
        final id = await db.insertSyncItem(
          ownerUid: 'uid-a',
          collection: 'review_queue',
          docId: 'card-1',
          operationType: 'create',
          payloadJson: jsonEncode(payload()),
        );
        final reached = Completer<void>(), release = Completer<void>();
        final source = FirestoreSyncRemoteDataSource(
          _P1Firestore(),
          _P1Auth('uid-a'),
          captureRemoteSend: (_) => RemoteSendPermit(() => true),
          idTokenProvider: (_, _) async => 'synthetic',
          appCheckTokenProvider: () async => 'synthetic',
          clientFactory: () => MockClient((_) async {
            reached.complete();
            await release.future;
            return http.Response(jsonEncode(ack()), 200);
          }),
        );
        final manager = SyncManager(
          queueStore: AppDatabaseSyncQueueStore(db),
          remoteDataSource: source,
          currentUserId: () => 'uid-a',
        );
        addTearDown(manager.dispose);
        final execution = manager.processPendingItems();
        await reached.future;
        final detached = manager.prepareForSessionDetach('uid-a');
        release.complete();
        await execution;
        expect(await detached, isTrue);
        final row = (await db.getSyncItemById(id))! as SyncQueueTableData;
        expect(row.status, SyncQueuePersistenceStatus.pending);
        expect(row.isSynced, isFalse);
        expect(row.payloadJson, jsonEncode(payload()));
        expect(row.ownerUid, 'uid-a');
        expect(row.id, id);
      },
    );
    testWidgets(
      'new recovery code uses existing backoff and never advances FIFO',
      (tester) async {
        final first = createSyncItem(
          id: 1,
          ownerUid: 'uid-a',
          collection: 'review_queue',
          docId: 'card-1',
          payloadJson: jsonEncode(payload()),
        );
        final second = createSyncItem(
          id: 2,
          ownerUid: 'uid-a',
          collection: 'review_queue',
          docId: 'card-2',
          payloadJson: jsonEncode({...payload(), 'cardId': 'card-2'}),
        );
        final store = FakeSyncQueueStore([first, second]);
        final remote = FakeSyncRemoteDataSource((_, item) async {
          expect(item.id, 1);
          return const SyncOperationResult.retryable(
            code: 'REVIEW_CREATE_ACK_INVALID',
          );
        });
        final manager = SyncManager(
          queueStore: store,
          remoteDataSource: remote,
          currentUserId: () => 'uid-a',
        );
        await manager.processPendingItems();
        expect(remote.processedItems, hasLength(1));
        for (final seconds in [5, 15, 30, 60, 300, 300]) {
          final calls = remote.processedItems.length;
          await tester.pump(Duration(seconds: seconds - 1));
          expect(remote.processedItems, hasLength(calls));
          await tester.pump(const Duration(seconds: 1));
          expect(remote.processedItems, hasLength(calls + 1));
          expect(store.items.first.payloadJson, first.payloadJson);
          expect(store.items.first.docId, 'card-1');
        }
        expect(store.markedAsSynced, isEmpty);
        expect(store.rejected, isEmpty);
        manager.dispose();
      },
    );
  });
  group('S2 StudyInfo retention and persistent HOLD', () {
    const rawPayload = '  { "reviewQueue" : 9, "historical" : true }\n';
    Future<int> row(
      AppDatabase db, {
      String uid = 'uid-a',
      String collection = 'study_info',
      String docId = 'main',
      String operation = 'update',
      String status = SyncQueuePersistenceStatus.pending,
      int createdAt = 1,
      int? lastAttemptAt = 1,
      int attempts = 7,
      String? error = 'HISTORICAL_UNCONFIRMED',
    }) => db
        .into(db.syncQueueTable)
        .insert(
          SyncQueueTableCompanion.insert(
            ownerUid: Value(uid),
            collection: collection,
            docId: docId,
            operationType: operation,
            payloadJson: rawPayload,
            createdAt: createdAt,
            status: Value(status),
            isSynced: Value(status == SyncQueuePersistenceStatus.succeeded),
            attemptCount: Value(attempts),
            lastAttemptAt: Value(lastAttemptAt),
            lastErrorCode: Value(error),
          ),
        );
    const cutoff = 100000000;

    for (final operation in ['create', 'update']) {
      for (final lastAttempt in <int?>[null, 1]) {
        test(
          'SQL retains old $operation succeeded with lastAttempt=$lastAttempt byte for byte',
          () async {
            final db = AppDatabase(executor: NativeDatabase.memory());
            addTearDown(db.close);
            final id = await row(
              db,
              operation: operation,
              status: SyncQueuePersistenceStatus.succeeded,
              lastAttemptAt: lastAttempt,
            );
            final original = await db.getSyncItemById(id);
            expect(await db.cleanupSucceededSyncItems('uid-a', cutoff), 0);
            expect(await db.cleanupSucceededSyncItems('uid-a', cutoff), 0);
            expect(await db.getSyncItemById(id), original);
            expect((await db.getSyncItemById(id)).payloadJson, rawPayload);
          },
        );
      }
    }
    test(
      'SQL trim agrees with datasource Dart trim for whitespace and literal non-whitespace',
      () async {
        final db = AppDatabase(executor: NativeDatabase.memory());
        addTearDown(db.close);
        // Includes runtime-dependent NEL and formerly whitespace U+180E;
        // zero-width space and ASCII punctuation must NOT be silently trimmed.
        final codePoints = [
          0x09,
          0x0a,
          0x0b,
          0x0c,
          0x0d,
          0x20,
          0x85,
          0xa0,
          0x1680,
          0x180e,
          ...List.generate(11, (i) => 0x2000 + i),
          0x2028,
          0x2029,
          0x202f,
          0x205f,
          0x3000,
          0xfeff,
          0x200b,
          0x2e,
        ];
        for (final cp in codePoints) {
          final space = String.fromCharCode(cp);
          for (final operation in ['CrEaTe', 'uPdAtE']) {
            final id = await row(
              db,
              collection: '${space}study_info$space',
              docId: '${space}main$space',
              operation: '$space$operation$space',
              status: SyncQueuePersistenceStatus.succeeded,
            );
            final original =
                (await db.getSyncItemById(id))! as SyncQueueTableData;
            final held = space.trim().isEmpty;
            expect(LegacyStudyInfoOperation.isBlocked(original), held);
            await db.cleanupSucceededSyncItems('uid-a', cutoff);
            expect(
              await db.getSyncItemById(id),
              held ? original : null,
              reason: 'codepoint $cp/$operation',
            );
          }
        }
      },
    );
    for (final spec in [
      ('study_info', 'other', 'update'),
      ('study_info', 'MAIN', 'create'),
      ('study_info', 'main', 'delete'),
      ('study_info', 'main', 'batch_delete'),
      ('Study_info', 'main', 'update'),
      ('habits', 'habit-1', 'create'),
      ('transactions', 'finance-1', 'create'),
      ('tasks', 'task-1', 'update'),
      ('focus_logs', 'focus-1', 'create'),
      ('review_queue', 'card-1', 'create'),
    ]) {
      test(
        'SQL still expires old succeeded ${spec.$1}/${spec.$2}/${spec.$3}',
        () async {
          final db = AppDatabase(executor: NativeDatabase.memory());
          addTearDown(db.close);
          final id = await row(
            db,
            collection: spec.$1,
            docId: spec.$2,
            operation: spec.$3,
            status: SyncQueuePersistenceStatus.succeeded,
          );
          expect(await db.cleanupSucceededSyncItems('uid-a', cutoff), 1);
          expect(await db.getSyncItemById(id), isNull);
        },
      );
    }
    test(
      'SQL keeps original Health, recent success, rejected, pending, other UID and date rules',
      () async {
        final db = AppDatabase(executor: NativeDatabase.memory());
        addTearDown(db.close);
        final preserved = <int>[];
        preserved.add(
          await row(
            db,
            collection: 'health_info',
            docId: 'day',
            status: SyncQueuePersistenceStatus.succeeded,
          ),
        );
        preserved.add(
          await row(
            db,
            collection: 'tasks',
            docId: 'recent',
            status: SyncQueuePersistenceStatus.succeeded,
            createdAt: cutoff + 1,
            lastAttemptAt: null,
          ),
        );
        preserved.add(
          await row(
            db,
            collection: 'tasks',
            docId: 'recent-attempt',
            status: SyncQueuePersistenceStatus.succeeded,
            lastAttemptAt: cutoff + 1,
          ),
        );
        preserved.add(
          await row(db, status: SyncQueuePersistenceStatus.rejected),
        );
        preserved.add(await row(db));
        preserved.add(
          await row(
            db,
            uid: 'uid-b',
            collection: 'habits',
            status: SyncQueuePersistenceStatus.succeeded,
          ),
        );
        final originals = await Future.wait(preserved.map(db.getSyncItemById));
        final expired = await row(
          db,
          collection: 'habits',
          status: SyncQueuePersistenceStatus.succeeded,
          lastAttemptAt: null,
        );
        expect(await db.cleanupSucceededSyncItems('uid-a', cutoff), 1);
        expect(await db.getSyncItemById(expired), isNull);
        expect(await Future.wait(preserved.map(db.getSyncItemById)), originals);
        expect(await db.cleanupSucceededSyncItems('uid-a', cutoff), 0);
        expect(await Future.wait(preserved.map(db.getSyncItemById)), originals);
      },
    );
    for (final operation in ['create', 'update']) {
      test(
        'Manager preserves $operation HOLD, later FIFO and metadata while maintaining other succeeded',
        () async {
          final db = AppDatabase(executor: NativeDatabase.memory());
          addTearDown(db.close);
          final history = await row(
            db,
            status: SyncQueuePersistenceStatus.succeeded,
            operation: operation,
          );
          final rejected = await row(
            db,
            status: SyncQueuePersistenceStatus.rejected,
            operation: operation,
          );
          final earlier = await row(
            db,
            collection: 'tasks',
            docId: 'before',
            attempts: 0,
          );
          final head = await row(db, operation: operation);
          final later = await row(
            db,
            collection: 'tasks',
            docId: 'after',
            attempts: 0,
          );
          final other = await row(
            db,
            uid: 'uid-b',
            collection: 'tasks',
            docId: 'other',
            attempts: 0,
          );
          final expired = await row(
            db,
            collection: 'habits',
            status: SyncQueuePersistenceStatus.succeeded,
          );
          final ids = [history, rejected, head, later, other];
          final originals = await Future.wait(ids.map(db.getSyncItemById));
          final remote = FakeSyncRemoteDataSource(
            (_, _) async => const SyncOperationResult.success(),
          );
          final manager = SyncManager(
            queueStore: AppDatabaseSyncQueueStore(db),
            remoteDataSource: remote,
            currentUserId: () => 'uid-a',
          );
          addTearDown(manager.dispose);
          expect(await manager.processPendingItems(), isFalse);
          expect(
            (await db.getSyncItemById(earlier)).status,
            SyncQueuePersistenceStatus.succeeded,
          );
          expect(await db.getSyncItemById(expired), isNull);
          expect(remote.processedItems, ['uid-a:tasks:before:update']);
          for (var n = 0; n < 3; n++)
            expect(await manager.processPendingItems(), isFalse);
          expect(await manager.prepareForLocalDataDiscard(), isFalse);
          expect(await Future.wait(ids.map(db.getSyncItemById)), originals);
          expect(remote.processedItems, hasLength(1));
          expect((await db.getPendingSyncItems('uid-a')).map((x) => x.id), [
            head,
            later,
          ]);
          expect(await manager.prepareForSessionDetach('uid-a'), isTrue);
        },
      );
    }
    testWidgets(
      'local HOLD has no send, retry timer, fake attempt or manual bypass',
      (tester) async {
        final head =
            createSyncItem(
              collection: 'study_info',
              docId: 'main',
              operationType: 'update',
              payloadJson: rawPayload,
              attemptCount: 11,
            ).copyWith(
              lastAttemptAt: const Value(123),
              lastErrorCode: const Value('EXISTING_CODE'),
            );
        final later = createSyncItem(id: 2);
        final store = FakeSyncQueueStore([head, later]);
        final remote = FakeSyncRemoteDataSource(
          (_, _) async => const SyncOperationResult.success(),
        );
        final manager = SyncManager(
          queueStore: store,
          remoteDataSource: remote,
          currentUserId: () => 'user-123',
        );
        addTearDown(manager.dispose);
        final events = <SyncUiEvent>[];
        final subscription = manager.uiEvents.listen(events.add);
        addTearDown(subscription.cancel);
        expect(await manager.processPendingItems(), isFalse);
        final reads = store.events.length;
        await tester.pump(const Duration(hours: 1));
        expect(store.events, hasLength(reads));
        expect(await manager.processPendingItems(), isFalse);
        expect(
          await Future.wait([
            manager.processPendingItems(),
            manager.processPendingItems(),
          ]),
          [false, false],
        );
        expect(store.items, [head, later]);
        expect(store.markedAsSynced, isEmpty);
        expect(store.retried, isEmpty);
        expect(store.rejected, isEmpty);
        expect(remote.processedItems, isEmpty);
        expect(events, isEmpty);
      },
    );
    test(
      'persisted HOLD survives database reopen, manager restart, A-B-A and closed SQLite',
      () async {
        // Dedicated synthetic SQLite files retained in this runner's empty TEMP.
        final folder = await Directory.systemTemp.createTemp('s2-study-hold-');
        final fileA = File('${folder.path}/a.sqlite'),
            fileB = File('${folder.path}/b.sqlite');
        var dbA = AppDatabase(executor: NativeDatabase(fileA));
        final dbB = AppDatabase(executor: NativeDatabase(fileB));
        addTearDown(dbB.close);
        final idA = await row(
          dbA,
          attempts: 0,
          error: null,
          lastAttemptAt: null,
        );
        final afterA = await row(
          dbA,
          collection: 'tasks',
          docId: 'after-a',
          attempts: 0,
        );
        final idB = await row(
          dbB,
          uid: 'uid-b',
          collection: 'tasks',
          docId: 'b',
          attempts: 0,
        );
        final originalA = await dbA.getSyncItemById(idA),
            originalAfter = await dbA.getSyncItemById(afterA);
        var uid = 'uid-a';
        final remote = FakeSyncRemoteDataSource(
          (_, _) async => const SyncOperationResult.success(),
        );
        final first = SyncManager(
          queueStore: AppDatabaseSyncQueueStore(dbA),
          remoteDataSource: remote,
          currentUserId: () => uid,
        );
        expect(await first.processPendingItems(), isFalse);
        expect(await first.prepareForSessionDetach('uid-a'), isTrue);
        first.dispose();
        await dbA.close();
        uid = 'uid-b';
        final b = SyncManager(
          queueStore: AppDatabaseSyncQueueStore(dbB),
          remoteDataSource: remote,
          currentUserId: () => uid,
        );
        addTearDown(b.dispose);
        expect(await b.processPendingItems(), isTrue);
        final confirmedB = await dbB.getSyncItemById(idB);
        expect(confirmedB.status, SyncQueuePersistenceStatus.succeeded);
        expect(await b.prepareForSessionDetach('uid-b'), isTrue);
        uid = 'uid-a';
        dbA = AppDatabase(executor: NativeDatabase(fileA));
        final restarted = SyncManager(
          queueStore: AppDatabaseSyncQueueStore(dbA),
          remoteDataSource: remote,
          currentUserId: () => uid,
        );
        addTearDown(restarted.dispose);
        expect(await restarted.processPendingItems(), isFalse);
        expect(await dbA.getSyncItemById(idA), originalA);
        expect(await dbA.getSyncItemById(afterA), originalAfter);
        expect(await dbB.getSyncItemById(idB), confirmedB);
        expect(remote.processedItems, ['uid-b:tasks:b:update']);
        await dbA.close();
        expect(
          await restarted.processPendingItems(),
          isFalse,
        ); // closed SQLite is never success
        final verified = AppDatabase(executor: NativeDatabase(fileA));
        addTearDown(verified.close);
        expect(await verified.getSyncItemById(idA), originalA);
        expect(await verified.getSyncItemById(afterA), originalAfter);
      },
    );
  });
  group('F01 persistent HOLD through transport Manager and SQLite', () {
    const reviewCode = 'STUDY_REVIEW_STATE_INVALID';
    const deleteCode = 'STUDY_REVIEW_QUEUE_STATE_INVALID';
    Future<int> row(
      AppDatabase db, {
      bool deleting = false,
      String uid = 'uid-a',
      String status = SyncQueuePersistenceStatus.pending,
      String? code,
    }) => db
        .into(db.syncQueueTable)
        .insert(
          SyncQueueTableCompanion.insert(
            ownerUid: Value(uid),
            collection: deleting ? 'subjects' : 'review_queue',
            docId: deleting ? 'subject-1' : 'card-1',
            operationType: deleting ? 'delete' : 'update',
            payloadJson: deleting
                ? '{}'
                : jsonEncode({
                    'subjectId': 'subject-1',
                    'lastReviewed': '2026-10-29T12:00:00.000Z',
                    'timeZoneOffsetMinutes': -180,
                  }),
            createdAt: 1,
            status: Value(status),
            lastErrorCode: Value(code),
          ),
        );
    for (final deleting in [false, true]) {
      final code = deleting ? deleteCode : reviewCode;
      test(
        '$code remains pending with one real attempt across restart, preserves FIFO and owner',
        () async {
          final folder = Directory.systemTemp.createTempSync('f01-409-');
          final file = File('${folder.path}/queue.sqlite');
          var db = AppDatabase(executor: NativeDatabase(file));
          final head = await row(db, deleting: deleting);
          final later = await row(db, deleting: !deleting);
          final other = await row(db, uid: 'uid-b');
          final originalHead = await db.getSyncItemById(head);
          final originalLater = await db.getSyncItemById(later);
          final originalOther = await db.getSyncItemById(other);
          var sends = 0;
          final source = FirestoreSyncRemoteDataSource(
            _P1Firestore(),
            _P1Auth('uid-a'),
            captureRemoteSend: (_) => RemoteSendPermit(() => true),
            clientFactory: () => MockClient((request) async {
              sends++;
              expect(
                jsonDecode(request.body)['operation'],
                deleting ? 'delete_subject' : 'apply_study_review',
              );
              return http.Response(
                jsonEncode({'code': code, 'error': 'private-detail'}),
                409,
              );
            }),
            idTokenProvider: (_, _) async => 'synthetic-token',
            appCheckTokenProvider: () async => 'synthetic-app-check',
          );
          SyncManager manager() => SyncManager(
            queueStore: AppDatabaseSyncQueueStore(db),
            remoteDataSource: source,
            currentUserId: () => 'uid-a',
          );
          var m = manager();
          final events = <SyncUiEvent>[];
          var subscription = m.uiEvents.listen(events.add);
          expect(await m.processPendingItems(), isFalse);
          final held = await db.getSyncItemById(head);
          expect(held.status, SyncQueuePersistenceStatus.pending);
          expect(held.isSynced, isFalse);
          expect(held.lastErrorCode, code);
          expect(held.attemptCount, 1);
          expect(held.lastAttemptAt, isNotNull);
          expect(held.payloadJson, originalHead.payloadJson);
          expect(held.docId, originalHead.docId);
          expect(held.ownerUid, originalHead.ownerUid);
          expect(held.operationType, originalHead.operationType);
          expect(held.createdAt, originalHead.createdAt);
          for (var n = 0; n < 3; n++)
            expect(await m.processPendingItems(), isFalse);
          expect(await m.prepareForLocalDataDiscard(), isFalse);
          expect(await db.getSyncItemById(head), held);
          expect(await db.getSyncItemById(later), originalLater);
          expect(await db.getSyncItemById(other), originalOther);
          expect(events, isEmpty);
          await subscription.cancel();
          m.dispose();
          await db.close();
          db = AppDatabase(executor: NativeDatabase(file));
          m = manager();
          subscription = m.uiEvents.listen(events.add);
          expect(await m.processPendingItems(), isFalse);
          expect(await db.getSyncItemById(head), held);
          expect(await db.getSyncItemById(later), originalLater);
          expect(await db.getSyncItemById(other), originalOther);
          expect((await db.getPendingSyncItems('uid-a')).map((x) => x.id), [
            head,
            later,
          ]);
          expect(await m.prepareForSessionDetach('uid-a'), isTrue);
          expect(sends, 1);
          expect(events, isEmpty);
          await subscription.cancel();
          m.dispose();
          await db.close();
        },
      );
      testWidgets(
        '$code has no automatic resend, fake attempts or A-B-A bypass',
        (tester) async {
          var uid = 'user-123';
          final head = createSyncItem(
            collection: deleting ? 'subjects' : 'review_queue',
            operationType: deleting ? 'delete' : 'update',
          );
          final later = createSyncItem(id: 2);
          final b = createSyncItem(id: 3, ownerUid: 'uid-b');
          final store = FakeSyncQueueStore([head, later, b]);
          final remote = FakeSyncRemoteDataSource(
            (_, item) async => item.id == 1
                ? SyncOperationResult.retryable(code: code)
                : const SyncOperationResult.success(),
          );
          final m = SyncManager(
            queueStore: store,
            remoteDataSource: remote,
            currentUserId: () => uid,
          );
          addTearDown(m.dispose);
          final first = m.processPendingItems(),
              coalesced = m.processPendingItems();
          expect(await first, isFalse);
          expect(await coalesced, isFalse);
          final held = store.items.first;
          expect(held.lastErrorCode, code);
          expect(held.attemptCount, 1);
          await tester.pump(const Duration(hours: 24));
          expect(remote.processedItems, hasLength(1));
          expect(await m.prepareForSessionDetach(uid), isTrue);
          expect(m.resumeForPreparedSession(uid), isTrue);
          await tester.pump(const Duration(seconds: 6));
          expect(store.items.first, held);
          uid = 'uid-b';
          expect(await m.processPendingItems(), isTrue);
          uid = 'user-123';
          expect(await m.processPendingItems(), isFalse);
          await tester.pump(const Duration(hours: 24));
          expect(store.items.first, held);
          expect(store.items[1], later);
          expect(remote.processedItems, hasLength(2));
          expect(store.rejected, isEmpty);
          expect(store.retried, [1]);
        },
      );
      test(
        '$code historical rejection stays unchanged while unrelated pending work drains',
        () async {
          final db = AppDatabase(executor: NativeDatabase.memory());
          addTearDown(db.close);
          final rejected = await row(
            db,
            deleting: deleting,
            status: SyncQueuePersistenceStatus.rejected,
            code: 'INVALID_PAYLOAD',
          );
          final before = await db.getSyncItemById(rejected);
          final next = await row(db, deleting: !deleting);
          final remote = FakeSyncRemoteDataSource(
            (_, _) async => const SyncOperationResult.success(),
          );
          final m = SyncManager(
            queueStore: AppDatabaseSyncQueueStore(db),
            remoteDataSource: remote,
            currentUserId: () => 'uid-a',
          );
          addTearDown(m.dispose);
          expect(await m.processPendingItems(), isTrue);
          expect(await db.getSyncItemById(rejected), before);
          expect(
            (await db.getSyncItemById(next)).status,
            SyncQueuePersistenceStatus.succeeded,
          );
          expect(remote.processedItems, hasLength(1));
        },
      );
      test(
        '$code late HTTP response after logout cannot persist or ACK in returning A session',
        () async {
          final db = AppDatabase(executor: NativeDatabase.memory());
          addTearDown(db.close);
          final id = await row(db, deleting: deleting), later = await row(db);
          final before = await db.getSyncItemById(id),
              after = await db.getSyncItemById(later);
          final entered = Completer<void>(), release = Completer<void>();
          final auth = _P1Auth('uid-a');
          var uid = 'uid-a', sends = 0;
          final source = FirestoreSyncRemoteDataSource(
            _P1Firestore(),
            auth,
            captureRemoteSend: (_) => RemoteSendPermit(() => true),
            clientFactory: () => MockClient((_) async {
              sends++;
              entered.complete();
              await release.future;
              return http.Response(jsonEncode({'code': code}), 409);
            }),
            idTokenProvider: (_, _) async => 'synthetic-token',
            appCheckTokenProvider: () async => 'synthetic-app-check',
          );
          final m = SyncManager(
            queueStore: AppDatabaseSyncQueueStore(db),
            remoteDataSource: source,
            currentUserId: () => uid,
          );
          addTearDown(m.dispose);
          final drain = m.processPendingItems();
          await entered.future;
          expect(await m.prepareForSessionDetach('uid-a'), isTrue);
          expect(await drain, isFalse);
          uid = 'uid-b';
          auth.uid = uid;
          uid = 'uid-a';
          auth.uid = uid;
          release.complete();
          await Future<void>.delayed(Duration.zero);
          expect(await db.getSyncItemById(id), before);
          expect(await db.getSyncItemById(later), after);
          expect(sends, 1);
          expect(await m.processPendingItems(), isFalse);
        },
      );
    }
  });
}
