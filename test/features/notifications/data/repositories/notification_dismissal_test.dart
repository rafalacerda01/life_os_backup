// ignore_for_file: subtype_of_sealed_class
import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Value;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/app_database.dart' hide Transaction;
import 'package:life_os/core/database/local_mutation_gate.dart';
import 'package:life_os/core/database/session_database_coordinator.dart';
import 'package:life_os/core/services/notification_preferences.dart';
import 'package:life_os/core/services/sync_manager.dart';
import 'package:life_os/core/services/sync_queue_store.dart';
import 'package:life_os/core/services/sync_remote_data_source.dart';
import 'package:life_os/core/services/sync_operation_result.dart';
import 'package:life_os/features/notifications/data/repositories/notifications_repository.dart';
import 'package:life_os/features/notifications/domain/models/notification_model.dart';
import 'package:life_os/features/notifications/domain/models/notification_occurrence.dart';
import 'package:life_os/features/notifications/domain/providers/notification_engine.dart';
import '../../../../helpers/test_user_database_factory.dart';

/// Identity must remain usable when local conversion is unavailable/changed.
class _InstantWithoutLocalConversion extends Fake implements DateTime {
  _InstantWithoutLocalConversion(this.microsecondsSinceEpoch);
  @override
  final int microsecondsSinceEpoch;
  @override
  DateTime toLocal() =>
      throw StateError('Current timezone is not occurrence identity');
}

class _User extends Fake implements User {
  _User(this.uid);
  @override
  final String uid;
}

class _Auth extends Fake implements FirebaseAuth {
  User? user = _User('user-a');
  @override
  User? get currentUser => user;
}

class _Store extends Fake implements FirebaseFirestore {
  final documents = <String, Map<String, dynamic>>{};
  final transactions = <String>[];
  final deletes = <String>[];
  int transactionStarts = 0;
  final attemptReads = <int>[];
  final attemptDeletes = <int>[];
  Completer<void>? responseStarted;
  Completer<void>? responseRelease;
  bool offline = false;
  bool loseResponse = false;
  String? failureCode;
  Completer<void>? readStarted;
  Completer<void>? readRelease;
  Completer<void>? writeStarted;
  Completer<void>? writeRelease;
  void Function()? afterRead;
  void Function()? conflictBeforeCommit;

  @override
  CollectionReference<Map<String, dynamic>> collection(String path) =>
      _Collection(this, path);

  @override
  Future<T> runTransaction<T>(
    TransactionHandler<T> action, {
    Duration timeout = const Duration(seconds: 30),
    int maxAttempts = 5,
  }) async {
    transactionStarts++;
    if (offline || failureCode != null) {
      throw FirebaseException(
        plugin: 'cloud_firestore',
        code: failureCode ?? 'unavailable',
      );
    }
    var transaction = _Transaction(this);
    var result = await action(transaction);
    final conflict = conflictBeforeCommit;
    if (conflict != null) {
      conflictBeforeCommit = null;
      conflict();
      // Model Firestore retrying a read version conflict before committing.
      transaction = _Transaction(this);
      result = await action(transaction);
    }
    for (final path in transaction.pendingDeletes) {
      documents.remove(path);
      deletes.add(path);
    }
    if (responseStarted?.isCompleted == false) responseStarted!.complete();
    await responseRelease?.future;
    if (loseResponse) {
      loseResponse = false;
      throw FirebaseException(
        plugin: 'cloud_firestore',
        code: 'deadline-exceeded',
      );
    }
    return result;
  }
}

class _Collection extends Fake
    implements CollectionReference<Map<String, dynamic>> {
  _Collection(this.store, this.path);
  final _Store store;
  @override
  final String path;
  @override
  DocumentReference<Map<String, dynamic>> doc([String? id]) =>
      _Document(store, '$path/$id');
  @override
  Future<QuerySnapshot<Map<String, dynamic>>> get([
    GetOptions? options,
  ]) async => _QuerySnapshot([
    for (final entry in store.documents.entries)
      if (entry.key.startsWith('$path/') &&
          !entry.key.substring(path.length + 1).contains('/'))
        _Snapshot(entry.key.split('/').last, Map.of(entry.value)),
  ]);
}

class _Document extends Fake
    implements DocumentReference<Map<String, dynamic>> {
  _Document(this.store, this.path);
  final _Store store;
  @override
  final String path;
  @override
  CollectionReference<Map<String, dynamic>> collection(String name) =>
      _Collection(store, '$path/$name');
  @override
  Future<void> set(Map<String, dynamic> data, [SetOptions? options]) async {
    if (store.writeStarted?.isCompleted == false)
      store.writeStarted!.complete();
    await store.writeRelease?.future;
    store.documents[path] = Map.of(data);
  }

  @override
  Future<void> delete() async {
    store.documents.remove(path);
    store.deletes.add(path);
  }
}

class _Snapshot extends Fake
    implements QueryDocumentSnapshot<Map<String, dynamic>> {
  _Snapshot(this.id, this.values);
  @override
  final String id;
  final Map<String, dynamic>? values;
  @override
  bool get exists => values != null;
  @override
  Map<String, dynamic> data() => values ?? {};
}

class _QuerySnapshot extends Fake
    implements QuerySnapshot<Map<String, dynamic>> {
  _QuerySnapshot(this.docs);
  @override
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> docs;
}

class _Transaction extends Fake implements Transaction {
  _Transaction(this.store) : attempt = store.attemptReads.length {
    store.attemptReads.add(0);
    store.attemptDeletes.add(0);
  }
  final int attempt;
  final _Store store;
  final pendingDeletes = <String>[];
  @override
  Future<DocumentSnapshot<T>> get<T extends Object?>(
    DocumentReference<T> ref,
  ) async {
    store.attemptReads[attempt]++;
    store.transactions.add(ref.path);
    final data = store.documents[ref.path];
    final snapshot = _Snapshot(
      ref.path.split('/').last,
      data == null ? null : Map.of(data),
    );
    if (store.readStarted?.isCompleted == false) store.readStarted!.complete();
    await store.readRelease?.future;
    store.afterRead?.call();
    return snapshot as DocumentSnapshot<T>;
  }

  @override
  Transaction delete(DocumentReference ref) {
    store.attemptDeletes[attempt]++;
    pendingDeletes.add(ref.path);
    return this;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final monday = DateTime(2026, 10, 5);
  final tuesday = DateTime(2026, 10, 6);
  late AppDatabase db;
  late _Auth auth;
  late _Store remote;
  late NotificationsRepository repository;
  late NotificationRemoteEffectsBarrier barrier;
  final managers = <SyncManager>[];

  NotificationModel card(String id, String module, DateTime due) =>
      NotificationModel(
        id: id,
        moduleType: module,
        dueDate: due,
        title: 'Fixture',
        description: 'Fixture',
        priority: 'today',
        route: '/',
        isRead: false,
        isCompleted: false,
        createdAt: monday,
      );
  String path(String id, [String uid = 'user-a']) =>
      'users/$uid/notifications/$id';
  String key(NotificationModel model) => NotificationOccurrence.key(
    id: model.id,
    moduleType: model.moduleType,
    dueDate: model.dueDate,
  )!;
  Future<void> seed(
    NotificationModel model, {
    AppDatabase? database,
    String uid = 'user-a',
  }) async {
    await (database ?? db)
        .into((database ?? db).notificationsTable)
        .insert(NotificationModel.toCompanion(model));
    remote.documents[path(model.id, uid)] = model.toFirestore();
  }

  SyncManager manager({
    AppDatabase? database,
    NotificationRemoteEffectsBarrier? effects,
    Future<void> Function()? beforeDelete,
    Completer<SyncOperationResult>? producerResult,
  }) {
    final currentDatabase = database ?? db;
    final source = FirestoreSyncRemoteDataSource(
      remote,
      auth,
      captureRemoteSend: (uid) =>
          currentDatabase.localMutations.captureRemoteSend(expectedUid: uid),
      beforeNotificationDelete:
          beforeDelete ?? (effects ?? barrier).drainCurrent,
    );
    final value = SyncManager(
      queueStore: AppDatabaseSyncQueueStore(currentDatabase),
      currentUserId: () => auth.currentUser?.uid,
      remoteDataSource: producerResult == null
          ? source
          : _ObservedNotificationRemote(source, producerResult),
    );
    managers.add(value);
    return value;
  }

  setUp(() {
    auth = _Auth();
    remote = _Store();
    db = AppDatabase(executor: NativeDatabase.memory());
    db.localMutations.bindSessionReader(() => auth.currentUser?.uid);
    db.localMutations.openPreparedSession();
    barrier = NotificationRemoteEffectsBarrier();
    repository = NotificationsRepository(
      localDao: db.notificationDao,
      firestore: remote,
      auth: auth,
      remoteEffects: barrier,
    );
  });
  tearDown(() async {
    for (final value in managers) {
      value.dispose();
    }
    managers.clear();
    if (remote.readRelease?.isCompleted == false)
      remote.readRelease!.complete();
    if (remote.writeRelease?.isCompleted == false)
      remote.writeRelease!.complete();
    if (remote.responseRelease?.isCompleted == false)
      remote.responseRelease!.complete();
    await barrier.sealAndDrain();
    await db.close();
  });

  for (final stop in ['quiesce', 'manager', 'aba', 'a-to-b']) {
    test('notification barrier + $stop starts zero transactions', () async {
      final model = card('habit_barrier-$stop', 'habits', monday);
      await seed(model);
      await repository.deleteNotification(model.id);
      final before = await db.select(db.syncQueueTable).getSingle();
      final entered = Completer<void>();
      final release = Completer<void>();
      final result = Completer<SyncOperationResult>();
      final sync = manager(
        beforeDelete: () {
          entered.complete();
          return release.future;
        },
        producerResult: result,
      );
      final processing = sync.processPendingItems();
      await entered.future;
      LocalMutationQuiescence? quiescence;
      if (stop == 'manager') {
        expect(await sync.prepareForSessionDetach('user-a'), true);
        expect(release.isCompleted, false);
      } else {
        quiescence = db.localMutations.beginQuiesce('user-a');
        if (stop == 'aba' || stop == 'a-to-b') {
          expect(await sync.prepareForSessionDetach('user-a'), true);
          auth.user = null;
          db.localMutations.observeSession(null);
          quiescence.finish(signOutConfirmed: true);
          auth.user = _User(stop == 'aba' ? 'user-a' : 'user-b');
          db.localMutations.observeSession(auth.currentUser?.uid);
          if (stop == 'aba') db.localMutations.openPreparedSession();
        }
      }
      release.complete();
      expect((await result.future).code, 'SESSION_STOPPED');
      expect(await processing, false);
      expect(remote.transactionStarts, 0);
      expect(remote.transactions, isEmpty);
      expect(remote.deletes, isEmpty);
      expect(remote.documents.containsKey(path(model.id)), true);
      final pending = await db.select(db.syncQueueTable).getSingle();
      expect(pending.status, SyncQueuePersistenceStatus.pending);
      expect(pending.ownerUid, before.ownerUid);
      expect(pending.payloadJson, before.payloadJson);
      quiescence?.finish(signOutConfirmed: false);
    });
  }

  for (final failure in ['read', 'transaction']) {
    test(
      'notification failed $failure await after quiesce stays SESSION_STOPPED',
      () async {
        final model = card('habit_failed-$failure', 'habits', monday);
        await seed(model);
        await repository.deleteNotification(model.id);
        LocalMutationQuiescence? quiescence;
        void invalidateAndFail() {
          quiescence = db.localMutations.beginQuiesce('user-a');
          throw FirebaseException(
            plugin: 'cloud_firestore',
            code: 'permission-denied',
          );
        }

        if (failure == 'read')
          remote.afterRead = invalidateAndFail;
        else
          remote.conflictBeforeCommit = invalidateAndFail;
        final result = Completer<SyncOperationResult>();
        final processing = manager(
          producerResult: result,
        ).processPendingItems();
        expect((await result.future).code, 'SESSION_STOPPED');
        expect(await processing, false);
        expect(auth.currentUser?.uid, 'user-a');
        expect(remote.deletes, isEmpty);
        expect(remote.documents.containsKey(path(model.id)), true);
        final pending = await db.select(db.syncQueueTable).getSingle();
        expect(pending.status, SyncQueuePersistenceStatus.pending);
        expect(pending.lastErrorCode, 'SESSION_STOPPED');
        quiescence?.finish(signOutConfirmed: false);
      },
    );
  }

  test('notification permit allows a valid delete and its ACK', () async {
    final model = card('habit_authorized', 'habits', monday);
    await seed(model);
    await repository.deleteNotification(model.id);
    expect(await manager().processPendingItems(), true);
    expect(remote.transactionStarts, 1);
    expect(remote.attemptReads, [1]);
    expect(remote.attemptDeletes, [1]);
    expect(remote.deletes, [path(model.id)]);
    expect(
      (await db.select(db.syncQueueTable).getSingle()).status,
      SyncQueuePersistenceStatus.succeeded,
    );
  });

  for (final stop in ['manager', 'quiesce']) {
    test(
      'notification pending transaction read + $stop cannot delete or ACK',
      () async {
        final model = card('habit_read-$stop', 'habits', monday);
        await seed(model);
        await repository.deleteNotification(model.id);
        final started = remote.readStarted = Completer<void>();
        final release = remote.readRelease = Completer<void>();
        final result = Completer<SyncOperationResult>();
        final sync = manager(producerResult: result);
        final processing = sync.processPendingItems();
        await started.future;
        LocalMutationQuiescence? quiescence;
        if (stop == 'manager') {
          expect(await sync.prepareForSessionDetach('user-a'), true);
          expect(release.isCompleted, false);
        } else {
          quiescence = db.localMutations.beginQuiesce('user-a');
        }
        // Firebase still reports A; the generation must stop this attempt.
        expect(auth.currentUser?.uid, 'user-a');
        release.complete();
        expect((await result.future).code, 'SESSION_STOPPED');
        expect(await processing, false);
        expect(remote.transactionStarts, 1);
        expect(remote.attemptReads, [1]);
        expect(remote.attemptDeletes, [0]);
        expect(remote.documents.containsKey(path(model.id)), true);
        expect(
          (await db.select(db.syncQueueTable).getSingle()).status,
          SyncQueuePersistenceStatus.pending,
        );
        quiescence?.finish(signOutConfirmed: false);
      },
    );
  }

  test(
    'notification already committed before stop has no late local ACK',
    () async {
      final model = card('habit_late-commit', 'habits', monday);
      await seed(model);
      await repository.deleteNotification(model.id);
      final before = await db.select(db.syncQueueTable).getSingle();
      final started = remote.responseStarted = Completer<void>();
      final release = remote.responseRelease = Completer<void>();
      final result = Completer<SyncOperationResult>();
      final sync = manager(producerResult: result);
      final processing = sync.processPendingItems();
      await started.future;
      expect(remote.deletes, [path(model.id)]);
      expect(await sync.prepareForSessionDetach('user-a'), true);
      expect(release.isCompleted, false);
      expect(await processing, false);
      release.complete();
      expect((await result.future).code, 'SESSION_STOPPED');
      expect(await db.select(db.syncQueueTable).getSingle(), before);
      expect(remote.transactionStarts, 1);
    },
  );

  for (final stop in ['quiesce', 'manager', 'aba', 'a-to-b']) {
    test(
      'notification transaction retry + $stop retains original permit',
      () async {
        final model = card('habit_retry-$stop', 'habits', monday);
        await seed(model);
        await repository.deleteNotification(model.id);
        final result = Completer<SyncOperationResult>();
        final sync = manager(producerResult: result);
        LocalMutationQuiescence? quiescence;
        Future<bool>? stopping;
        remote.conflictBeforeCommit = () {
          if (stop == 'manager') {
            stopping = sync.prepareForSessionDetach('user-a');
          } else {
            quiescence = db.localMutations.beginQuiesce('user-a');
            if (stop == 'aba' || stop == 'a-to-b') {
              auth.user = null;
              db.localMutations.observeSession(null);
              quiescence!.finish(signOutConfirmed: true);
              auth.user = _User(stop == 'aba' ? 'user-a' : 'user-b');
              db.localMutations.observeSession(auth.currentUser?.uid);
              if (stop == 'aba') db.localMutations.openPreparedSession();
            }
          }
        };
        final processing = sync.processPendingItems();
        expect((await result.future).code, 'SESSION_STOPPED');
        expect(await processing, false);
        if (stopping != null) expect(await stopping, true);
        expect(remote.transactionStarts, 1);
        // First buffered delete is rolled back after the version conflict.
        // The new attempt rejects before its first read or buffered delete.
        expect(remote.attemptReads, [1, 0]);
        expect(remote.attemptDeletes, [1, 0]);
        expect(remote.deletes, isEmpty);
        expect(remote.documents.containsKey(path(model.id)), true);
        expect(
          (await db.select(db.syncQueueTable).getSingle()).status,
          SyncQueuePersistenceStatus.pending,
        );
        quiescence?.finish(signOutConfirmed: false);
      },
    );
  }

  test(
    'notification canceled preflight stays pending and replays with new admission',
    () async {
      final model = card('habit_replay-permit', 'habits', monday);
      await seed(model);
      await repository.deleteNotification(model.id);
      final entered = Completer<void>(), release = Completer<void>();
      final result = Completer<SyncOperationResult>();
      final sync = manager(
        beforeDelete: () {
          entered.complete();
          return release.future;
        },
        producerResult: result,
      );
      final processing = sync.processPendingItems();
      await entered.future;
      final quiescence = db.localMutations.beginQuiesce('user-a');
      expect(await sync.prepareForSessionDetach('user-a'), true);
      quiescence.finish(signOutConfirmed: false);
      release.complete();
      expect((await result.future).code, 'SESSION_STOPPED');
      expect(await processing, false);
      expect(remote.transactionStarts, 0);
      expect(
        (await db.select(db.syncQueueTable).getSingle()).status,
        SyncQueuePersistenceStatus.pending,
      );
      expect(await manager().processPendingItems(), true);
      expect(remote.transactionStarts, 1);
      expect(remote.deletes, [path(model.id)]);
      expect(
        (await db.select(db.syncQueueTable).getSingle()).status,
        SyncQueuePersistenceStatus.succeeded,
      );
    },
  );

  for (final (id, module) in [
    ('habit_entity', 'habits'),
    ('exam_entity', 'studies'),
    ('health_med_entity', 'health'),
  ]) {
    test('$id dismisses current occurrence and admits a new one', () async {
      final first = card(id, module, monday);
      await seed(first);
      await repository.deleteNotification(id);
      await repository.deleteNotification(id);
      expect(await repository.getLocalNotification(id), isNull);
      final dismissal =
          (await db.select(db.notificationDismissals).get()).single;
      expect(dismissal.occurrenceKey, key(first));
      final intent = (await db.getPendingSyncItems('user-a')).single;
      expect(intent.ownerUid, 'user-a');
      expect(intent.collection, 'notifications');
      expect(intent.operationType, 'delete');
      expect(jsonDecode(intent.payloadJson), {'occurrenceKey': key(first)});
      expect(remote.documents.containsKey(path(id)), isTrue);
      await repository.syncNotificationsFromFirebaseToLocal();
      await repository.saveLocalNotification(
        first.copyWith(createdAt: tuesday),
      );
      expect(await repository.getLocalNotification(id), isNull);
      expect(await manager().processPendingItems(), isTrue);
      expect(remote.documents.containsKey(path(id)), isFalse);
      expect(await db.select(db.notificationDismissals).get(), [dismissal]);
      await repository.saveLocalNotification(first);
      expect(await repository.getLocalNotification(id), isNull);
      await db.cleanupSucceededSyncItems(
        'user-a',
        DateTime(2100).millisecondsSinceEpoch,
      );
      expect(await db.select(db.syncQueueTable).get(), isEmpty);
      await repository.saveLocalNotification(first);
      expect(await repository.getLocalNotification(id), isNull);
      // Same occurrence is suppressed despite queue success retention cleanup.
      final next = first.copyWith(dueDate: tuesday);
      remote.documents[path(id)] = next.toFirestore();
      await repository.syncNotificationsFromFirebaseToLocal();
      expect((await repository.getLocalNotification(id))!.dueDate, tuesday);
      await repository.saveLocalNotification(next);
      await barrier.drainCurrent();
      // The historical key remains inert for Y but still rejects a late X read.
      remote.documents[path(id)] = first.toFirestore();
      await repository.syncNotificationsFromFirebaseToLocal();
      expect((await repository.getLocalNotification(id))!.dueDate, tuesday);
    });

    test(
      '$id stale pending delete cannot delete the newer remote occurrence',
      () async {
        final first = card(id, module, monday);
        await seed(first);
        await repository.deleteNotification(id);
        final next = first.copyWith(dueDate: tuesday);
        await repository.saveLocalNotification(next);
        await barrier.drainCurrent();
        expect(await manager().processPendingItems(), isTrue);
        expect(remote.deletes, isEmpty);
        expect(
          NotificationModel.fromFirestore(
            _Snapshot(id, remote.documents[path(id)]),
          ).dueDate,
          tuesday,
        );
        expect(
          (await db.select(db.syncQueueTable).getSingle()).status,
          SyncQueuePersistenceStatus.succeeded,
        );
      },
    );
  }

  test(
    'queue insert failure rolls back dismissal and local deletion together',
    () async {
      final model = card('habit_atomic', 'habits', monday);
      await seed(model);
      await db.customStatement(
        "CREATE TRIGGER fail_notification_queue BEFORE INSERT ON sync_queue_table BEGIN SELECT RAISE(ABORT, 'test rollback'); END",
      );
      await expectLater(
        repository.deleteNotification(model.id),
        throwsA(isA<Exception>()),
      );
      expect(await repository.getLocalNotification(model.id), isNotNull);
      expect(await db.select(db.notificationDismissals).get(), isEmpty);
      expect(await db.select(db.syncQueueTable).get(), isEmpty);
      expect(remote.transactions, isEmpty);
    },
  );

  test('delete without occurrenceKey is rejected before remote I/O', () async {
    final model = card('habit_unscoped', 'habits', monday);
    await seed(model);
    await db.insertSyncItem(
      ownerUid: 'user-a',
      collection: 'notifications',
      docId: model.id,
      operationType: 'delete',
      payloadJson: '{}',
    );
    await manager().processPendingItems();
    expect(
      (await db.select(db.syncQueueTable).getSingle()).status,
      SyncQueuePersistenceStatus.rejected,
    );
    expect(remote.transactions, isEmpty);
    expect(remote.documents.containsKey(path(model.id)), isTrue);
  });

  test(
    'all occurrences use the exact dueDate instant independently of timezone',
    () {
      for (final (id, module) in [
        ('habit_key', 'habits'),
        ('exam_key', 'studies'),
        ('health_med_key', 'health'),
      ]) {
        final current = card(id, module, monday);
        expect(key(current), key(current.copyWith(dueDate: monday.toUtc())));
        expect(
          key(current),
          key(current.copyWith(createdAt: tuesday, title: 'Renamed')),
        );
        expect(key(current), isNot(key(current.copyWith(dueDate: tuesday))));
        expect(
          key(current),
          isNot(
            key(
              current.copyWith(dueDate: monday.add(const Duration(hours: 1))),
            ),
          ),
        );
      }
      expect(
        NotificationOccurrence.key(
          id: 'habit_key',
          moduleType: 'habits',
          dueDate: null,
        ),
        isNull,
      );
    },
  );

  test('habit key never consults the current local timezone', () {
    final instant = DateTime.utc(2026, 10, 5, 1, 30);
    final expected = key(card('habit_timezone', 'habits', instant));
    expect(
      NotificationOccurrence.key(
        id: 'habit_timezone',
        moduleType: 'habits',
        dueDate: _InstantWithoutLocalConversion(instant.microsecondsSinceEpoch),
      ),
      expected,
    );
    expect(jsonDecode(expected), [
      1,
      'habit_timezone',
      'habits',
      instant.microsecondsSinceEpoch,
    ]);
  });

  for (final (id, module) in [
    ('habit_precision', 'habits'),
    ('exam_precision', 'studies'),
    ('health_med_precision', 'health'),
  ]) {
    test(
      'exact dueDate of $id survives Drift rounding and hydration',
      () async {
        final due = monday.add(
          const Duration(milliseconds: 123, microseconds: 456),
        );
        final model = card(id, module, due);
        final utcRoundtrip = DateTime.fromMicrosecondsSinceEpoch(
          due.microsecondsSinceEpoch,
          isUtc: true,
        );
        expect(key(model), key(model.copyWith(dueDate: utcRoundtrip)));
        await repository.saveLocalNotification(model);
        await barrier.drainCurrent();
        expect((await repository.getLocalNotification(id))!.dueDate, due);
        expect(remote.documents[path(id)]!['dueDate'], Timestamp.fromDate(due));
        // Remote Timestamp reconstructed from the same instant in UTC.
        remote.documents[path(id)] = model
            .copyWith(dueDate: utcRoundtrip)
            .toFirestore();
        await repository.deleteNotification(id);
        expect(
          (await db.select(db.notificationDismissals).getSingle())
              .occurrenceKey,
          key(model),
        );
        await repository.saveLocalNotification(model);
        await repository.syncNotificationsFromFirebaseToLocal();
        expect(await repository.getLocalNotification(id), isNull);
        expect(await manager().processPendingItems(), isTrue);
        expect(remote.documents.containsKey(path(id)), isFalse);
        await repository.saveLocalNotification(
          model.copyWith(dueDate: due.add(const Duration(microseconds: 1))),
        );
        expect(await repository.getLocalNotification(id), isNotNull);
      },
    );
  }

  test(
    'ambiguous legacy hydration cannot invalidate a persisted dismissal',
    () async {
      final model = card('habit_legacy-hydration', 'habits', monday);
      await seed(model);
      await repository.deleteNotification(model.id);
      remote.documents[path(model.id)]!.remove('dueDate');
      await repository.syncNotificationsFromFirebaseToLocal();
      expect(await repository.getLocalNotification(model.id), isNull);
      expect(await db.select(db.notificationDismissals).get(), hasLength(1));
      expect(await db.getPendingSyncItems('user-a'), hasLength(1));
    },
  );

  test(
    'remote adapter refuses owner mismatch before reading any document',
    () async {
      final model = card('habit_owner', 'habits', monday);
      await seed(model);
      await repository.deleteNotification(model.id);
      final item = await db.select(db.syncQueueTable).getSingle();
      auth.user = _User('user-b');
      final result = await FirestoreSyncRemoteDataSource(
        remote,
        auth,
      ).process('user-b', item);
      expect(result.shouldRetry, isTrue);
      expect(remote.transactions, isEmpty);
      expect(remote.documents.containsKey(path(model.id)), isTrue);
    },
  );

  test(
    'replay drain includes SDK effects admitted by an existing continuation',
    () async {
      final continueLocal = Completer<void>();
      final sdkStarted = Completer<void>();
      final finishSdk = Completer<void>();
      unawaited(
        barrier.track(() async {
          await continueLocal.future;
          unawaited(
            barrier.track(() async {
              sdkStarted.complete();
              await finishSdk.future;
            }),
          );
        }),
      );
      var drained = false;
      final drain = barrier.drainCurrent().then((_) => drained = true);
      continueLocal.complete();
      await sdkStarted.future;
      await Future<void>.delayed(Duration.zero);
      expect(drained, isFalse);
      finishSdk.complete();
      await drain;
      expect(drained, isTrue);
    },
  );

  test(
    'online dismissal commits before remote I/O and returns while delete is in flight',
    () async {
      final model = card('habit_online', 'habits', monday);
      await seed(model);
      final sync = manager();
      final started = remote.readStarted = Completer<void>();
      final release = remote.readRelease = Completer<void>();
      final online = NotificationsRepository(
        localDao: db.notificationDao,
        firestore: remote,
        auth: auth,
        remoteEffects: barrier,
        replayDeletes: () async {
          expect(
            await db.select(db.notificationDismissals).get(),
            hasLength(1),
          );
          expect(await db.getPendingSyncItems('user-a'), hasLength(1));
          expect(await repository.getLocalNotification(model.id), isNull);
          await sync.processPendingItems();
        },
      );
      await online.deleteNotification(model.id);
      await started.future;
      expect(release.isCompleted, isFalse);
      expect(await repository.getLocalNotification(model.id), isNull);
      release.complete();
      expect(await sync.processPendingItems(), isTrue);
      expect(remote.documents.containsKey(path(model.id)), isFalse);
      expect(await db.select(db.notificationDismissals).get(), hasLength(1));
    },
  );

  test(
    'offline/timeout retains delete and hydration cannot resurrect it',
    () async {
      final model = card('exam_offline', 'studies', monday);
      await seed(model);
      await repository.deleteNotification(model.id);
      remote.offline = true;
      final sync = manager();
      expect(await sync.processPendingItems(), isFalse);
      final intent = await db.select(db.syncQueueTable).getSingle();
      expect(intent.status, SyncQueuePersistenceStatus.pending);
      expect(intent.attemptCount, 1);
      await repository.syncNotificationsFromFirebaseToLocal();
      expect(await repository.getLocalNotification(model.id), isNull);
      remote.offline = false;
      expect(await sync.processPendingItems(), isTrue);
      expect(remote.documents.containsKey(path(model.id)), isFalse);
    },
  );

  test(
    'applied delete with lost response retries absent document safely',
    () async {
      final model = card('health_med_lost', 'health', monday);
      await seed(model);
      await repository.deleteNotification(model.id);
      remote.loseResponse = true;
      final sync = manager();
      expect(await sync.processPendingItems(), isFalse);
      expect(remote.documents.containsKey(path(model.id)), isFalse);
      expect(
        (await db.select(db.syncQueueTable).getSingle()).status,
        SyncQueuePersistenceStatus.pending,
      );
      expect(await sync.processPendingItems(), isTrue);
      expect(remote.deletes, [path(model.id)]);
      expect((await db.select(db.syncQueueTable).getSingle()).attemptCount, 2);
    },
  );

  test('Firestore read version conflict retries and preserves Y', () async {
    final model = card('habit_conflict', 'habits', monday);
    await seed(model);
    await repository.deleteNotification(model.id);
    remote.conflictBeforeCommit = () => remote.documents[path(model.id)] = model
        .copyWith(dueDate: tuesday)
        .toFirestore();
    expect(await manager().processPendingItems(), isTrue);
    expect(remote.transactions, [path(model.id), path(model.id)]);
    expect(remote.deletes, isEmpty);
    expect(
      remote.documents[path(model.id)]!['dueDate'],
      Timestamp.fromDate(tuesday),
    );
  });

  test(
    'session switch during transaction read never deletes or acknowledges A',
    () async {
      final model = card('habit_switch', 'habits', monday);
      await seed(model);
      await repository.deleteNotification(model.id);
      remote.documents[path(model.id, 'user-b')] = model.toFirestore();
      remote.afterRead = () => auth.user = _User('user-b');
      expect(await manager().processPendingItems(), isFalse);
      expect(remote.transactions, [path(model.id)]);
      expect(remote.deletes, isEmpty);
      expect(remote.documents, hasLength(2));
      expect(
        (await db.select(db.syncQueueTable).getSingle()).status,
        SyncQueuePersistenceStatus.pending,
      );
    },
  );

  test('rejected delete retains user dismissal without resurrecting', () async {
    final model = card('exam_rejected', 'studies', monday);
    await seed(model);
    await repository.deleteNotification(model.id);
    remote.failureCode = 'permission-denied';
    await manager().processPendingItems();
    expect(
      (await db.select(db.syncQueueTable).getSingle()).status,
      SyncQueuePersistenceStatus.rejected,
    );
    await repository.syncNotificationsFromFirebaseToLocal();
    expect(await repository.getLocalNotification(model.id), isNull);
    expect(await db.select(db.notificationDismissals).get(), hasLength(1));
  });

  test(
    'unknown/legacy occurrence is refused without inventing identity',
    () async {
      final model = card('custom_unknown', 'general', monday);
      await seed(model);
      await expectLater(
        repository.deleteNotification(model.id),
        throwsUnsupportedError,
      );
      expect(await repository.getLocalNotification(model.id), isNotNull);
      expect(await db.select(db.notificationDismissals).get(), isEmpty);
      expect(await db.select(db.syncQueueTable).get(), isEmpty);
      expect(remote.documents.containsKey(path(model.id)), isTrue);
    },
  );

  test(
    'remote legacy record missing dueDate is retained, not blindly deleted',
    () async {
      final model = card('habit_legacy', 'habits', monday);
      await seed(model);
      await repository.deleteNotification(model.id);
      remote.documents[path(model.id)]!.remove('dueDate');
      await manager().processPendingItems();
      expect(remote.deletes, isEmpty);
      expect(remote.documents.containsKey(path(model.id)), isTrue);
      expect(
        (await db.select(db.syncQueueTable).getSingle()).status,
        SyncQueuePersistenceStatus.rejected,
      );
    },
  );

  test(
    'SDK writes admitted before dismissal settle before remote deletion',
    () async {
      final model = card('habit_write', 'habits', monday);
      final started = remote.writeStarted = Completer<void>();
      final release = remote.writeRelease = Completer<void>();
      await repository.saveLocalNotification(model);
      await started.future;
      await repository.deleteNotification(model.id);
      final processing = manager().processPendingItems();
      await Future<void>.delayed(Duration.zero);
      expect(remote.transactions, isEmpty);
      release.complete();
      expect(await processing, isTrue);
      expect(remote.documents.containsKey(path(model.id)), isFalse);
    },
  );

  test(
    'barrier seal blocks a late A dismissal before local persistence',
    () async {
      final model = card('habit_sealed', 'habits', monday);
      await seed(model);
      await barrier.sealAndDrain();
      await expectLater(
        repository.deleteNotification(model.id),
        throwsA(isA<LocalMutationUnavailable>()),
      );
      expect(await repository.getLocalNotification(model.id), isNotNull);
      expect(await db.select(db.syncQueueTable).get(), isEmpty);
      expect(await db.select(db.notificationDismissals).get(), isEmpty);
    },
  );

  test(
    'actual file restart and A/B detach isolate and preserve dismissal/replay',
    () async {
      final factory = TestUserDatabaseFactory();
      final sessions = SessionDatabaseCoordinator(
        currentUserId: () => auth.currentUser?.uid,
        openDatabase: factory.open,
      );
      addTearDown(() async {
        await sessions.dispose();
        await factory.dispose();
      });
      final model = card(
        'exam_restart',
        'studies',
        monday.add(const Duration(milliseconds: 123, microseconds: 456)),
      );
      var a = await sessions.prepare('user-a');
      await seed(model, database: a);
      var repoA = NotificationsRepository(
        localDao: a.notificationDao,
        firestore: remote,
        auth: auth,
      );
      await repoA.deleteNotification(model.id);
      final original = await a.select(a.notificationDismissals).getSingle();
      // No SDK call happened: simulate app dying immediately after durable commit.
      expect(remote.transactions, isEmpty);
      await sessions.detach(expectedUid: 'user-a');
      a = await sessions.prepare('user-a');
      repoA = NotificationsRepository(
        localDao: a.notificationDao,
        firestore: remote,
        auth: auth,
      );
      await repoA.syncNotificationsFromFirebaseToLocal();
      expect(await repoA.getLocalNotification(model.id), isNull);
      expect(await a.select(a.notificationDismissals).getSingle(), original);
      final syncA = manager(database: a, effects: repoA.remoteEffects);
      remote.offline = true;
      expect(await syncA.processPendingItems(), isFalse);
      expect(await syncA.prepareForSessionDetach('user-a'), isTrue);
      await repoA.remoteEffects.sealAndDrain();
      auth.user = null;
      await sessions.detach(expectedUid: 'user-a');
      auth.user = _User('user-b');
      final b = await sessions.prepare('user-b');
      remote.documents[path(model.id, 'user-b')] = model.toFirestore();
      final repoB = NotificationsRepository(
        localDao: b.notificationDao,
        firestore: remote,
        auth: auth,
      );
      await repoB.syncNotificationsFromFirebaseToLocal();
      expect(await repoB.getLocalNotification(model.id), isNotNull);
      expect(await b.select(b.notificationDismissals).get(), isEmpty);
      expect(await b.select(b.syncQueueTable).get(), isEmpty);
      remote.offline = false;
      expect(await syncA.processPendingItems(), isFalse);
      expect(
        await manager(
          database: b,
          effects: repoB.remoteEffects,
        ).processPendingItems(),
        isTrue,
      );
      expect(remote.transactions, isEmpty);
      await expectLater(
        repoA.deleteNotification(model.id),
        throwsA(isA<LocalMutationUnavailable>()),
      );
      auth.user = null;
      await sessions.detach(expectedUid: 'user-b');
      auth.user = _User('user-a');
      a = await sessions.prepare('user-a');
      repoA = NotificationsRepository(
        localDao: a.notificationDao,
        firestore: remote,
        auth: auth,
      );
      await repoA.syncNotificationsFromFirebaseToLocal();
      expect(await repoA.getLocalNotification(model.id), isNull);
      expect(await a.select(a.notificationDismissals).getSingle(), original);
      expect(
        await manager(
          database: a,
          effects: repoA.remoteEffects,
        ).processPendingItems(),
        isTrue,
      );
      expect(remote.transactions, [path(model.id)]);
      expect(remote.documents.containsKey(path(model.id, 'user-b')), isTrue);
      expect(await a.select(a.notificationDismissals).getSingle(), original);
    },
  );

  test(
    'destructive DB cleanup includes dismissals and pending delivery',
    () async {
      final model = card('habit_cleanup', 'habits', monday);
      await seed(model);
      await repository.deleteNotification(model.id);
      await db.clearAllData();
      expect(await db.select(db.notificationDismissals).get(), isEmpty);
      expect(await db.select(db.syncQueueTable).get(), isEmpty);
    },
  );

  for (final (id, module) in [
    ('habit_entity', 'habits'),
    ('exam_entity', 'studies'),
    ('health_med_entity', 'health'),
  ]) {
    test(
      'engine respects dismissal of $id and allows its next occurrence',
      () async {
        Future<void> source(DateTime date, {bool update = false}) async {
          if (module == 'habits') {
            if (!update)
              await db
                  .into(db.habits)
                  .insert(
                    HabitsCompanion.insert(
                      id: 'entity',
                      title: 'Fixture',
                      completedDates: '[]',
                    ),
                  );
          } else if (module == 'studies') {
            if (!update) {
              await db
                  .into(db.subjects)
                  .insert(
                    SubjectsCompanion.insert(
                      id: 'entity',
                      title: 'Fixture',
                      cardsToReview: 0,
                      streakDays: 0,
                      progress: 0,
                      hasExam: true,
                      examDate: Value(date.millisecondsSinceEpoch),
                    ),
                  );
            } else {
              await (db.update(
                db.subjects,
              )..where((t) => t.id.equals('entity'))).write(
                SubjectsCompanion(examDate: Value(date.millisecondsSinceEpoch)),
              );
            }
          } else {
            if (!update) {
              await db
                  .into(db.medications)
                  .insert(
                    MedicationsCompanion.insert(
                      firestoreId: 'entity',
                      name: 'Fixture',
                      startDate: monday,
                      endDate: Value(date.add(const Duration(days: 10))),
                    ),
                  );
            } else {
              await db
                  .update(db.medications)
                  .write(
                    MedicationsCompanion(
                      endDate: Value(date.add(const Duration(days: 10))),
                    ),
                  );
            }
          }
        }

        Future<void> reconcile(DateTime day) =>
            const NotificationModuleReconciler().sync(
              repository: repository,
              db: db,
              preferences: const NotificationPreferences.enabled(),
              today: day,
            );
        await source(monday);
        await reconcile(monday);
        await barrier.drainCurrent();
        expect(await repository.getLocalNotification(id), isNotNull);
        await repository.deleteNotification(id);
        await reconcile(monday);
        expect(await repository.getLocalNotification(id), isNull);
        if (module == 'health') {
          await reconcile(tuesday);
          expect(await repository.getLocalNotification(id), isNull);
        }
        await source(tuesday, update: true);
        await reconcile(module == 'habits' ? tuesday : monday);
        expect(await repository.getLocalNotification(id), isNotNull);
      },
    );
  }

  test(
    'category disable and orphan cleanup do not create a user dismissal',
    () async {
      await db
          .into(db.habits)
          .insert(
            HabitsCompanion.insert(
              id: 'entity',
              title: 'Fixture',
              completedDates: '[]',
            ),
          );
      await const NotificationModuleReconciler().sync(
        repository: repository,
        db: db,
        preferences: const NotificationPreferences.enabled(),
        today: monday,
      );
      await barrier.drainCurrent();
      await const NotificationModuleReconciler().sync(
        repository: repository,
        db: db,
        preferences: const NotificationPreferences(
          allNotifications: false,
          studyReminders: false,
          habitReminders: false,
          medicationReminders: false,
        ),
        today: monday,
      );
      await barrier.drainCurrent();
      expect(await db.select(db.notificationDismissals).get(), isEmpty);
      expect(await db.select(db.syncQueueTable).get(), isEmpty);
      await const NotificationModuleReconciler().sync(
        repository: repository,
        db: db,
        preferences: const NotificationPreferences.enabled(),
        today: monday,
      );
      expect(await repository.getLocalNotification('habit_entity'), isNotNull);
      await db.delete(db.habits).go();
      await const NotificationModuleReconciler().sync(
        repository: repository,
        db: db,
        preferences: const NotificationPreferences.enabled(),
        today: monday,
      );
      expect(await repository.getLocalNotification('habit_entity'), isNull);
      expect(await db.select(db.notificationDismissals).get(), isEmpty);
    },
  );
}

/// Observe the producer after Future.any has already released its manager.
class _ObservedNotificationRemote implements SessionBoundSyncRemoteDataSource {
  _ObservedNotificationRemote(this.source, this.result);
  final FirestoreSyncRemoteDataSource source;
  final Completer<SyncOperationResult> result;
  @override
  Future<SyncOperationResult> process(String uid, SyncQueueTableData item) =>
      processForSession(uid, item, canSend: () => true);
  @override
  Future<SyncOperationResult> processForSession(
    String uid,
    SyncQueueTableData item, {
    required bool Function() canSend,
  }) async {
    final value = await source.processForSession(uid, item, canSend: canSend);
    if (!result.isCompleted) result.complete(value);
    return value;
  }
}
