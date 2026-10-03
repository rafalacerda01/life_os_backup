// ignore_for_file: subtype_of_sealed_class

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
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
  Future<void> deleteNotification(String id) async {
    await super.deleteNotification(id);
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
    id: 'notification-a',
    title: 'Private fixture',
    description: 'Fixture',
    priority: 'normal',
    moduleType: 'health',
    route: '/health',
    isRead: false,
    isCompleted: false,
    createdAt: day,
  );
  const path = 'users/user-a/notifications/notification-a';

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
      expect(operation == 'delete' ? firestore.deletes : firestore.writes, [
        path,
      ]);
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
