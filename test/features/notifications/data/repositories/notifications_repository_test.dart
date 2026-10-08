// ignore_for_file: subtype_of_sealed_class

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/local_mutation_gate.dart';
import 'package:life_os/core/services/notification_preferences.dart';
import 'package:life_os/features/notifications/data/daos/notification_dao.dart';
import 'package:life_os/features/notifications/data/repositories/notifications_repository.dart';
import 'package:life_os/features/notifications/domain/models/notification_model.dart';
import 'package:life_os/features/notifications/domain/providers/notification_engine.dart';

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

class _Firestore extends Fake implements FirebaseFirestore {
  final writes = <String>[];
  final deletes = <String>[];
  final reads = <String>[];
  final documents = <String, Map<String, dynamic>>{};
  final writeStarted = Completer<void>();
  Completer<void>? writeRelease;
  Completer<void>? readRelease;
  final readStarted = Completer<void>();
  Object? writeError;

  @override
  CollectionReference<Map<String, dynamic>> collection(String path) =>
      _Collection(this, path);
}

class _Collection extends Fake
    implements CollectionReference<Map<String, dynamic>> {
  _Collection(this.owner, this.path);
  final _Firestore owner;
  @override
  final String path;
  @override
  DocumentReference<Map<String, dynamic>> doc([String? id]) =>
      _Document(owner, '$path/$id');
  @override
  Future<QuerySnapshot<Map<String, dynamic>>> get([GetOptions? options]) async {
    owner.reads.add(path);
    if (!owner.readStarted.isCompleted) owner.readStarted.complete();
    await owner.readRelease?.future;
    return _Snapshot(
      owner.documents.entries
          .where((entry) => entry.key.startsWith('$path/'))
          .map(
            (entry) => _QueryDocument(entry.key.split('/').last, entry.value),
          )
          .toList(),
    );
  }
}

class _Document extends Fake
    implements DocumentReference<Map<String, dynamic>> {
  _Document(this.owner, this.path);
  final _Firestore owner;
  @override
  final String path;
  @override
  CollectionReference<Map<String, dynamic>> collection(String name) =>
      _Collection(owner, '$path/$name');
  @override
  Future<void> set(Map<String, dynamic> data, [SetOptions? options]) async {
    owner.writes.add(path);
    if (!owner.writeStarted.isCompleted) owner.writeStarted.complete();
    await owner.writeRelease?.future;
    if (owner.writeError != null) throw owner.writeError!;
    owner.documents[path] = Map.of(data);
  }

  @override
  Future<void> delete() async {
    owner.deletes.add(path);
    owner.documents.remove(path);
  }
}

class _Snapshot extends Fake implements QuerySnapshot<Map<String, dynamic>> {
  _Snapshot(this.docs);
  @override
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> docs;
}

class _QueryDocument extends Fake
    implements QueryDocumentSnapshot<Map<String, dynamic>> {
  _QueryDocument(this.id, this.value);
  @override
  final String id;
  final Map<String, dynamic> value;
  @override
  Map<String, dynamic> data() => value;
}

class _BlockingDao extends NotificationDao {
  _BlockingDao(super.db);
  String? block;
  final started = Completer<void>();
  final release = Completer<void>();

  Future<void> pause(String operation) async {
    if (block != operation) return;
    if (!started.isCompleted) started.complete();
    await release.future;
  }

  @override
  Future<bool> upsertPreservingState(
    NotificationsTableCompanion incoming, {
    LocalMutationTicket? admission,
  }) async {
    final result = await super.upsertPreservingState(
      incoming,
      admission: admission,
    );
    await pause('save');
    return result;
  }

  @override
  Future<bool> upsertFromRemote(
    NotificationsTableCompanion incoming, {
    LocalMutationTicket? admission,
  }) async {
    await pause('hydrate');
    return super.upsertFromRemote(incoming, admission: admission);
  }

  @override
  Future<void> markAsRead(String id) async {
    await super.markAsRead(id);
    await pause('read');
  }

  @override
  Future<void> markAsCompleted(String id) async {
    await super.markAsCompleted(id);
    await pause('complete');
  }

  @override
  Future<void> dismissNotification(String id, String ownerUid) async {
    await super.dismissNotification(id, ownerUid);
    await pause('delete');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late _Auth auth;
  late _Firestore firestore;
  late _BlockingDao dao;
  late NotificationRemoteEffectsBarrier barrier;
  late NotificationsRepository repository;
  final day = DateTime(2026, 10, 3, 12);
  final notification = NotificationModel(
    id: 'health_med_notification-a',
    title: 'Private fixture',
    description: 'Fixture',
    priority: 'normal',
    moduleType: 'health',
    route: '/health',
    isRead: false,
    isCompleted: false,
    dueDate: day,
    createdAt: day,
  );
  const path = 'users/user-a/notifications/health_med_notification-a';

  setUp(() {
    db = AppDatabase(executor: NativeDatabase.memory());
    auth = _Auth();
    firestore = _Firestore();
    dao = _BlockingDao(db);
    barrier = NotificationRemoteEffectsBarrier();
    repository = NotificationsRepository(
      firestore: firestore,
      auth: auth,
      localDao: dao,
      remoteEffects: barrier,
    );
  });
  tearDown(() async {
    if (!dao.release.isCompleted) dao.release.complete();
    await barrier.sealAndDrain();
    await db.close();
  });

  Future<void> seed() => db
      .into(db.notificationsTable)
      .insert(NotificationModel.toCompanion(notification))
      .then((_) {});

  for (final operation in ['save', 'read', 'complete', 'delete']) {
    test('$operation A to B during local await never targets B', () async {
      if (operation != 'save') await seed();
      dao.block = operation;
      final future = switch (operation) {
        'save' => repository.saveLocalNotification(notification),
        'read' => repository.markAsReadLocal(notification.id),
        'complete' => repository.markAsCompletedLocal(notification.id),
        _ => repository.deleteNotification(notification.id),
      };
      await dao.started.future;
      auth.user = _User('user-b');
      dao.release.complete();
      await future;
      await barrier.sealAndDrain();
      expect(firestore.writes, isEmpty);
      expect(firestore.deletes, isEmpty);
    });
  }

  for (final operation in ['save', 'read', 'complete', 'delete']) {
    test('$operation in stable session targets only captured A', () async {
      if (operation != 'save') await seed();
      switch (operation) {
        case 'save':
          await repository.saveLocalNotification(notification);
        case 'read':
          await repository.markAsReadLocal(notification.id);
        case 'complete':
          await repository.markAsCompletedLocal(notification.id);
        case 'delete':
          await repository.deleteNotification(notification.id);
      }
      await barrier.sealAndDrain();
      if (operation == 'delete') {
        expect(firestore.deletes, isEmpty);
        final item = (await db.getPendingSyncItems('user-a')).single;
        expect(item.collection, 'notifications');
        expect(item.docId, notification.id);
        expect(item.operationType, 'delete');
      } else {
        expect(firestore.writes, [path]);
      }
    });
  }

  test(
    'no Firebase user preserves local save without remote effects',
    () async {
      auth.user = null;
      await repository.saveLocalNotification(notification);
      await barrier.sealAndDrain();
      expect(await dao.getNotificationById(notification.id), isNotNull);
      expect(firestore.writes, isEmpty);
    },
  );

  test('SDK write remains tracked after local return and UID change', () async {
    final release = Completer<void>();
    firestore.writeRelease = release;
    await repository.saveLocalNotification(notification);
    await firestore.writeStarted.future;
    auth.user = _User('user-b');
    var drained = false;
    final drain = barrier.sealAndDrain().then((_) => drained = true);
    expect(drained, isFalse);
    expect(barrier.resume(), isFalse);
    expect(firestore.writes, [path]);
    release.complete();
    await drain;
    expect(drained, isTrue);
    expect(firestore.documents.keys, [path]);
    expect(barrier.resume(), isTrue);
  });

  test(
    'sealed cleanup invalidates a local continuation before deletion',
    () async {
      dao.block = 'save';
      final save = repository.saveLocalNotification(notification);
      await dao.started.future;
      final drain = barrier.sealAndDrain();
      dao.release.complete();
      await save;
      await drain;
      await db.clearAllData();
      firestore.documents.clear();
      await repository.saveLocalNotification(notification);
      await barrier.sealAndDrain();
      expect(firestore.writes, isEmpty);
      expect(firestore.documents, isEmpty);
    },
  );

  test(
    'remote failure does not escape or roll back offline local data',
    () async {
      firestore.writeError = StateError('technical-notification-marker');
      await expectLater(
        repository.saveLocalNotification(notification),
        completes,
      );
      await barrier.sealAndDrain();
      expect(await dao.getNotificationById(notification.id), isNotNull);
      expect(firestore.documents, isEmpty);
    },
  );

  const states = [(false, false), (true, false), (false, true), (true, true)];
  for (final (localRead, localCompleted) in states) {
    for (final (remoteRead, remoteCompleted) in states) {
      test('same occurrence merges local $localRead/$localCompleted '
          'with remote $remoteRead/$remoteCompleted without echo', () async {
        await db
            .into(db.notificationsTable)
            .insert(
              NotificationModel.toCompanion(
                notification.copyWith(
                  isRead: localRead,
                  isCompleted: localCompleted,
                ),
              ),
            );
        firestore.documents[path] = notification
            .copyWith(
              isRead: remoteRead,
              isCompleted: remoteCompleted,
              createdAt: day.add(const Duration(days: 2)),
            )
            .toFirestore();

        await repository.syncNotificationsFromFirebaseToLocal();

        final result = (await dao.getNotificationById(notification.id))!;
        expect(result.isRead, localRead || remoteRead);
        expect(result.isCompleted, localCompleted || remoteCompleted);
        expect(result.createdAt, day);
        expect(result.dueDate, day);
        expect(firestore.writes, isEmpty);
        expect(firestore.deletes, isEmpty);
        expect(await db.select(db.syncQueueTable).get(), isEmpty);
      });
    }
  }

  for (final oldState in [false, true]) {
    for (final (remoteRead, remoteCompleted) in states) {
      test('new occurrence honors remote $remoteRead/$remoteCompleted '
          'without inheriting old $oldState/$oldState', () async {
        await db
            .into(db.notificationsTable)
            .insert(
              NotificationModel.toCompanion(
                notification.copyWith(isRead: oldState, isCompleted: oldState),
              ),
            );
        final next = notification.copyWith(
          dueDate: day.add(const Duration(days: 1)),
          createdAt: day.add(const Duration(days: 2)),
          isRead: remoteRead,
          isCompleted: remoteCompleted,
        );
        firestore.documents[path] = next.toFirestore();

        await repository.syncNotificationsFromFirebaseToLocal();

        final result = (await dao.getNotificationById(notification.id))!;
        expect(result.isRead, remoteRead);
        expect(result.isCompleted, remoteCompleted);
        expect(result.dueDate, next.dueDate);
        expect(
          result.occurrenceKey,
          NotificationModel.toCompanion(next).occurrenceKey.value,
        );
        expect(result.createdAt, day);
        expect(firestore.writes, isEmpty);
      });
    }
  }

  for (final (label, shift) in [
    ('different hour', const Duration(hours: 1)),
    ('one microsecond', const Duration(microseconds: 1)),
  ]) {
    for (final remoteRead in [false, true]) {
      test('distinct occurrence on same day ($label) honors remote '
          '$remoteRead/false without inheritance', () async {
        final previous = notification.copyWith(
          id: 'exam_matematica',
          moduleType: 'studies',
          dueDate: DateTime(2026, 10, 10, 9),
          isRead: true,
          isCompleted: true,
        );
        final next = previous.copyWith(
          dueDate: previous.dueDate!.add(shift),
          isRead: remoteRead,
          isCompleted: false,
        );
        final oldCompanion = NotificationModel.toCompanion(previous);
        final nextCompanion = NotificationModel.toCompanion(next);
        expect(
          oldCompanion.occurrenceKey.value,
          isNot(nextCompanion.occurrenceKey.value),
        );
        await db.into(db.notificationsTable).insert(oldCompanion);
        firestore.documents['users/user-a/notifications/${next.id}'] = next
            .toFirestore();

        await repository.syncNotificationsFromFirebaseToLocal();

        final result = (await dao.getNotificationById(next.id))!;
        expect(result.isRead, remoteRead);
        expect(result.isCompleted, isFalse);
        expect(result.occurrenceKey, nextCompanion.occurrenceKey.value);
        expect(NotificationModel.fromDrift(result).dueDate, next.dueDate);
        expect(result.createdAt, previous.createdAt);
        expect(firestore.writes, isEmpty);
      });
    }
  }

  test('exact occurrence key preserves flags despite Drift rounding', () async {
    final precise = notification.copyWith(
      dueDate: day.add(const Duration(microseconds: 123)),
      isRead: true,
      isCompleted: true,
    );
    await db
        .into(db.notificationsTable)
        .insert(NotificationModel.toCompanion(precise));
    final stored = (await dao.getNotificationById(precise.id))!;
    expect(stored.dueDate, isNot(precise.dueDate));
    firestore.documents[path] = precise
        .copyWith(isRead: false, isCompleted: false)
        .toFirestore();

    await repository.syncNotificationsFromFirebaseToLocal();

    final result = (await dao.getNotificationById(precise.id))!;
    expect(result.isRead, isTrue);
    expect(result.isCompleted, isTrue);
    expect(result.occurrenceKey, stored.occurrenceKey);
    expect(NotificationModel.fromDrift(result).dueDate, precise.dueDate);
    expect(firestore.writes, isEmpty);
  });

  for (final shift in [
    const Duration(hours: 1),
    const Duration(microseconds: 1),
  ]) {
    test(
      'local generation still preserves same-day flags after $shift',
      () async {
        final previous = notification.copyWith(isRead: true, isCompleted: true);
        await db
            .into(db.notificationsTable)
            .insert(NotificationModel.toCompanion(previous));
        final next = notification.copyWith(
          dueDate: day.add(shift),
          title: 'Updated derived content',
        );

        await repository.saveLocalNotification(next);
        await barrier.sealAndDrain();

        final result = (await dao.getNotificationById(next.id))!;
        expect(result.title, next.title);
        expect(result.isRead, isTrue);
        expect(result.isCompleted, isTrue);
        expect(
          result.occurrenceKey,
          NotificationModel.toCompanion(next).occurrenceKey.value,
        );
      },
    );
  }

  for (final completed in [false, true]) {
    test(
      'new same-day habit occurrence keeps derived completion $completed',
      () async {
        final previous = notification.copyWith(
          id: 'habit_remote',
          moduleType: 'habits',
          priority: 'completed',
          isRead: true,
          isCompleted: true,
        );
        await db
            .into(db.notificationsTable)
            .insert(NotificationModel.toCompanion(previous));
        final next = previous.copyWith(
          dueDate: day.add(const Duration(hours: 1)),
          priority: completed ? 'completed' : 'today',
          isRead: false,
          isCompleted: completed,
        );
        firestore.documents['users/user-a/notifications/${next.id}'] = next
            .toFirestore();

        await repository.syncNotificationsFromFirebaseToLocal();

        final result = (await dao.getNotificationById(next.id))!;
        expect(result.isRead, completed);
        expect(result.isCompleted, completed);
        expect(firestore.writes, isEmpty);
      },
    );
  }

  for (final remoteRead in [false, true]) {
    test(
      'legacy null key does not prove identity; honors remote $remoteRead/false',
      () async {
        final previous = notification.copyWith(
          dueDate: day.add(const Duration(microseconds: 123)),
          isRead: true,
          isCompleted: true,
        );
        await db
            .into(db.notificationsTable)
            .insert(
              NotificationModel.toCompanion(
                previous,
              ).copyWith(occurrenceKey: const Value(null)),
            );
        final next = previous.copyWith(isRead: remoteRead, isCompleted: false);
        firestore.documents[path] = next.toFirestore();

        await repository.syncNotificationsFromFirebaseToLocal();

        final result = (await dao.getNotificationById(next.id))!;
        expect(result.isRead, remoteRead);
        expect(result.isCompleted, isFalse);
        expect(
          result.occurrenceKey,
          NotificationModel.toCompanion(next).occurrenceKey.value,
        );
        expect(result.createdAt, previous.createdAt);
        expect(firestore.writes, isEmpty);
      },
    );
  }

  test('two null keys do not establish a shared legacy occurrence', () async {
    final legacy = notification.copyWith(
      moduleType: 'general',
      isRead: true,
      isCompleted: true,
    );
    final incoming = legacy.copyWith(isRead: false, isCompleted: false);
    expect(NotificationModel.toCompanion(legacy).occurrenceKey.value, isNull);
    expect(NotificationModel.toCompanion(incoming).occurrenceKey.value, isNull);
    await db
        .into(db.notificationsTable)
        .insert(NotificationModel.toCompanion(legacy));
    firestore.documents[path] = incoming.toFirestore();

    await repository.syncNotificationsFromFirebaseToLocal();

    final result = (await dao.getNotificationById(legacy.id))!;
    expect(result.isRead, isFalse);
    expect(result.isCompleted, isFalse);
    expect(result.occurrenceKey, isNull);
    expect(result.createdAt, legacy.createdAt);
    expect(firestore.writes, isEmpty);
  });

  for (final (localRead, localCompleted) in states.skip(1)) {
    test(
      'local generation preserves manual $localRead/$localCompleted',
      () async {
        await db
            .into(db.notificationsTable)
            .insert(
              NotificationModel.toCompanion(
                notification.copyWith(
                  isRead: localRead,
                  isCompleted: localCompleted,
                ),
              ),
            );

        await repository.saveLocalNotification(
          notification.copyWith(title: 'Updated derived content'),
        );
        await barrier.sealAndDrain();

        final result = (await dao.getNotificationById(notification.id))!;
        expect(result.title, 'Updated derived content');
        expect(result.isRead, localRead);
        expect(result.isCompleted, localCompleted);
        expect(firestore.documents[path]!['isRead'], localRead);
        expect(firestore.documents[path]!['isCompleted'], localCompleted);
      },
    );
  }

  test(
    'hydration merges the local state changed after reading remote',
    () async {
      await seed();
      firestore.documents[path] = notification.toFirestore();
      dao.block = 'hydrate';

      final hydration = repository.syncNotificationsFromFirebaseToLocal();
      await dao.started.future;
      // The remote false/false snapshot is already parsed; no upsert has begun.
      await dao.markAsCompleted(notification.id);
      dao.release.complete();
      await hydration;

      final result = (await dao.getNotificationById(notification.id))!;
      expect(result.isRead, isTrue);
      expect(result.isCompleted, isTrue);
      expect(firestore.writes, isEmpty);
    },
  );

  test('habit remote read survives the derived reopening branch', () async {
    final habit = notification.copyWith(
      id: 'habit_remote',
      moduleType: 'habits',
      priority: 'completed',
    );
    await db
        .into(db.notificationsTable)
        .insert(NotificationModel.toCompanion(habit));
    firestore.documents['users/user-a/notifications/${habit.id}'] = habit
        .copyWith(priority: 'today', isRead: true)
        .toFirestore();

    await repository.syncNotificationsFromFirebaseToLocal();

    final result = (await dao.getNotificationById(habit.id))!;
    expect(result.isRead, isTrue);
    expect(result.isCompleted, isFalse);
    expect(firestore.writes, isEmpty);
  });

  test(
    'habit remote hydration is monotonic while local undo still reopens',
    () async {
      final habit = notification.copyWith(
        id: 'habit_remote',
        moduleType: 'habits',
        priority: 'completed',
        isRead: true,
        isCompleted: true,
      );
      await db
          .into(db.notificationsTable)
          .insert(NotificationModel.toCompanion(habit));
      firestore.documents['users/user-a/notifications/${habit.id}'] = habit
          .copyWith(isRead: false, isCompleted: false)
          .toFirestore();

      await repository.syncNotificationsFromFirebaseToLocal();
      var result = (await dao.getNotificationById(habit.id))!;
      expect(result.isRead, isTrue);
      expect(result.isCompleted, isTrue);
      expect(firestore.writes, isEmpty);

      await repository.saveLocalNotification(
        habit.copyWith(priority: 'today', isRead: false, isCompleted: false),
      );
      result = (await dao.getNotificationById(habit.id))!;
      expect(result.isRead, isFalse);
      expect(result.isCompleted, isFalse);
    },
  );

  test('hydration captures A and rejects writes after switch to B', () async {
    db.localMutations.bindSessionReader(() => auth.currentUser?.uid);
    db.localMutations.openPreparedSession();
    firestore.documents[path] = notification.toFirestore();
    final release = Completer<void>();
    firestore.readRelease = release;
    final hydration = repository.syncNotificationsFromFirebaseToLocal();
    await firestore.readStarted.future;
    auth.user = _User('user-b');
    release.complete();
    await hydration;
    expect(firestore.reads, ['users/user-a/notifications']);
    expect(await dao.getAllNotifications(), isEmpty);
    expect(firestore.writes, isEmpty);
  });

  test('cancelled module bootstrap A cannot write its content to B', () async {
    await db
        .into(db.medications)
        .insert(
          MedicationsCompanion.insert(
            firestoreId: 'med-a',
            name: 'Private fixture',
            startDate: day,
          ),
        );
    dao.block = 'save';
    final bootstrap = const NotificationModuleReconciler().sync(
      repository: repository,
      db: db,
      preferences: const NotificationPreferences.enabled(),
      today: day,
      isCancelled: () => auth.currentUser?.uid != 'user-a',
    );
    await dao.started.future;
    auth.user = _User('user-b');
    dao.release.complete();
    await bootstrap;
    await barrier.sealAndDrain();
    expect(firestore.writes, isEmpty);
  });
}
