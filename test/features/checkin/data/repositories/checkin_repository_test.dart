// ignore_for_file: subtype_of_sealed_class

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/features/checkin/data/repositories/checkin_repository.dart';

class _User extends Fake implements User {
  _User(this.uid);

  @override
  final String uid;
}

class _Auth extends Fake implements FirebaseAuth {
  @override
  User? currentUser = _User('user-a');
}

class _RemoteDocument extends Fake
    implements QueryDocumentSnapshot<Map<String, dynamic>> {
  _RemoteDocument(this.id, this.values);

  @override
  final String id;
  final Map<String, dynamic> values;

  @override
  Map<String, dynamic> data() => values;
}

class _RemoteSnapshot extends Fake
    implements QuerySnapshot<Map<String, dynamic>> {
  _RemoteSnapshot(this.docs);

  @override
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> docs;
}

class _CheckInDocument extends Fake
    implements DocumentReference<Map<String, dynamic>> {
  _CheckInDocument(this.owner, this.id);

  final _Firestore owner;
  @override
  final String id;

  @override
  Future<void> set(Map<String, dynamic> data, [SetOptions? options]) async {
    owner.setCalls += 1;
    await owner.beforeSet?.call(id);
    if (owner.failSetIds.contains(id)) {
      throw FirebaseException(plugin: 'cloud_firestore', code: 'unavailable');
    }
    owner.writes[id] = Map<String, dynamic>.from(data);
  }
}

class _CheckInsCollection extends Fake
    implements CollectionReference<Map<String, dynamic>> {
  _CheckInsCollection(this.owner);

  final _Firestore owner;

  @override
  DocumentReference<Map<String, dynamic>> doc([String? path]) =>
      _CheckInDocument(owner, path!);

  @override
  Future<QuerySnapshot<Map<String, dynamic>>> get([GetOptions? options]) async {
    await owner.beforeGet?.call();
    return _RemoteSnapshot([
      for (final entry in owner.remoteDocs.entries)
        _RemoteDocument(entry.key, entry.value),
    ]);
  }
}

class _UserDocument extends Fake
    implements DocumentReference<Map<String, dynamic>> {
  _UserDocument(this.owner);

  final _Firestore owner;

  @override
  CollectionReference<Map<String, dynamic>> collection(String path) {
    expect(path, 'checkins');
    return _CheckInsCollection(owner);
  }
}

class _UsersCollection extends Fake
    implements CollectionReference<Map<String, dynamic>> {
  _UsersCollection(this.owner);

  final _Firestore owner;

  @override
  DocumentReference<Map<String, dynamic>> doc([String? path]) {
    owner.lastUid = path;
    return _UserDocument(owner);
  }
}

class _Firestore extends Fake implements FirebaseFirestore {
  final remoteDocs = <String, Map<String, dynamic>>{};
  final writes = <String, Map<String, dynamic>>{};
  final failSetIds = <String>{};
  Future<void> Function()? beforeGet;
  Future<void> Function(String id)? beforeSet;
  String? lastUid;
  int setCalls = 0;

  @override
  CollectionReference<Map<String, dynamic>> collection(String path) {
    expect(path, 'users');
    return _UsersCollection(this);
  }
}

void main() {
  late AppDatabase db;
  late _Auth auth;
  late _Firestore firestore;
  late CheckInRepository repository;

  setUp(() {
    db = AppDatabase(executor: NativeDatabase.memory());
    auth = _Auth();
    firestore = _Firestore();
    repository = CheckInRepository(db, firestore, auth);
  });

  tearDown(() async => db.close());

  Future<void> seed(String id, double energy, {bool isSynced = false}) {
    return db
        .insertCheckIn(
          CheckInTableCompanion(
            id: Value(id),
            energy: Value(energy),
            focus: const Value(3),
            motivation: const Value(4),
            createdAt: Value(DateTime.utc(2026, 9, 24, 10)),
            isSynced: Value(isSynced),
          ),
        )
        .then((_) {});
  }

  test('pull não sobrescreve check-in local pendente do mesmo ID', () async {
    await seed('2026-09-24', 5);
    firestore.remoteDocs['2026-09-24'] = {
      'energy': 1,
      'focus': 1,
      'motivation': 1,
      'updatedAt': Timestamp.fromDate(DateTime.utc(2026, 9, 23)),
    };

    await repository.syncCheckinsFromFirebaseToLocal();

    final local = await db.select(db.checkInTable).getSingle();
    expect(local.energy, 5);
    expect(local.focus, 3);
    expect(local.isSynced, isFalse);
  });

  test('pull hidrata registro remoto sem pendência conflitante', () async {
    firestore.remoteDocs['2026-09-24'] = {
      'energy': 2,
      'focus': 3,
      'motivation': 4,
      'updatedAt': Timestamp.fromDate(DateTime.utc(2026, 9, 24)),
    };

    await repository.syncCheckinsFromFirebaseToLocal();

    final local = await db.select(db.checkInTable).getSingle();
    expect(local.energy, 2);
    expect(local.isSynced, isTrue);
    expect(firestore.lastUid, 'user-a');
  });

  test(
    'replay retorna sucesso somente após enviar todos os pendentes',
    () async {
      await seed('2026-09-23', 2);
      await seed('2026-09-24', 3);

      expect(await repository.syncPendingCheckIns(), isTrue);
      expect(firestore.setCalls, 2);
      expect(firestore.lastUid, 'user-a');
      expect(
        (await db.select(db.checkInTable).get()).every((row) => row.isSynced),
        isTrue,
      );
      expect(await repository.syncPendingCheckIns(), isTrue);
      expect(firestore.setCalls, 2);
    },
  );

  test('falha remota mantém pendência e retorna false', () async {
    await seed('2026-09-23', 2);
    await seed('2026-09-24', 3);
    firestore.failSetIds.add('2026-09-24');

    expect(await repository.syncPendingCheckIns(), isFalse);
    final rows = await db.select(db.checkInTable).get();
    expect(rows.singleWhere((row) => row.id == '2026-09-23').isSynced, isTrue);
    expect(rows.singleWhere((row) => row.id == '2026-09-24').isSynced, isFalse);
  });

  test('timeout remoto mantém check-in e valores locais pendentes', () async {
    await seed('2026-09-24', 3);
    final started = Completer<void>();
    final release = Completer<void>();
    firestore.beforeSet = (_) async {
      started.complete();
      await release.future;
    };
    repository = CheckInRepository(
      db,
      firestore,
      auth,
      remoteWriteTimeout: const Duration(milliseconds: 10),
    );

    final replay = repository.syncPendingCheckIns();
    await started.future;
    expect(await replay, isFalse);

    final local = await db.select(db.checkInTable).getSingle();
    expect(local.id, '2026-09-24');
    expect(local.energy, 3);
    expect(local.focus, 3);
    expect(local.motivation, 4);
    expect(local.isSynced, isFalse);

    release.complete();
    await release.future;
    expect((await db.select(db.checkInTable).getSingle()).isSynced, isFalse);
  });

  test('troca de UID durante upload não marca check-in entregue', () async {
    await seed('2026-09-24', 3);
    firestore.beforeSet = (_) async => auth.currentUser = _User('user-b');

    expect(await repository.syncPendingCheckIns(), isFalse);
    expect((await db.select(db.checkInTable).getSingle()).isSynced, isFalse);
    expect(firestore.lastUid, 'user-a');
  });

  test('edição local durante upload antigo permanece pendente', () async {
    await seed('2026-09-24', 2);
    final started = Completer<void>();
    final release = Completer<void>();
    firestore.beforeSet = (_) async {
      started.complete();
      await release.future;
    };

    final replay = repository.syncPendingCheckIns();
    await started.future;
    await seed('2026-09-24', 5);
    release.complete();

    expect(await replay, isFalse);
    final local = await db.select(db.checkInTable).getSingle();
    expect(local.energy, 5);
    expect(local.isSynced, isFalse);
  });

  test('troca de UID após fetch não aplica snapshot de A', () async {
    firestore.remoteDocs['2026-09-24'] = {
      'energy': 2,
      'focus': 3,
      'motivation': 4,
      'updatedAt': Timestamp.fromDate(DateTime.utc(2026, 9, 24)),
    };
    firestore.beforeGet = () async => auth.currentUser = _User('user-b');

    await repository.syncCheckinsFromFirebaseToLocal();

    expect(await db.select(db.checkInTable).get(), isEmpty);
  });
}
