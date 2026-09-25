// ignore_for_file: subtype_of_sealed_class

import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:drift/native.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/features/habits/data/repositories/habits_repository.dart';

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
  final String documentId;
  final Map<String, dynamic> values;

  _Document(this.documentId, this.values);

  @override
  String get id => documentId;

  @override
  Map<String, dynamic> data() => values;
}

class _Snapshot extends Fake implements QuerySnapshot<Map<String, dynamic>> {
  _Snapshot(this.docs);

  @override
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> docs;
}

// ignore: must_be_immutable
class _Collection extends Fake
    implements CollectionReference<Map<String, dynamic>> {
  Future<void> Function()? beforeGet;
  bool remotePresent = true;
  bool failGet = false;
  String documentId = 'habit-1';
  Map<String, dynamic> values = {
    'title': 'Remote',
    'completedDates': ['2026-09-06'],
  };

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
    return _Snapshot(remotePresent ? [_Document(documentId, values)] : []);
  }
}

class _UserDocument extends Fake
    implements DocumentReference<Map<String, dynamic>> {
  final _Collection habits;

  _UserDocument(this.habits);

  @override
  CollectionReference<Map<String, dynamic>> collection(String path) {
    expect(path, 'habits');
    return habits;
  }
}

class _Firestore extends Fake implements FirebaseFirestore {
  final _Collection habits = _Collection();

  @override
  CollectionReference<Map<String, dynamic>> collection(String path) {
    expect(path, 'users');
    return habits;
  }
}

void main() {
  late AppDatabase db;
  late _Auth auth;
  late _Firestore firestore;
  late HabitsRepository repository;

  setUp(() {
    db = AppDatabase(executor: NativeDatabase.memory());
    auth = _Auth();
    firestore = _Firestore();
    repository = HabitsRepository(db, firestore, auth);
  });

  tearDown(() => db.close());

  Future<void> seed({List<String> dates = const ['2026-09-05']}) async {
    await db
        .into(db.habits)
        .insert(
          HabitsCompanion.insert(
            id: 'habit-1',
            title: 'Local',
            completedDates: jsonEncode(dates),
          ),
        );
  }

  Future<int> enqueue({
    String ownerUid = 'user-a',
    String collection = 'habits',
    String docId = 'habit-1',
    String operationType = 'update',
    int? createdAt,
  }) {
    return db.insertSyncItem(
      ownerUid: ownerUid,
      collection: collection,
      docId: docId,
      operationType: operationType,
      payloadJson: jsonEncode({
        if (operationType == 'batch_delete')
          'deletes': [
            {'collection': 'habits', 'docId': docId},
          ]
        else
          'completedDates': ['2026-09-05'],
      }),
      createdAt: createdAt,
    );
  }

  Future<List<String>> localDates() async {
    final habit = await db.select(db.habits).getSingle();
    return List<String>.from(jsonDecode(habit.completedDates));
  }

  test('without pending item Firebase hydrates habit normally', () async {
    await seed();

    await repository.syncHabitsFromFirebaseToLocal();

    expect(await localDates(), ['2026-09-06']);
  });

  test('remote absence removes unprotected local habit', () async {
    await seed();
    firestore.habits.remotePresent = false;

    await repository.syncHabitsFromFirebaseToLocal();

    expect(await db.select(db.habits).get(), isEmpty);
  });

  test('rejected create absent remotely removes optimistic habit', () async {
    await seed();
    firestore.habits.remotePresent = false;
    final id = await enqueue(operationType: 'create');
    await db.markSyncItemRejected(id, 'user-a', 'QUOTA_EXCEEDED');

    await repository.syncHabitsFromFirebaseToLocal();

    expect(await db.select(db.habits).get(), isEmpty);
  });

  test('pending create absent remotely preserves local habit', () async {
    await seed();
    firestore.habits.remotePresent = false;
    await enqueue(operationType: 'create');

    await repository.syncHabitsFromFirebaseToLocal();

    expect(await db.select(db.habits).get(), hasLength(1));
  });

  test('pending batch_delete protects affected habit from prune', () async {
    await seed();
    firestore.habits.remotePresent = false;
    await enqueue(collection: 'batch', operationType: 'batch_delete');

    await repository.syncHabitsFromFirebaseToLocal();

    expect(await db.select(db.habits).get(), hasLength(1));
  });

  test('old succeeded create absent remotely permits prune', () async {
    await seed();
    firestore.habits.remotePresent = false;
    final id = await enqueue(
      operationType: 'create',
      createdAt: DateTime.utc(2026, 1, 1).millisecondsSinceEpoch,
    );
    await db.markSyncItemAsSucceeded(id, 'user-a');

    await repository.syncHabitsFromFirebaseToLocal();

    expect(await db.select(db.habits).get(), isEmpty);
  });

  test('preexisting pending succeeds during GET and protects habit', () async {
    await seed();
    firestore.habits.remotePresent = false;
    final id = await enqueue(
      operationType: 'create',
      createdAt: DateTime.utc(2026, 1, 1).millisecondsSinceEpoch,
    );
    firestore.habits.beforeGet = () async {
      await db.markSyncItemAsSucceeded(id, 'user-a');
    };

    await repository.syncHabitsFromFirebaseToLocal();

    expect(await db.select(db.habits).get(), hasLength(1));
  });

  test(
    'preexisting pending rejected during GET does not protect habit',
    () async {
      await seed();
      firestore.habits.remotePresent = false;
      final id = await enqueue(
        operationType: 'create',
        createdAt: DateTime.utc(2026, 1, 1).millisecondsSinceEpoch,
      );
      firestore.habits.beforeGet = () async {
        await db.markSyncItemRejected(id, 'user-a', 'QUOTA_EXCEEDED');
      };

      await repository.syncHabitsFromFirebaseToLocal();

      expect(await db.select(db.habits).get(), isEmpty);
    },
  );

  test(
    'preexisting batch_delete succeeds during GET and protects habit',
    () async {
      await seed();
      firestore.habits.remotePresent = false;
      final id = await enqueue(
        collection: 'batch',
        operationType: 'batch_delete',
        createdAt: DateTime.utc(2026, 1, 1).millisecondsSinceEpoch,
      );
      firestore.habits.beforeGet = () async {
        await db.markSyncItemAsSucceeded(id, 'user-a');
      };

      await repository.syncHabitsFromFirebaseToLocal();

      expect(await db.select(db.habits).get(), hasLength(1));
    },
  );

  test('succeeded create during GET protects absent remote habit', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    firestore.habits.remotePresent = false;
    firestore.habits.beforeGet = () {
      started.complete();
      return release.future;
    };

    final pull = repository.syncHabitsFromFirebaseToLocal();
    await started.future;
    await seed();
    final id = await enqueue(operationType: 'create');
    await db.markSyncItemAsSucceeded(id, 'user-a');
    release.complete();
    await pull;

    expect(await db.select(db.habits).get(), hasLength(1));
  });

  test('succeeded batch_delete during GET protects affected habit', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    firestore.habits.remotePresent = false;
    firestore.habits.beforeGet = () {
      started.complete();
      return release.future;
    };

    final pull = repository.syncHabitsFromFirebaseToLocal();
    await started.future;
    await seed();
    final id = await enqueue(
      collection: 'batch',
      operationType: 'batch_delete',
    );
    await db.markSyncItemAsSucceeded(id, 'user-a');
    release.complete();
    await pull;

    expect(await db.select(db.habits).get(), hasLength(1));
  });

  test('failed server fetch does not prune habit', () async {
    await seed();
    firestore.habits.remotePresent = false;
    firestore.habits.failGet = true;

    await repository.syncHabitsFromFirebaseToLocal();

    expect(await db.select(db.habits).get(), hasLength(1));
  });

  test('UID change during absent snapshot does not prune habit', () async {
    await seed();
    firestore.habits.remotePresent = false;
    firestore.habits.beforeGet = () async {
      auth.currentUser = _User('user-b');
    };

    await repository.syncHabitsFromFirebaseToLocal();

    expect(await db.select(db.habits).get(), hasLength(1));
  });

  test('pending update protects local completedDates', () async {
    await seed();
    await repository.updateHabitDates('habit-1', ['2026-09-04']);

    await repository.syncHabitsFromFirebaseToLocal();

    expect(await localDates(), ['2026-09-04']);
  });

  test('pending batch_delete prevents resurrection', () async {
    await seed();
    await repository.deleteHabit('habit-1', 'Local');

    await repository.syncHabitsFromFirebaseToLocal();

    expect(await db.select(db.habits).get(), isEmpty);
  });

  test('succeeded update created during GET protects local dates', () async {
    await seed();
    final started = Completer<void>();
    final release = Completer<void>();
    firestore.habits.beforeGet = () {
      started.complete();
      return release.future;
    };

    final pull = repository.syncHabitsFromFirebaseToLocal();
    await started.future;
    await repository.updateHabitDates('habit-1', ['2026-09-04']);
    final pending =
        (await db.getPendingSyncItems('user-a')).single as SyncQueueTableData;
    await db.markSyncItemAsSucceeded(pending.id, 'user-a');
    release.complete();
    await pull;

    expect(await localDates(), ['2026-09-04']);
  });

  test(
    'succeeded batch_delete during in-flight fetch does not resurrect habit',
    () async {
      await seed();
      final started = Completer<void>();
      final release = Completer<void>();
      firestore.habits.beforeGet = () {
        started.complete();
        return release.future;
      };

      final pull = repository.syncHabitsFromFirebaseToLocal();
      await started.future;
      await repository.deleteHabit('habit-1', 'Local');
      final pending =
          (await db.getPendingSyncItems('user-a')).single as SyncQueueTableData;
      expect(pending.collection, 'batch');
      expect(pending.docId, 'habit-1');
      expect(pending.operationType, 'batch_delete');
      await db.markSyncItemAsSucceeded(pending.id, 'user-a');
      release.complete();
      await pull;

      expect(await db.select(db.habits).get(), isEmpty);
    },
  );

  test('succeeded item before pull permits remote hydration', () async {
    await seed();
    final id = await enqueue(
      createdAt: DateTime.utc(2026, 1, 1).millisecondsSinceEpoch,
    );
    await db.markSyncItemAsSucceeded(id, 'user-a');

    await repository.syncHabitsFromFirebaseToLocal();

    expect(await localDates(), ['2026-09-06']);
  });

  test('rejected item permits remote hydration', () async {
    await seed();
    final id = await enqueue();
    await db.markSyncItemRejected(id, 'user-a', 'INVALID_PAYLOAD');

    await repository.syncHabitsFromFirebaseToLocal();

    expect(await localDates(), ['2026-09-06']);
  });

  test('pending item from another owner does not block hydration', () async {
    await seed();
    await enqueue(ownerUid: 'user-b');

    await repository.syncHabitsFromFirebaseToLocal();

    expect(await localDates(), ['2026-09-06']);
  });

  test('session change during fetch prevents old-user write', () async {
    firestore.habits.beforeGet = () async {
      auth.currentUser = _User('user-b');
    };

    await repository.syncHabitsFromFirebaseToLocal();

    expect(await db.select(db.habits).get(), isEmpty);
  });

  test('pending item for another habit does not block hydration', () async {
    await seed();
    await enqueue(docId: 'habit-2');

    await repository.syncHabitsFromFirebaseToLocal();

    expect(await localDates(), ['2026-09-06']);
  });
}
