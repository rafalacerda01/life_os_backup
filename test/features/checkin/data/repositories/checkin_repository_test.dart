// ignore_for_file: subtype_of_sealed_class

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/local_mutation_gate.dart';
import 'package:life_os/features/checkin/data/repositories/checkin_repository.dart';
import 'package:life_os/features/ai_companion/data/models/ai_insight.dart';
import 'package:life_os/features/ai_companion/data/services/ai_insight_context_builder.dart';

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
    owner.remoteDocs[id] = {...?owner.remoteDocs[id], ...data};
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
    final snapshot = _RemoteSnapshot([
      for (final entry in owner.remoteDocs.entries)
        _RemoteDocument(entry.key, Map<String, dynamic>.from(entry.value)),
    ]);
    owner.lastSnapshot = snapshot;
    await owner.afterSnapshotCaptured?.call();
    return snapshot;
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
  Future<void> Function()? afterSnapshotCaptured;
  Future<void> Function(String id)? beforeSet;
  _RemoteSnapshot? lastSnapshot;
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

  Future<void> seed(
    String id,
    double energy, {
    bool isSynced = false,
    DateTime? createdAt,
  }) {
    return db
        .insertCheckIn(
          CheckInTableCompanion(
            id: Value(id),
            energy: Value(energy),
            focus: const Value(3),
            motivation: const Value(4),
            createdAt: Value(createdAt ?? DateTime.utc(2026, 9, 24, 10)),
            isSynced: Value(isSynced),
          ),
        )
        .then((_) {});
  }

  Future<({Future<void> pull, Completer<void> release})>
  holdCapturedPull() async {
    final captured = Completer<void>();
    final release = Completer<void>();
    firestore.afterSnapshotCaptured = () {
      firestore.afterSnapshotCaptured = null;
      captured.complete();
      return release.future;
    };
    final pull = repository.syncCheckinsFromFirebaseToLocal();
    addTearDown(() async {
      if (!release.isCompleted) release.complete();
      await pull;
    });
    await captured.future;
    return (pull: pull, release: release);
  }

  group('pull protects local revisions', () {
    const id = '2026-09-24';
    final storedDate = DateTime(2026, 9, 24, 10);

    void remote(double energy, {String checkInId = id}) {
      firestore.remoteDocs[checkInId] = {
        'energy': energy,
        'focus': 3.0,
        'motivation': 4.0,
      };
    }

    test('confirmed domain save survives a captured V0 snapshot', () async {
      final today = DateTime.now();
      final todayId =
          '${today.year.toString().padLeft(4, '0')}-'
          '${today.month.toString().padLeft(2, '0')}-'
          '${today.day.toString().padLeft(2, '0')}';
      await seed(todayId, 2, isSynced: true, createdAt: today);
      remote(2, checkInId: todayId);
      final held = await holdCapturedPull();

      await repository.saveDailyMetrics(energy: 5, focus: 3, motivation: 4);
      expect(await repository.syncPendingCheckIns(), isTrue);
      final confirmed = await db.select(db.checkInTable).getSingle();
      expect(confirmed.id, todayId);
      expect(confirmed.energy, 5);
      expect(confirmed.isSynced, isTrue);
      expect(firestore.remoteDocs[todayId]!['energy'], 5);
      expect(firestore.lastSnapshot!.docs.single.data()['energy'], 2);

      held.release.complete();
      await held.pull;

      expect(await db.select(db.checkInTable).getSingle(), confirmed);
      expect(firestore.remoteDocs[todayId]!['energy'], 5);
      expect(await db.getPendingCheckIns(), isEmpty);
    });

    test('row created and confirmed during GET is preserved', () async {
      remote(2);
      final held = await holdCapturedPull();
      await seed(id, 5, createdAt: storedDate);
      expect(await repository.syncPendingCheckIns(), isTrue);
      final confirmed = await db.select(db.checkInTable).getSingle();

      held.release.complete();
      await held.pull;

      expect(await db.select(db.checkInTable).getSingle(), confirmed);
      expect(firestore.remoteDocs[id]!['energy'], 5);
      expect(firestore.lastSnapshot!.docs.single.data()['energy'], 2);
    });

    test('two confirmed edits during one pull preserve the latest', () async {
      await seed(id, 2, isSynced: true, createdAt: storedDate);
      remote(2);
      final held = await holdCapturedPull();
      for (final energy in [3.0, 5.0]) {
        await seed(id, energy, createdAt: storedDate);
        expect(await repository.syncPendingCheckIns(), isTrue);
      }
      final confirmed = await db.select(db.checkInTable).getSingle();
      held.release.complete();
      await held.pull;

      expect(await db.select(db.checkInTable).getSingle(), confirmed);
      expect(confirmed.energy, 5);
      expect(firestore.remoteDocs[id]!['energy'], 5);
      expect(firestore.setCalls, 2);
    });

    test('ABA edits with identical stored timestamps are protected', () async {
      await seed(id, 2, isSynced: true, createdAt: storedDate);
      final baseline = await db.select(db.checkInTable).getSingle();
      remote(9);
      final held = await holdCapturedPull();
      for (final energy in [5.0, 2.0]) {
        await seed(id, energy, createdAt: storedDate);
        expect(await repository.syncPendingCheckIns(), isTrue);
      }
      expect(await db.select(db.checkInTable).getSingle(), baseline);
      held.release.complete();
      await held.pull;

      expect(await db.select(db.checkInTable).getSingle(), baseline);
      expect(firestore.remoteDocs[id]!['energy'], 2);
      expect(firestore.lastSnapshot!.docs.single.data()['energy'], 9);
    });

    test('identical confirmed replacement still counts as an edit', () async {
      await seed(id, 2, isSynced: true, createdAt: storedDate);
      final baseline = await db.select(db.checkInTable).getSingle();
      remote(9);
      final held = await holdCapturedPull();
      await seed(id, 2, createdAt: storedDate);
      expect(await repository.syncPendingCheckIns(), isTrue);
      expect(await db.select(db.checkInTable).getSingle(), baseline);
      held.release.complete();
      await held.pull;

      expect(await db.select(db.checkInTable).getSingle(), baseline);
    });

    test('edit remains pending while its upload is held', () async {
      await seed(id, 2, isSynced: true, createdAt: storedDate);
      remote(2);
      final held = await holdCapturedPull();
      await seed(id, 5, createdAt: storedDate);
      final uploadStarted = Completer<void>();
      final uploadRelease = Completer<void>();
      firestore.beforeSet = (_) {
        uploadStarted.complete();
        return uploadRelease.future;
      };
      final uploading = repository.syncPendingCheckIns();
      addTearDown(() async {
        if (!uploadRelease.isCompleted) uploadRelease.complete();
        await uploading;
      });
      await uploadStarted.future;
      held.release.complete();
      await held.pull;

      final pending = (await db.getPendingCheckIns()).single as CheckInEntry;
      expect(pending.energy, 5);
      expect(pending.createdAt, storedDate);
      expect(firestore.remoteDocs[id]!['energy'], 2);
      uploadRelease.complete();
      expect(await uploading, isTrue);
      expect(firestore.remoteDocs[id]!['energy'], 5);
    });

    test('failed upload and unrelated pending row survive the pull', () async {
      await seed(id, 2, isSynced: true, createdAt: storedDate);
      remote(2);
      final held = await holdCapturedPull();
      await seed(id, 5, createdAt: storedDate);
      firestore.failSetIds.add(id);
      expect(await repository.syncPendingCheckIns(), isFalse);
      await seed('2026-09-23', 4);
      final pending = await db.getPendingCheckIns();
      held.release.complete();
      await held.pull;

      expect(await db.getPendingCheckIns(), unorderedEquals(pending));
      expect(firestore.remoteDocs[id]!['energy'], 2);
      expect(firestore.writes, isEmpty);
    });

    test(
      'unchanged synced row permits hydration and keeps civil date',
      () async {
        await seed(id, 2, isSynced: true, createdAt: storedDate);
        remote(9);
        firestore.remoteDocs[id]!['updatedAt'] = Timestamp.fromDate(
          DateTime.utc(2100, 1, 1),
        );
        final held = await holdCapturedPull();
        held.release.complete();
        await held.pull;

        final local = await db.select(db.checkInTable).getSingle();
        expect(local.energy, 9);
        expect(local.createdAt, DateTime(2026, 9, 24));
        expect(local.createdAt.isUtc, isFalse);
        expect(local.isSynced, isTrue);
        expect(firestore.writes, isEmpty);
      },
    );

    test('UID switch rejects a previously captured snapshot', () async {
      await seed(id, 2, isSynced: true, createdAt: storedDate);
      final original = await db.select(db.checkInTable).getSingle();
      remote(9);
      final held = await holdCapturedPull();
      auth.currentUser = _User('user-b');
      held.release.complete();
      await held.pull;

      expect(await db.select(db.checkInTable).getSingle(), original);
      expect(firestore.writes, isEmpty);
    });

    test('reopening the same UID cannot revive an old pull ticket', () async {
      db.localMutations.bindSessionReader(() => auth.currentUser?.uid);
      db.localMutations.openPreparedSession();
      await seed(id, 2, isSynced: true, createdAt: storedDate);
      final original = await db.select(db.checkInTable).getSingle();
      remote(9);
      final held = await holdCapturedPull();
      final barrier = db.localMutations.beginQuiesce('user-a');
      await barrier.drain();
      auth.currentUser = null;
      db.localMutations.observeSession(null);
      barrier.finish(signOutConfirmed: true);
      auth.currentUser = _User('user-a');
      db.localMutations.observeSession('user-a');
      db.localMutations.openPreparedSession();
      held.release.complete();
      await held.pull;

      expect(await db.select(db.checkInTable).getSingle(), original);
      await repository.syncCheckinsFromFirebaseToLocal();
      expect((await db.select(db.checkInTable).getSingle()).energy, 9);
    });

    test('application failure rolls back every hydrated row', () async {
      await seed(id, 2, isSynced: true, createdAt: storedDate);
      await seed('2026-09-23', 4);
      final original = await db.select(db.checkInTable).get();
      final pending = await db.getPendingCheckIns();
      remote(9);
      firestore.remoteDocs['2026-09-25'] = {'energy': 'invalid'};
      final held = await holdCapturedPull();
      held.release.complete();
      await held.pull;

      expect(await db.select(db.checkInTable).get(), unorderedEquals(original));
      expect(await db.getPendingCheckIns(), unorderedEquals(pending));
      remote(3, checkInId: '2026-09-25');
      await repository.syncCheckinsFromFirebaseToLocal();
      final rows = await db.select(db.checkInTable).get();
      expect(rows.singleWhere((row) => row.id == id).energy, 9);
      expect(await db.getPendingCheckIns(), unorderedEquals(pending));
    });

    test('in-place value change is protected even with stable rowid', () async {
      await seed(id, 2, isSynced: true, createdAt: storedDate);
      remote(9);
      final held = await holdCapturedPull();
      await (db.update(db.checkInTable)..where((row) => row.id.equals(id)))
          .write(const CheckInTableCompanion(energy: Value(5)));
      held.release.complete();
      await held.pull;

      final local = await db.select(db.checkInTable).getSingle();
      expect(local.energy, 5);
      expect(local.createdAt, storedDate);
      expect(local.isSynced, isTrue);
    });

    test(
      'rolled-back replacement does not prevent legitimate hydration',
      () async {
        await seed(id, 2, isSynced: true, createdAt: storedDate);
        final original = await db.select(db.checkInTable).getSingle();
        remote(9);
        final held = await holdCapturedPull();
        await expectLater(
          db.transaction(() async {
            await seed(id, 5, isSynced: true, createdAt: storedDate);
            throw StateError('local write failed');
          }),
          throwsStateError,
        );
        expect(await db.select(db.checkInTable).getSingle(), original);
        held.release.complete();
        await held.pull;

        expect((await db.select(db.checkInTable).getSingle()).energy, 9);
      },
    );
  });

  test('pull não sobrescreve check-in local pendente do mesmo ID', () async {
    await seed('2026-09-24', 5);
    final original = await db.select(db.checkInTable).getSingle();
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
    expect(local.motivation, 4);
    expect(local.createdAt, original.createdAt);
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

  test('CheckIn drain acknowledges under quiescence', () async {
    db.localMutations.bindSessionReader(() => auth.currentUser?.uid);
    db.localMutations.openPreparedSession();
    await seed('2026-09-24', 3);
    final barrier = db.localMutations.beginQuiesce('user-a');
    expect(await repository.syncPendingCheckIns(), isTrue);
    expect((await db.select(db.checkInTable).getSingle()).isSynced, isTrue);
    barrier.finish(signOutConfirmed: false);
  });

  test('CheckIn domain save waits and resumes on same-session abort', () async {
    db.localMutations.bindSessionReader(() => auth.currentUser?.uid);
    db.localMutations.openPreparedSession();
    await db.customSelect('SELECT 1').get();
    final barrier = db.localMutations.beginQuiesce('user-a');
    final saving = repository.saveDailyMetrics(
      energy: 5,
      focus: 3,
      motivation: 4,
    );
    expect(await db.select(db.checkInTable).get(), isEmpty);
    barrier.finish(signOutConfirmed: false);
    await saving;
    await repository.syncPendingCheckIns();
    expect((await db.select(db.checkInTable).getSingle()).energy, 5);
  });

  test(
    'CheckIn waiting save cannot repopulate after confirmed sign-out',
    () async {
      db.localMutations.bindSessionReader(() => auth.currentUser?.uid);
      db.localMutations.openPreparedSession();
      await db.customSelect('SELECT 1').get();
      final barrier = db.localMutations.beginQuiesce('user-a');
      final saving = repository.saveDailyMetrics(
        energy: 5,
        focus: 3,
        motivation: 4,
      );
      final failure = expectLater(
        saving,
        throwsA(isA<LocalMutationUnavailable>()),
      );
      await barrier.cleanup(db.clearAllData);
      auth.currentUser = null;
      barrier.finish(signOutConfirmed: true);
      await failure;
      expect(await db.select(db.checkInTable).get(), isEmpty);
      expect(firestore.setCalls, 0);
    },
  );

  test(
    'old upload cannot acknowledge a new generation of the same UID',
    () async {
      db.localMutations.bindSessionReader(() => auth.currentUser?.uid);
      db.localMutations.openPreparedSession();
      await seed('2026-09-24', 3);
      final started = Completer<void>();
      final release = Completer<void>();
      firestore.beforeSet = (_) async {
        started.complete();
        await release.future;
      };
      final uploading = repository.syncPendingCheckIns();
      await started.future;
      final barrier = db.localMutations.beginQuiesce('user-a');
      await barrier.cleanup(db.clearAllData);
      auth.currentUser = null;
      barrier.finish(signOutConfirmed: true);
      auth.currentUser = _User('user-a');
      db.localMutations.openPreparedSession();
      await seed('2026-09-24', 3);
      release.complete();
      expect(await uploading, isFalse);
      expect((await db.select(db.checkInTable).getSingle()).isSynced, isFalse);
    },
  );
  for (final metadata in <String, Object?>{
    'late UTC upload': Timestamp.fromDate(DateTime.utc(2026, 9, 22, 23, 50)),
    'missing timestamp': null,
    'future timestamp': Timestamp.fromDate(DateTime.utc(2100, 1, 1)),
    'non-timestamp metadata': 'PRIVATE_REMOTE_METADATA',
  }.entries) {
    test('hydration uses ID civil date with ${metadata.key}', () async {
      firestore.remoteDocs['2026-09-15'] = {
        'energy': 2,
        'focus': 3,
        'motivation': 4,
        if (metadata.value != null) 'updatedAt': metadata.value,
      };
      await repository.syncCheckinsFromFirebaseToLocal();
      final local = await db.select(db.checkInTable).getSingle();
      expect(local.id, '2026-09-15');
      expect(local.createdAt.year, 2026);
      expect(local.createdAt.month, 9);
      expect(local.createdAt.day, 15);
      expect(local.createdAt.isUtc, isFalse);
      expect(local.createdAt, DateTime(2026, 9, 15));
      expect(local.energy, 2);
      expect(local.focus, 3);
      expect(local.motivation, 4);
      expect(local.isSynced, isTrue);
    });
  }

  test('history orders civil days independently of upload order', () async {
    firestore.remoteDocs.addAll({
      '2026-09-15': {
        'energy': 1,
        'updatedAt': Timestamp.fromDate(DateTime.utc(2100, 1, 1)),
      },
      '2026-09-22': {
        'energy': 2,
        'updatedAt': Timestamp.fromDate(DateTime.utc(2000, 1, 1)),
      },
      '2026-09-16': {
        'energy': 3,
        'updatedAt': Timestamp.fromDate(DateTime.utc(2026, 9, 22)),
      },
    });
    await repository.syncCheckinsFromFirebaseToLocal();
    final history = await repository.watchCheckIns().first;
    expect(history.map((entry) => entry.id), [
      '2026-09-22',
      '2026-09-16',
      '2026-09-15',
    ]);
    expect(history.map((entry) => entry.createdAt), [
      DateTime(2026, 9, 22),
      DateTime(2026, 9, 16),
      DateTime(2026, 9, 15),
    ]);
  });

  for (final invalidId in [
    'legacy-uuid',
    '2026-9-15',
    '2026-09-5',
    '2026-02-30',
    '2025-02-29',
    '2026-00-15',
    '2026-13-01',
    '2026-09-00',
    '2026-09-31',
    '0000-01-01',
    ' 2026-09-15',
    '2026-09-15 ',
    '2026-09-15\n',
    '2026-09-15T00:00:00Z',
  ]) {
    test(
      'invalid civil ID ${invalidId.replaceAll('\n', r'\n')} is skipped without aborting valid docs',
      () async {
        firestore.remoteDocs.addAll({
          '2026-09-14': {'energy': 2},
          invalidId: {
            'energy': 'PRIVATE_INVALID_PAYLOAD',
            'updatedAt': Timestamp.fromDate(DateTime.utc(2026, 9, 22)),
          },
          '2026-09-16': {'energy': 4},
        });
        await repository.syncCheckinsFromFirebaseToLocal();
        final history = await repository.watchCheckIns().first;
        expect(history.map((entry) => entry.id), ['2026-09-16', '2026-09-14']);
        expect(history.map((entry) => entry.createdAt), [
          DateTime(2026, 9, 16),
          DateTime(2026, 9, 14),
        ]);
      },
    );
  }

  test('valid leap day is hydrated as a local civil date', () async {
    firestore.remoteDocs['2024-02-29'] = {'energy': 3};
    await repository.syncCheckinsFromFirebaseToLocal();
    expect(
      (await db.select(db.checkInTable).getSingle()).createdAt,
      DateTime(2024, 2, 29),
    );
  });

  test(
    'rehydration repairs a synced row previously dated by upload time',
    () async {
      await seed(
        '2026-09-15',
        3,
        isSynced: true,
        createdAt: DateTime(2026, 9, 22),
      );
      firestore.remoteDocs['2026-09-15'] = {
        'energy': 4,
        'updatedAt': Timestamp.fromDate(DateTime.utc(2026, 9, 22)),
      };
      await repository.syncCheckinsFromFirebaseToLocal();
      final local = await db.select(db.checkInTable).getSingle();
      expect(local.createdAt, DateTime(2026, 9, 15));
      expect(local.energy, 4);
      expect(local.isSynced, isTrue);
    },
  );

  test(
    'ACK for an old pending check-in preserves its original civil date',
    () async {
      final originalDate = DateTime(2026, 9, 15);
      await seed('2026-09-15', 4, createdAt: originalDate);
      expect(await repository.syncPendingCheckIns(), isTrue);
      final local = await db.select(db.checkInTable).getSingle();
      expect(local.id, '2026-09-15');
      expect(local.createdAt, originalDate);
      expect(local.isSynced, isTrue);
      expect(firestore.lastUid, 'user-a');
      expect(
        firestore.writes['2026-09-15']!.keys,
        unorderedEquals(['energy', 'focus', 'motivation', 'updatedAt']),
      );
      expect(firestore.writes['2026-09-15']!['updatedAt'], isA<FieldValue>());
    },
  );

  test(
    'hydration upload date cannot contaminate AI daily or seven-day context',
    () async {
      final builder = AIInsightContextBuilder(
        db,
        currentUserIdProvider: () => auth.currentUser?.uid,
        clock: () => DateTime(2026, 9, 22, 12),
      );
      firestore.remoteDocs['2026-09-15'] = {
        'energy': 1,
        'focus': 1,
        'motivation': 1,
        'updatedAt': Timestamp.fromDate(DateTime.utc(2026, 9, 22)),
      };
      await repository.syncCheckinsFromFirebaseToLocal();
      final dailyWithoutCurrent = await builder.buildContext(
        AIInsightIntent.dailyOverview,
        expectedUserId: 'user-a',
      );
      expect(dailyWithoutCurrent, isNot(contains('checkin')));
      final weeklyWithoutCurrent = await builder.buildContext(
        AIInsightIntent.weeklyOverview,
        expectedUserId: 'user-a',
      );
      expect(weeklyWithoutCurrent['checkin'], {'entries_last_7_days': 0});
      expect(
        (await builder.buildLocalSummary(expectedUserId: 'user-a')).energy,
        isNull,
      );

      firestore.remoteDocs['2026-09-16'] = {
        'energy': 5,
        'focus': 4,
        'motivation': 3,
        'updatedAt': Timestamp.fromDate(DateTime.utc(2026, 9, 22)),
      };
      await repository.syncCheckinsFromFirebaseToLocal();
      final daily = await builder.buildContext(
        AIInsightIntent.dailyOverview,
        expectedUserId: 'user-a',
      );
      expect(daily, isNot(contains('checkin')));
      final weekly = await builder.buildContext(
        AIInsightIntent.weeklyOverview,
        expectedUserId: 'user-a',
      );
      expect(weekly['checkin'], {
        'entries_last_7_days': 1,
        'average_energy': 5.0,
        'average_focus': 4.0,
        'average_motivation': 3.0,
      });
      expect(
        (await builder.buildLocalSummary(expectedUserId: 'user-a')).energy,
        isNull,
      );
    },
  );
}
