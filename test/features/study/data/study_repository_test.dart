// ignore_for_file: subtype_of_sealed_class, must_be_immutable

import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/services/sync_manager.dart';
import 'package:life_os/core/services/sync_operation_result.dart';
import 'package:life_os/core/services/sync_queue_store.dart';
import 'package:life_os/core/services/sync_remote_data_source.dart';
import 'package:life_os/features/study/data/models/study_model.dart';
import 'package:life_os/features/study/data/study_repository.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

class _User extends Fake implements User {
  @override
  final String uid;
  _User(this.uid);
}

class _Auth extends Fake implements FirebaseAuth {
  User? user = _User('user-a');
  int reads = 0;
  int? switchAfterRead;
  String? Function(int reads)? uidForRead;
  @override
  User? get currentUser {
    reads++;
    final uid = uidForRead?.call(reads);
    if (uid != null) return _User(uid);
    return switchAfterRead != null && reads >= switchAfterRead!
        ? _User('user-b')
        : user;
  }
}

class _QueryDoc extends Fake
    implements QueryDocumentSnapshot<Map<String, dynamic>> {
  @override
  final String id;
  final Map<String, dynamic> values;
  _QueryDoc(this.id, this.values);
  @override
  Map<String, dynamic> data() => Map.of(values);
}

class _QuerySnap extends Fake implements QuerySnapshot<Map<String, dynamic>> {
  @override
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> docs;
  _QuerySnap(this.docs);
}

class _DocSnap extends Fake implements DocumentSnapshot<Map<String, dynamic>> {
  final Map<String, dynamic>? values;
  _DocSnap(this.values);
  @override
  bool get exists => values != null;
  @override
  Map<String, dynamic>? data() => values == null ? null : Map.of(values!);
}

class _Document extends Fake
    implements DocumentReference<Map<String, dynamic>> {
  Map<String, dynamic>? values;
  GetOptions? options;
  int calls = 0;
  Future<void> Function()? beforeGet;
  @override
  Future<DocumentSnapshot<Map<String, dynamic>>> get([
    GetOptions? value,
  ]) async {
    calls++;
    options = value;
    await beforeGet?.call();
    return _DocSnap(values);
  }
}

class _Collection extends Fake
    implements CollectionReference<Map<String, dynamic>> {
  final document = _Document();
  List<QueryDocumentSnapshot<Map<String, dynamic>>> documents = [];
  GetOptions? options;
  int calls = 0;
  Future<void> Function()? beforeGet;
  @override
  DocumentReference<Map<String, dynamic>> doc([String? path]) => document;
  @override
  Future<QuerySnapshot<Map<String, dynamic>>> get([GetOptions? value]) async {
    calls++;
    options = value;
    await beforeGet?.call();
    return _QuerySnap(documents);
  }
}

class _UserDoc extends Fake implements DocumentReference<Map<String, dynamic>> {
  final _Collection info, subjects, cards;
  _UserDoc(this.info, this.subjects, this.cards);
  @override
  CollectionReference<Map<String, dynamic>> collection(String path) =>
      switch (path) {
        'study_info' => info,
        'subjects' => subjects,
        'review_queue' => cards,
        _ => throw UnsupportedError(path),
      };
}

class _Users extends Fake implements CollectionReference<Map<String, dynamic>> {
  final _UserDoc user;
  _Users(this.user);
  @override
  DocumentReference<Map<String, dynamic>> doc([String? path]) => user;
}

class _Firestore extends Fake implements FirebaseFirestore {
  final info = _Collection(), subjects = _Collection(), cards = _Collection();
  @override
  CollectionReference<Map<String, dynamic>> collection(String path) =>
      _Users(_UserDoc(info, subjects, cards));
}

class _Store implements SyncQueueStore {
  @override
  Future<List<SyncQueueTableData>> getPendingSyncItems(String uid) async => [];
  @override
  Future<int> markSyncItemAsSucceeded(int id, String uid) async => 0;
  @override
  Future<int> markSyncItemRejected(int id, String uid, String code) async => 0;
  @override
  Future<int> markSyncItemRetryableFailure(
    int id,
    String uid,
    String code,
  ) async => 0;
}

class _Remote implements SyncRemoteDataSource {
  @override
  Future<SyncOperationResult> process(
    String uid,
    SyncQueueTableData item,
  ) async => const SyncOperationResult.success();
}

class _Sync extends SyncManager {
  int calls = 0;
  bool drains = true;
  Future<void> Function()? duringDrain;
  _Sync()
    : super(
        queueStore: _Store(),
        remoteDataSource: _Remote(),
        currentUserId: () => 'user-a',
      );
  @override
  Future<bool> processPendingItems() async {
    calls++;
    await duringDrain?.call();
    return drains;
  }
}

void main() {
  late AppDatabase db;
  late sqlite.Database rawDb;
  late _Auth auth;
  late _Firestore fire;
  late _Sync sync;
  late StudyRepository repository;
  setUp(() {
    rawDb = sqlite.sqlite3.openInMemory();
    db = AppDatabase(executor: NativeDatabase.opened(rawDb));
    auth = _Auth();
    fire = _Firestore();
    sync = _Sync();
    repository = StudyRepository(db, fire, auth, sync);
  });
  tearDown(() => db.closeDatabase());

  Future<void> subject({String id = 'subject-1', int cards = 0}) => db
      .into(db.subjects)
      .insert(
        SubjectsCompanion.insert(
          id: id,
          title: 'Matemática',
          cardsToReview: cards,
          streakDays: 1,
          progress: .2,
          hasExam: false,
        ),
      )
      .then((_) {});
  Future<void> stats({int queue = 0, double progress = .2}) => db
      .into(db.studyStats)
      .insert(
        StudyStatsCompanion.insert(
          id: 'main',
          streak: 2,
          reviewQueue: queue,
          progress: progress,
        ),
      )
      .then((_) {});
  Future<void> card() => db
      .into(db.flashcards)
      .insert(
        FlashcardsCompanion.insert(
          id: 'card-1',
          subjectId: 'subject-1',
          question: 'Pergunta',
          answer: 'Resposta',
        ),
      )
      .then((_) {});
  Map<String, dynamic> remoteSubject([String title = 'Remota']) => {
    'title': title,
    'cardsToReview': 2,
    'streakDays': 3,
    'progress': .4,
    'hasExam': false,
    'examDate': null,
  };

  test(
    'banco vazio expõe reviewQueue zero',
    () async =>
        expect((await repository.getStudyStatsStream().first).reviewQueue, 0),
  );

  test('addFlashcard atualiza Drift, SyncQueue owner e agenda', () async {
    await subject();
    await repository.addFlashcard('subject-1', 'Pergunta', 'Resposta');
    expect(await db.select(db.flashcards).get(), hasLength(1));
    expect((await db.select(db.subjects).getSingle()).cardsToReview, 1);
    expect((await db.select(db.studyStats).getSingle()).reviewQueue, 1);
    final queue = await db.getPendingSyncItems('user-a');
    expect(queue, hasLength(1));
    expect(queue.every((e) => e.ownerUid == 'user-a'), isTrue);
    expect(queue.single.collection, 'review_queue');
    expect(queue.single.operationType, 'create');
    expect(sync.calls, 1);
  });

  test('envio indisponível preserva flashcard e fila locais', () async {
    await subject();
    sync.drains = false;
    await repository.addFlashcard('subject-1', 'Pergunta', 'Resposta');
    expect(await db.select(db.flashcards).get(), hasLength(1));
    expect(await db.getPendingSyncItems('user-a'), hasLength(1));
  });

  test('intent único de add protege contadores durante pull antigo', () async {
    await subject();
    await stats();
    fire.info.document.values = {'streak': 2, 'reviewQueue': 0, 'progress': .2};
    fire.subjects.documents = [_QueryDoc('subject-1', remoteSubject())];
    final started = Completer<void>();
    final release = Completer<void>();
    fire.info.document.beforeGet = () {
      started.complete();
      return release.future;
    };

    final pull = repository.syncStudyFromFirebaseToLocal();
    await started.future;
    await repository.addFlashcard('subject-1', 'Pergunta', 'Resposta');
    release.complete();
    await pull;

    expect((await db.select(db.studyStats).getSingle()).reviewQueue, 1);
    expect((await db.select(db.subjects).getSingle()).cardsToReview, 1);
    expect(await db.select(db.flashcards).get(), hasLength(1));
  });

  test('completeCard é atômico e idempotente no mesmo dia', () async {
    await subject(cards: 1);
    await stats(queue: 1);
    await card();
    await repository.completeCard('card-1');
    await repository.completeCard('card-1');
    expect((await db.select(db.studyStats).getSingle()).reviewQueue, 0);
    expect((await db.select(db.studyStats).getSingle()).progress, .25);
    expect((await db.select(db.subjects).getSingle()).cardsToReview, 0);
    final queue = await db.getPendingSyncItems('user-a');
    expect(queue, hasLength(1));
    expect(queue.single.collection, 'review_queue');
    expect(queue.single.operationType, 'update');
    expect(queue.single.docId, 'card-1');
    final payload =
        jsonDecode(queue.single.payloadJson) as Map<String, dynamic>;
    expect(payload['subjectId'], 'subject-1');
    expect(
      DateTime.tryParse(payload['lastReviewed'] as String) != null,
      isTrue,
    );
    expect(sync.calls, 1);
  });

  test('intent único de review protege dados durante pull antigo', () async {
    await subject(cards: 1);
    await stats(queue: 1);
    await card();
    fire.info.document.values = {'streak': 2, 'reviewQueue': 1, 'progress': .2};
    fire.subjects.documents = [_QueryDoc('subject-1', remoteSubject())];
    fire.cards.documents = [
      _QueryDoc('card-1', {
        'subjectId': 'subject-1',
        'question': 'Pergunta',
        'answer': 'Resposta',
        'lastReviewed': null,
      }),
    ];
    final started = Completer<void>();
    final release = Completer<void>();
    fire.info.document.beforeGet = () {
      started.complete();
      return release.future;
    };

    final pull = repository.syncStudyFromFirebaseToLocal();
    await started.future;
    await repository.completeCard('card-1');
    final reviewedAt =
        (await db.select(db.flashcards).getSingle()).lastReviewed;
    release.complete();
    await pull;

    expect((await db.select(db.studyStats).getSingle()).reviewQueue, 0);
    expect((await db.select(db.studyStats).getSingle()).progress, .25);
    expect((await db.select(db.subjects).getSingle()).cardsToReview, 0);
    expect(
      (await db.select(db.flashcards).getSingle()).lastReviewed,
      reviewedAt,
    );
  });

  test('create e remove subject agendam imediatamente', () async {
    await repository.createSubject('Matemática');
    expect(sync.calls, 1);
    await repository.removeSubject(
      (await db.select(db.subjects).getSingle()).id,
    );
    expect(sync.calls, 2);
  });

  test('addStudyTime enfileira subject somente quando existe', () async {
    await subject();
    await repository.addStudyTime('subject-1', 1500);
    expect(
      (await db.getPendingSyncItems('user-a')).map((e) => e.collection),
      containsAll(['study_info', 'subjects']),
    );
    await db.delete(db.syncQueueTable).go();
    await repository.addStudyTime('missing', 1500);
    expect((await db.getPendingSyncItems('user-a')).map((e) => e.collection), [
      'study_info',
    ]);
  });

  test('completeReview e reset criam main com intents duráveis', () async {
    final state = StudyModel(streak: 1, reviewQueue: 2, progress: .8);
    await repository.completeReview(state);
    await repository.resetDailyProgress(state);
    expect((await db.select(db.studyStats).getSingle()).reviewQueue, 1);
    expect((await db.select(db.studyStats).getSingle()).progress, 0);
    expect(await db.getPendingSyncItems('user-a'), hasLength(2));
  });

  test('fila não drenada impede GET', () async {
    sync.drains = false;
    await repository.syncStudyFromFirebaseToLocal();
    expect(
      fire.info.document.calls + fire.subjects.calls + fire.cards.calls,
      0,
    );
  });

  test('todos os GETs usam Source.server', () async {
    await repository.syncStudyFromFirebaseToLocal();
    expect(fire.info.document.options?.source, Source.server);
    expect(fire.subjects.options?.source, Source.server);
    expect(fire.cards.options?.source, Source.server);
  });

  test('mudança UID após drain ou GET não aplica remoto', () async {
    sync.duringDrain = () async => auth.user = _User('user-b');
    await repository.syncStudyFromFirebaseToLocal();
    expect(fire.info.document.calls, 0);
    auth.user = _User('user-a');
    sync.duringDrain = null;
    fire.subjects.documents = [_QueryDoc('subject-1', remoteSubject())];
    fire.cards.beforeGet = () async => auth.user = _User('user-b');
    await repository.syncStudyFromFirebaseToLocal();
    expect(await db.select(db.subjects).get(), isEmpty);
  });

  test('mudança UID durante reconciliation faz rollback', () async {
    await db.select(db.subjects).get();
    fire.subjects.documents = [
      _QueryDoc('subject-1', remoteSubject()),
      _QueryDoc('subject-2', remoteSubject()),
    ];
    var observedFirstWrite = false;
    auth.uidForRead = (_) {
      final count =
          rawDb.select('SELECT COUNT(*) AS count FROM subjects').first['count']!
              as int;
      if (count > 0) {
        observedFirstWrite = true;
        return 'user-b';
      }
      return 'user-a';
    };
    await repository.syncStudyFromFirebaseToLocal();
    expect(observedFirstWrite, isTrue);
    expect(await db.select(db.subjects).get(), isEmpty);
  });

  test('troca de UID durante addFlashcard faz rollback sem propagar', () async {
    await subject();
    await stats();
    var observedFlashcardWrite = false;
    auth.uidForRead = (_) {
      final count =
          rawDb
                  .select('SELECT COUNT(*) AS count FROM flashcards')
                  .first['count']!
              as int;
      if (count > 0) {
        observedFlashcardWrite = true;
        return 'user-b';
      }
      return 'user-a';
    };

    await repository.addFlashcard('subject-1', 'Pergunta', 'Resposta');

    expect(observedFlashcardWrite, isTrue);
    expect(await db.select(db.flashcards).get(), isEmpty);
    expect((await db.select(db.subjects).getSingle()).cardsToReview, 0);
    expect((await db.select(db.studyStats).getSingle()).reviewQueue, 0);
    expect(await db.getPendingSyncItems('user-a'), isEmpty);
    expect(sync.calls, 0);
  });

  for (final collection in ['study_info', 'subjects', 'review_queue']) {
    test('pending $collection protege entidade local', () async {
      await subject();
      await stats(queue: 7);
      await card();
      fire.info.document.values = {
        'streak': 9,
        'reviewQueue': 9,
        'progress': .9,
      };
      fire.subjects.documents = [
        _QueryDoc('subject-1', remoteSubject('Sobrescrita')),
      ];
      fire.cards.documents = [
        _QueryDoc('card-1', {
          'subjectId': 'subject-1',
          'question': 'Remota',
          'answer': 'Remota',
          'lastReviewed': null,
        }),
      ];
      final id = collection == 'study_info'
          ? 'main'
          : collection == 'subjects'
          ? 'subject-1'
          : 'card-1';
      await db.insertSyncItem(
        ownerUid: 'user-a',
        collection: collection,
        docId: id,
        operationType: 'update',
        payloadJson: '{}',
      );
      await repository.syncStudyFromFirebaseToLocal();
      if (collection == 'study_info')
        expect((await db.select(db.studyStats).getSingle()).reviewQueue, 7);
      if (collection == 'subjects')
        expect((await db.select(db.subjects).getSingle()).title, 'Matemática');
      if (collection == 'review_queue')
        expect(
          (await db.select(db.flashcards).getSingle()).question,
          'Pergunta',
        );
    });
  }

  test('succeeded recente protege subject', () async {
    await subject();
    fire.subjects.documents = [_QueryDoc('subject-1', remoteSubject('Remota'))];
    final started = Completer<void>(), release = Completer<void>();
    fire.info.document.beforeGet = () {
      started.complete();
      return release.future;
    };
    final pull = repository.syncStudyFromFirebaseToLocal();
    await started.future;
    final id = await db.insertSyncItem(
      ownerUid: 'user-a',
      collection: 'subjects',
      docId: 'subject-1',
      operationType: 'update',
      payloadJson: '{}',
      createdAt: DateTime.now().millisecondsSinceEpoch + 1000,
    );
    await db.markSyncItemAsSucceeded(id, 'user-a');
    release.complete();
    await pull;
    expect((await db.select(db.subjects).getSingle()).title, 'Matemática');
  });

  test(
    'remoto inválido não fabrica dados e falha GET preserva Drift',
    () async {
      fire.info.document.values = {'reviewQueue': 'x'};
      fire.subjects.documents = [
        _QueryDoc('bad', {'title': ''}),
      ];
      await repository.syncStudyFromFirebaseToLocal();
      expect(await db.select(db.studyStats).get(), isEmpty);
      expect(await db.select(db.subjects).get(), isEmpty);
      await subject();
      fire.subjects.beforeGet = () async => throw StateError('offline');
      await repository.syncStudyFromFirebaseToLocal();
      expect((await db.select(db.subjects).getSingle()).title, 'Matemática');
    },
  );

  test('study_info parcial válido cria stats com defaults ausentes', () async {
    fire.info.document.values = {'reviewQueue': 4};

    await repository.syncStudyFromFirebaseToLocal();

    final local = await db.select(db.studyStats).getSingle();
    expect(local.streak, 0);
    expect(local.reviewQueue, 4);
    expect(local.progress, 0);
    expect(local.lastStudyDate, null);
  });

  test('study_info parcial inválido não cria stats', () async {
    fire.info.document.values = {'reviewQueue': '4'};

    await repository.syncStudyFromFirebaseToLocal();

    expect(await db.select(db.studyStats).get(), isEmpty);
  });
}
