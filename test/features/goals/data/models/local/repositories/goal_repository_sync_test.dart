// ignore_for_file: subtype_of_sealed_class

import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:drift/native.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/features/goals/data/models/local/repositories/goal_repository.dart';

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
  final Map<String, dynamic> values;

  _Document(this.values);

  @override
  String get id => 'goal-1';

  @override
  Map<String, dynamic> data() => values;
}

class _Snapshot extends Fake implements QuerySnapshot<Map<String, dynamic>> {
  final Map<String, dynamic> values;

  _Snapshot(this.values);

  @override
  List<QueryDocumentSnapshot<Map<String, dynamic>>> get docs => [
    _Document(values),
  ];
}

// ignore: must_be_immutable
class _Collection extends Fake
    implements CollectionReference<Map<String, dynamic>> {
  Future<void> Function()? beforeGet;
  Map<String, dynamic> values = {
    'title': 'Remote',
    'period': 'DIÁRIA',
    'currentValue': 8,
    'targetValue': 10,
    'createdAt': Timestamp.fromDate(DateTime.utc(2026, 9, 1)),
    'lastReset': Timestamp.fromDate(DateTime.utc(2026, 9, 2)),
  };

  @override
  DocumentReference<Map<String, dynamic>> doc([String? path]) {
    expect(path, 'user-a');
    return _UserDocument(this);
  }

  @override
  Future<QuerySnapshot<Map<String, dynamic>>> get([GetOptions? options]) async {
    await beforeGet?.call();
    return _Snapshot(values);
  }
}

class _UserDocument extends Fake
    implements DocumentReference<Map<String, dynamic>> {
  final _Collection goals;

  _UserDocument(this.goals);

  @override
  CollectionReference<Map<String, dynamic>> collection(String path) {
    expect(path, 'goals');
    return goals;
  }
}

class _Firestore extends Fake implements FirebaseFirestore {
  final _Collection goals = _Collection();

  @override
  CollectionReference<Map<String, dynamic>> collection(String path) {
    expect(path, 'users');
    return goals;
  }
}

void main() {
  late AppDatabase db;
  late _Auth auth;
  late _Firestore firestore;
  late GoalRepository repository;

  setUp(() {
    db = AppDatabase(executor: NativeDatabase.memory());
    auth = _Auth();
    firestore = _Firestore();
    repository = GoalRepository(db, firestore, auth);
  });

  tearDown(() => db.close());

  Future<void> seed({int currentValue = 1}) async {
    await db
        .into(db.goals)
        .insert(
          GoalsCompanion.insert(
            id: 'goal-1',
            title: 'Local',
            period: 'DIÁRIA',
            currentValue: currentValue,
            targetValue: 10,
            createdAt: DateTime.utc(2026, 8, 1).millisecondsSinceEpoch,
            lastReset: DateTime.utc(2026, 8, 2).millisecondsSinceEpoch,
          ),
        );
  }

  Future<int> enqueue(
    String operation, {
    String ownerUid = 'user-a',
    int? createdAt,
  }) {
    return db.insertSyncItem(
      ownerUid: ownerUid,
      collection: 'goals',
      docId: 'goal-1',
      operationType: operation,
      payloadJson: jsonEncode({'currentValue': 2}),
      createdAt: createdAt,
    );
  }

  test('update progress writes Drift and pending queue with owner', () async {
    await seed();

    await repository.updateGoalProgress('goal-1', 2);

    expect((await db.select(db.goals).getSingle()).currentValue, 2);
    final item =
        (await db.getPendingSyncItems('user-a')).single as SyncQueueTableData;
    expect(item.ownerUid, 'user-a');
    expect(item.collection, 'goals');
    expect(item.docId, 'goal-1');
    expect(item.operationType, 'update');
    expect(jsonDecode(item.payloadJson), {'currentValue': 2});
  });

  test('pending update protects local progress from stale remote', () async {
    await seed(currentValue: 2);
    await enqueue('update');

    await repository.syncGoalsFromFirebaseToLocal();

    expect((await db.select(db.goals).getSingle()).currentValue, 2);
  });

  test('pending delete prevents resurrection', () async {
    await enqueue('delete');

    await repository.syncGoalsFromFirebaseToLocal();

    expect(await db.select(db.goals).get(), isEmpty);
  });

  test('without pending remote hydrates normally', () async {
    await seed();

    await repository.syncGoalsFromFirebaseToLocal();

    expect((await db.select(db.goals).getSingle()).currentValue, 8);
  });

  test('succeeded created during GET protects local state', () async {
    await seed(currentValue: 1);
    final started = Completer<void>();
    final release = Completer<void>();
    firestore.goals.beforeGet = () {
      started.complete();
      return release.future;
    };

    final pull = repository.syncGoalsFromFirebaseToLocal();
    await started.future;
    await repository.updateGoalProgress('goal-1', 3);
    final pending =
        (await db.getPendingSyncItems('user-a')).single as SyncQueueTableData;
    await db.markSyncItemAsSucceeded(pending.id, 'user-a');
    release.complete();
    await pull;

    expect((await db.select(db.goals).getSingle()).currentValue, 3);
  });

  test(
    'succeeded delete during in-flight fetch does not resurrect goal',
    () async {
      await seed();
      final started = Completer<void>();
      final release = Completer<void>();
      firestore.goals.beforeGet = () {
        started.complete();
        return release.future;
      };

      final pull = repository.syncGoalsFromFirebaseToLocal();
      await started.future;
      await repository.removeGoal('goal-1');
      final pending =
          (await db.getPendingSyncItems('user-a')).single as SyncQueueTableData;
      expect(pending.collection, 'goals');
      expect(pending.docId, 'goal-1');
      expect(pending.operationType, 'delete');
      await db.markSyncItemAsSucceeded(pending.id, 'user-a');
      release.complete();
      await pull;

      expect(await db.select(db.goals).get(), isEmpty);
    },
  );

  test('succeeded before pull permits fresh hydration', () async {
    await seed();
    final id = await enqueue(
      'update',
      createdAt: DateTime.utc(2026, 1, 1).millisecondsSinceEpoch,
    );
    await db.markSyncItemAsSucceeded(id, 'user-a');

    await repository.syncGoalsFromFirebaseToLocal();

    expect((await db.select(db.goals).getSingle()).currentValue, 8);
  });

  test('rejected item permits fresh hydration', () async {
    await seed();
    final id = await enqueue('update');
    await db.markSyncItemRejected(id, 'user-a', 'INVALID_PAYLOAD');

    await repository.syncGoalsFromFirebaseToLocal();

    expect((await db.select(db.goals).getSingle()).currentValue, 8);
  });

  test('pending item from another owner does not block hydration', () async {
    await seed();
    await enqueue('update', ownerUid: 'user-b');

    await repository.syncGoalsFromFirebaseToLocal();

    expect((await db.select(db.goals).getSingle()).currentValue, 8);
  });

  test('session change during fetch prevents old-user write', () async {
    firestore.goals.beforeGet = () async {
      auth.currentUser = _User('user-b');
    };

    await repository.syncGoalsFromFirebaseToLocal();

    expect(await db.select(db.goals).get(), isEmpty);
  });

  test('Timestamp dates hydrate correctly', () async {
    await repository.syncGoalsFromFirebaseToLocal();

    final goal = await db.select(db.goals).getSingle();
    expect(goal.createdAt, DateTime.utc(2026, 9, 1).millisecondsSinceEpoch);
    expect(goal.lastReset, DateTime.utc(2026, 9, 2).millisecondsSinceEpoch);
  });

  test('legacy ISO lastReset hydrates correctly', () async {
    firestore.goals.values['lastReset'] = '2026-09-03T10:00:00.000Z';

    await repository.syncGoalsFromFirebaseToLocal();

    expect(
      (await db.select(db.goals).getSingle()).lastReset,
      DateTime.parse('2026-09-03T10:00:00.000Z').millisecondsSinceEpoch,
    );
  });

  test('invalid legacy lastReset falls back to createdAt', () async {
    firestore.goals.values['lastReset'] = 'invalid';

    await repository.syncGoalsFromFirebaseToLocal();

    final goal = await db.select(db.goals).getSingle();
    expect(goal.lastReset, goal.createdAt);
  });
}
