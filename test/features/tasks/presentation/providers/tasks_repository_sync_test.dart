// ignore_for_file: subtype_of_sealed_class

import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/features/tasks/presentation/providers/tasks_provider.dart';

class _User extends Fake implements User {
  @override
  final String uid;
  _User(this.uid);
}

class _Auth extends Fake implements FirebaseAuth {
  @override
  User? currentUser = _User('user-a');
}

class _Document extends Fake
    implements QueryDocumentSnapshot<Map<String, dynamic>> {
  @override
  String get id => 'task-1';
  @override
  Map<String, dynamic> data() => {
    'title': 'Task',
    'priority': 'medium',
    'isCompleted': true,
    'date': Timestamp.fromDate(DateTime(2026, 9, 5)),
  };
}

class _Snapshot extends Fake implements QuerySnapshot<Map<String, dynamic>> {
  _Snapshot(this.docs);

  @override
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> docs;
}

// Mutable fetch hook controls session changes and in-flight mutations in tests.
// ignore: must_be_immutable
class _Collection extends Fake
    implements CollectionReference<Map<String, dynamic>> {
  Future<void> Function()? beforeGet;
  List<QueryDocumentSnapshot<Map<String, dynamic>>> remoteDocs = [_Document()];
  bool failGet = false;
  @override
  DocumentReference<Map<String, dynamic>> doc([String? path]) {
    expect(path, 'user-a');
    return _UserDocument(this);
  }

  @override
  Future<QuerySnapshot<Map<String, dynamic>>> get([GetOptions? options]) async {
    expect(options?.source, Source.server);
    await beforeGet?.call();
    if (failGet) {
      throw FirebaseException(plugin: 'cloud_firestore', code: 'unavailable');
    }
    return _Snapshot(remoteDocs);
  }
}

class _UserDocument extends Fake
    implements DocumentReference<Map<String, dynamic>> {
  final _Collection tasks;
  _UserDocument(this.tasks);
  @override
  CollectionReference<Map<String, dynamic>> collection(String path) {
    expect(path, 'tasks');
    return tasks;
  }
}

class _Firestore extends Fake implements FirebaseFirestore {
  final _Collection tasks = _Collection();
  @override
  CollectionReference<Map<String, dynamic>> collection(String path) {
    expect(path, 'users');
    return tasks;
  }
}

class _Database extends AppDatabase {
  void Function()? afterPendingRead;
  _Database() : super(executor: NativeDatabase.memory());
  @override
  Future<List> getPendingSyncItems(String ownerUid) async {
    final items = await super.getPendingSyncItems(ownerUid);
    afterPendingRead?.call();
    return items;
  }
}

void main() {
  late _Database db;
  late _Auth auth;
  late _Firestore firestore;
  late TasksRepository repository;

  setUp(() {
    db = _Database();
    auth = _Auth();
    firestore = _Firestore();
    repository = TasksRepository(db, firestore, auth);
  });
  tearDown(() => db.close());

  Future<void> seed({bool completed = false}) => db
      .into(db.taskTable)
      .insert(
        TaskTableCompanion.insert(
          id: 'task-1',
          title: 'Local',
          priority: 'medium',
          isCompleted: Value(completed),
          date: DateTime(2026, 9, 5),
        ),
      )
      .then((_) {});

  Future<int> enqueue(
    String operation, {
    String owner = 'user-a',
    int? createdAt,
  }) => db.insertSyncItem(
    ownerUid: owner,
    collection: 'tasks',
    docId: 'task-1',
    operationType: operation,
    payloadJson: '{"isCompleted":false}',
    createdAt: createdAt,
  );

  test(
    'uncheck commits false locally and queues pending false with owner',
    () async {
      await seed(completed: true);
      await repository.toggleTaskStatus('task-1', true);
      expect((await db.select(db.taskTable).getSingle()).isCompleted, isFalse);
      final item =
          (await db.getPendingSyncItems('user-a')).single as SyncQueueTableData;
      expect(item.ownerUid, 'user-a');
      expect(item.collection, 'tasks');
      expect(item.docId, 'task-1');
      expect(item.operationType, 'update');
      expect(item.status, 'pending');
      expect(jsonDecode(item.payloadJson), {'isCompleted': false});
    },
  );

  for (final operation in ['create', 'update']) {
    test(
      'pending $operation protects local false against remote true',
      () async {
        await seed();
        await enqueue(operation);
        await repository.syncTasksFromFirebaseToLocal();
        expect(
          (await db.select(db.taskTable).getSingle()).isCompleted,
          isFalse,
        );
      },
    );
  }

  test('pending delete prevents resurrection', () async {
    await enqueue('delete');
    await repository.syncTasksFromFirebaseToLocal();
    expect(await db.select(db.taskTable).get(), isEmpty);
  });

  test('without pending remote hydrates normally', () async {
    await seed();
    await repository.syncTasksFromFirebaseToLocal();
    expect((await db.select(db.taskTable).getSingle()).isCompleted, isTrue);
  });

  test('remote absence removes unprotected local task', () async {
    await seed();
    firestore.tasks.remoteDocs = [];

    await repository.syncTasksFromFirebaseToLocal();

    expect(await db.select(db.taskTable).get(), isEmpty);
  });

  test('rejected create absent remotely removes optimistic task', () async {
    await seed();
    firestore.tasks.remoteDocs = [];
    final id = await enqueue('create');
    await db.markSyncItemRejected(id, 'user-a', 'QUOTA_EXCEEDED');

    await repository.syncTasksFromFirebaseToLocal();

    expect(await db.select(db.taskTable).get(), isEmpty);
  });

  test('pending create absent remotely remains local', () async {
    await seed();
    firestore.tasks.remoteDocs = [];
    await enqueue('create');

    await repository.syncTasksFromFirebaseToLocal();

    expect(await db.select(db.taskTable).get(), hasLength(1));
  });

  test('old succeeded create absent remotely is pruned', () async {
    await seed();
    firestore.tasks.remoteDocs = [];
    final id = await enqueue(
      'create',
      createdAt: DateTime.utc(2026, 1, 1).millisecondsSinceEpoch,
    );
    await db.markSyncItemAsSucceeded(id, 'user-a');

    await repository.syncTasksFromFirebaseToLocal();

    expect(await db.select(db.taskTable).get(), isEmpty);
  });

  test('preexisting pending succeeds during GET and protects task', () async {
    await seed();
    firestore.tasks.remoteDocs = [];
    final id = await enqueue(
      'create',
      createdAt: DateTime.utc(2026, 1, 1).millisecondsSinceEpoch,
    );
    firestore.tasks.beforeGet = () async {
      await db.markSyncItemAsSucceeded(id, 'user-a');
    };

    await repository.syncTasksFromFirebaseToLocal();

    expect(await db.select(db.taskTable).get(), hasLength(1));
  });

  test(
    'preexisting pending rejected during GET does not protect task',
    () async {
      await seed();
      firestore.tasks.remoteDocs = [];
      final oldSucceeded = await enqueue(
        'update',
        createdAt: DateTime.utc(2025, 1, 1).millisecondsSinceEpoch,
      );
      await db.markSyncItemAsSucceeded(oldSucceeded, 'user-a');
      final pending = await enqueue(
        'create',
        createdAt: DateTime.utc(2026, 1, 1).millisecondsSinceEpoch,
      );
      firestore.tasks.beforeGet = () async {
        await db.markSyncItemRejected(pending, 'user-a', 'QUOTA_EXCEEDED');
      };

      await repository.syncTasksFromFirebaseToLocal();

      expect(await db.select(db.taskTable).get(), isEmpty);
    },
  );

  test('succeeded create during GET protects absent remote task', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    firestore.tasks.remoteDocs = [];
    firestore.tasks.beforeGet = () {
      started.complete();
      return release.future;
    };

    final pull = repository.syncTasksFromFirebaseToLocal();
    await started.future;
    await seed();
    final id = await enqueue('create');
    await db.markSyncItemAsSucceeded(id, 'user-a');
    release.complete();
    await pull;

    expect(await db.select(db.taskTable).get(), hasLength(1));
  });

  test('failed server fetch preserves local task', () async {
    await seed();
    firestore.tasks.remoteDocs = [];
    firestore.tasks.failGet = true;

    await repository.syncTasksFromFirebaseToLocal();

    expect(await db.select(db.taskTable).get(), hasLength(1));
  });

  test('UID change during absent snapshot does not prune task', () async {
    await seed();
    firestore.tasks.remoteDocs = [];
    firestore.tasks.beforeGet = () async {
      auth.currentUser = _User('user-b');
    };

    await repository.syncTasksFromFirebaseToLocal();

    expect(await db.select(db.taskTable).get(), hasLength(1));
  });

  for (final status in ['rejected', 'succeeded']) {
    test('$status does not block reconciliation', () async {
      await seed();
      final id = await enqueue(
        'update',
        createdAt: DateTime(2026, 1, 1).millisecondsSinceEpoch,
      );
      if (status == 'rejected') {
        await db.markSyncItemRejected(id, 'user-a', 'INVALID_PAYLOAD');
      } else {
        await db.markSyncItemAsSucceeded(id, 'user-a');
      }
      await repository.syncTasksFromFirebaseToLocal();
      expect((await db.select(db.taskTable).getSingle()).isCompleted, isTrue);
    });
  }

  test('another owner pending does not block this owner hydration', () async {
    await seed();
    await enqueue('update', owner: 'user-b');
    await repository.syncTasksFromFirebaseToLocal();
    expect((await db.select(db.taskTable).getSingle()).isCompleted, isTrue);
  });

  test('session changes during fetch: no old-user write', () async {
    firestore.tasks.beforeGet = () async {
      auth.currentUser = _User('user-b');
    };
    await repository.syncTasksFromFirebaseToLocal();
    expect(await db.select(db.taskTable).get(), isEmpty);
  });

  test('session changes during pending read: no old-user write', () async {
    firestore.tasks.beforeGet = () async {
      auth.currentUser = _User('user-b');
    };
    await repository.syncTasksFromFirebaseToLocal();
    expect(await db.select(db.taskTable).get(), isEmpty);
  });

  test(
    'mutation while remote fetch is in flight stays authoritative',
    () async {
      await seed(completed: true);
      final started = Completer<void>();
      final release = Completer<void>();
      firestore.tasks.beforeGet = () {
        started.complete();
        return release.future;
      };
      final pull = repository.syncTasksFromFirebaseToLocal();
      await started.future;
      await repository.toggleTaskStatus('task-1', true);
      release.complete();
      await pull;
      expect((await db.select(db.taskTable).getSingle()).isCompleted, isFalse);
      expect(await db.getPendingSyncItems('user-a'), hasLength(1));
    },
  );

  test(
    'mutation succeeded during in-flight fetch still protects local state',
    () async {
      await seed(completed: true);
      final started = Completer<void>();
      final release = Completer<void>();
      firestore.tasks.beforeGet = () {
        started.complete();
        return release.future;
      };

      final pull = repository.syncTasksFromFirebaseToLocal();
      await started.future;
      await repository.toggleTaskStatus('task-1', true);
      final pending =
          (await db.getPendingSyncItems('user-a')).single as SyncQueueTableData;
      await db.markSyncItemAsSucceeded(pending.id, 'user-a');
      release.complete();
      await pull;

      expect((await db.select(db.taskTable).getSingle()).isCompleted, isFalse);
    },
  );

  test(
    'succeeded delete during in-flight fetch does not resurrect task',
    () async {
      await seed(completed: true);
      final started = Completer<void>();
      final release = Completer<void>();
      firestore.tasks.beforeGet = () {
        started.complete();
        return release.future;
      };

      final pull = repository.syncTasksFromFirebaseToLocal();
      await started.future;
      await repository.deleteTask('task-1');
      final pending =
          (await db.getPendingSyncItems('user-a')).single as SyncQueueTableData;
      await db.markSyncItemAsSucceeded(pending.id, 'user-a');
      release.complete();
      await pull;

      expect(await db.select(db.taskTable).get(), isEmpty);
    },
  );

  test('succeeded before pull does not block fresh hydration', () async {
    await seed();
    final id = await enqueue(
      'update',
      createdAt: DateTime(2026, 1, 1).millisecondsSinceEpoch,
    );
    await db.markSyncItemAsSucceeded(id, 'user-a');

    await repository.syncTasksFromFirebaseToLocal();

    expect((await db.select(db.taskTable).getSingle()).isCompleted, isTrue);
  });
}
