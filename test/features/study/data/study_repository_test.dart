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
  Future<void> card({
    String id = 'card-1',
    String subjectId = 'subject-1',
    DateTime? lastReviewed,
  }) => db
      .into(db.flashcards)
      .insert(
        FlashcardsCompanion.insert(
          id: id,
          subjectId: subjectId,
          question: 'Pergunta',
          answer: 'Resposta',
          lastReviewed: Value(lastReviewed?.millisecondsSinceEpoch),
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

  test('cache persistido não é autoritativo para contadores due', () async {
    final now = DateTime(2026, 9, 8, 12);
    repository = StudyRepository(db, fire, auth, sync, reviewNow: () => now);
    await subject(cards: 99);
    await stats(queue: 99);
    await card();

    expect((await repository.getStudyStatsStream().first).reviewQueue, 1);
    expect(
      (await repository.getSubjectsStream().first).single.cardsToReview,
      1,
    );
  });

  test('due inclui nunca revisado e dia anterior, mas não hoje', () async {
    final now = DateTime(2026, 9, 8, 12);
    repository = StudyRepository(db, fire, auth, sync, reviewNow: () => now);
    await subject();
    await card(id: 'card-1');
    await card(id: 'card-2', lastReviewed: DateTime(2026, 9, 7, 20));
    await card(id: 'card-3', lastReviewed: DateTime(2026, 9, 8, 8));

    final dueIds = (await repository.getFlashcardsStream().first)
        .map((item) => item.id)
        .toSet();
    expect(dueIds, {'card-1', 'card-2'});
    expect((await repository.getStudyStatsStream().first).reviewQueue, 2);
  });

  test('cardsToReview é agregado por subject a partir dos cards due', () async {
    final now = DateTime(2026, 9, 8, 12);
    repository = StudyRepository(db, fire, auth, sync, reviewNow: () => now);
    await subject(id: 'subject-a', cards: 99);
    await subject(id: 'subject-b', cards: 99);
    await card(id: 'a-1', subjectId: 'subject-a');
    await card(
      id: 'a-2',
      subjectId: 'subject-a',
      lastReviewed: DateTime(2026, 9, 7, 20),
    );
    await card(
      id: 'a-3',
      subjectId: 'subject-a',
      lastReviewed: DateTime(2026, 9, 8, 8),
    );
    await card(id: 'b-1', subjectId: 'subject-b');
    await card(
      id: 'b-2',
      subjectId: 'subject-b',
      lastReviewed: DateTime(2026, 9, 8, 9),
    );

    final subjects = {
      for (final item in await repository.getSubjectsStream().first)
        item.id: item.cardsToReview,
    };
    expect(subjects, {'subject-a': 2, 'subject-b': 1});
    expect((await repository.getStudyStatsStream().first).reviewQueue, 3);
  });

  test('card revisado volta a ficar due no próximo dia local', () async {
    var now = DateTime(2026, 9, 8, 12);
    repository = StudyRepository(db, fire, auth, sync, reviewNow: () => now);
    await subject();
    await card(lastReviewed: DateTime(2026, 9, 8, 10));

    expect(await repository.getFlashcardsStream().first, isEmpty);
    expect((await repository.getStudyStatsStream().first).reviewQueue, 0);
    expect(
      (await repository.getSubjectsStream().first).single.cardsToReview,
      0,
    );

    now = DateTime(2026, 9, 9, 0, 1);

    expect(await repository.getFlashcardsStream().first, hasLength(1));
    expect((await repository.getStudyStatsStream().first).reviewQueue, 1);
    expect(
      (await repository.getSubjectsStream().first).single.cardsToReview,
      1,
    );
  });

  test('cache remoto stale não domina contadores derivados', () async {
    final now = DateTime(2026, 9, 8, 12);
    repository = StudyRepository(db, fire, auth, sync, reviewNow: () => now);
    fire.info.document.values = {
      'streak': 2,
      'reviewQueue': 99,
      'progress': .2,
    };
    fire.subjects.documents = [
      _QueryDoc('subject-1', {...remoteSubject(), 'cardsToReview': 99}),
    ];
    fire.cards.documents = [
      _QueryDoc('card-due', {
        'subjectId': 'subject-1',
        'question': 'Pendente',
        'answer': 'Resposta',
        'lastReviewed': Timestamp.fromDate(DateTime(2026, 9, 7, 20)),
      }),
      _QueryDoc('card-reviewed', {
        'subjectId': 'subject-1',
        'question': 'Revisado',
        'answer': 'Resposta',
        'lastReviewed': Timestamp.fromDate(DateTime(2026, 9, 8, 8)),
      }),
    ];

    await repository.syncStudyFromFirebaseToLocal();

    expect((await repository.getStudyStatsStream().first).reviewQueue, 1);
    expect(
      (await repository.getSubjectsStream().first).single.cardsToReview,
      1,
    );
  });

  test('ausência remota remove subject e flashcard locais stale', () async {
    final now = DateTime(2026, 9, 8, 12);
    repository = StudyRepository(db, fire, auth, sync, reviewNow: () => now);
    await subject(id: 'subject-a');
    await subject(id: 'subject-b');
    await card(id: 'card-a', subjectId: 'subject-a');
    await card(id: 'card-b', subjectId: 'subject-b');
    fire.subjects.documents = [
      _QueryDoc('subject-b', remoteSubject('Matemática B')),
    ];
    fire.cards.documents = [
      _QueryDoc('card-b', {
        'subjectId': 'subject-b',
        'question': 'Pergunta B',
        'answer': 'Resposta B',
        'lastReviewed': null,
      }),
    ];

    await repository.syncStudyFromFirebaseToLocal();

    expect((await db.select(db.subjects).get()).map((item) => item.id), [
      'subject-b',
    ]);
    expect((await db.select(db.flashcards).get()).map((item) => item.id), [
      'card-b',
    ]);
    expect((await repository.getStudyStatsStream().first).reviewQueue, 1);
  });

  test('documento remoto inválido presente não apaga cópia local', () async {
    await subject();
    await card();
    fire.subjects.documents = [
      _QueryDoc('subject-1', {'title': ''}),
    ];
    fire.cards.documents = [
      _QueryDoc('card-1', {'subjectId': ''}),
    ];

    await repository.syncStudyFromFirebaseToLocal();

    final localSubject = await db.select(db.subjects).getSingle();
    final localCard = await db.select(db.flashcards).getSingle();
    expect(localSubject.id, 'subject-1');
    expect(localSubject.title, 'Matemática');
    expect(localCard.id, 'card-1');
    expect(localCard.question, 'Pergunta');
  });

  test('troca de UID durante remote delete faz rollback integral', () async {
    await subject(id: 'subject-a');
    await subject(id: 'subject-b');
    await card(id: 'card-a', subjectId: 'subject-a');
    await card(id: 'card-b', subjectId: 'subject-b');
    var observedFirstDelete = false;
    auth.uidForRead = (_) {
      final count =
          rawDb
                  .select('SELECT COUNT(*) AS count FROM flashcards')
                  .first['count']!
              as int;
      if (count < 2) {
        observedFirstDelete = true;
        return 'user-b';
      }
      return 'user-a';
    };

    await repository.syncStudyFromFirebaseToLocal();

    expect(observedFirstDelete, isTrue);
    expect(await db.select(db.subjects).get(), hasLength(2));
    expect(await db.select(db.flashcards).get(), hasLength(2));
  });

  test('delete subject recalcula fila global pelo cascade real', () async {
    final now = DateTime(2026, 9, 8, 12);
    repository = StudyRepository(db, fire, auth, sync, reviewNow: () => now);
    await stats(queue: 99);
    await subject(id: 'subject-a', cards: 99);
    await subject(id: 'subject-b', cards: 99);
    await card(id: 'a-due', subjectId: 'subject-a');
    await card(
      id: 'a-reviewed',
      subjectId: 'subject-a',
      lastReviewed: DateTime(2026, 9, 8, 8),
    );
    await card(id: 'b-due-1', subjectId: 'subject-b');
    await card(id: 'b-due-2', subjectId: 'subject-b');

    expect((await repository.getStudyStatsStream().first).reviewQueue, 3);

    await repository.removeSubject('subject-a');

    expect((await repository.getStudyStatsStream().first).reviewQueue, 2);
  });

  test('streams abertos reagem ao cascade de subject', () async {
    final now = DateTime(2026, 9, 8, 12);
    repository = StudyRepository(db, fire, auth, sync, reviewNow: () => now);
    await subject(id: 'subject-a');
    await subject(id: 'subject-b');
    await card(id: 'a-due', subjectId: 'subject-a');
    await card(id: 'b-due', subjectId: 'subject-b');

    final statsStream = StreamIterator(repository.getStudyStatsStream());
    final subjectsStream = StreamIterator(repository.getSubjectsStream());
    final cardsStream = StreamIterator(repository.getFlashcardsStream());
    addTearDown(statsStream.cancel);
    addTearDown(subjectsStream.cancel);
    addTearDown(cardsStream.cancel);

    expect(await statsStream.moveNext(), isTrue);
    expect(await subjectsStream.moveNext(), isTrue);
    expect(await cardsStream.moveNext(), isTrue);
    expect(statsStream.current.reviewQueue, 2);
    expect(subjectsStream.current, hasLength(2));
    expect(cardsStream.current, hasLength(2));

    await repository.removeSubject('subject-a');

    expect(await statsStream.moveNext(), isTrue);
    expect(await subjectsStream.moveNext(), isTrue);
    expect(await cardsStream.moveNext(), isTrue);
    expect(statsStream.current.reviewQueue, 1);
    expect(subjectsStream.current.single.id, 'subject-b');
    expect(cardsStream.current.single.id, 'b-due');
  });

  test('fila global mantém invariante com lista de flashcards due', () async {
    final now = DateTime(2026, 9, 8, 12);
    repository = StudyRepository(db, fire, auth, sync, reviewNow: () => now);
    await subject();
    await card(id: 'never');
    await card(id: 'yesterday', lastReviewed: DateTime(2026, 9, 7, 23));
    await card(id: 'today', lastReviewed: DateTime(2026, 9, 8, 1));

    final dueCards = await repository.getFlashcardsStream().first;
    final study = await repository.getStudyStatsStream().first;

    expect(study.reviewQueue, dueCards.length);
  });

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
    expect(payload.keys.toSet(), {
      'subjectId',
      'lastReviewed',
      'timeZoneOffsetMinutes',
    });
    expect(payload['subjectId'], 'subject-1');
    expect(DateTime.parse(payload['lastReviewed'] as String).isUtc, isTrue);
    expect(payload['timeZoneOffsetMinutes'], isA<int>());
    expect(
      (payload['timeZoneOffsetMinutes'] as int).abs(),
      lessThanOrEqualTo(840),
    );
    expect(sync.calls, 1);
  });

  test(
    'no-op remoto de review reconcilia incremento otimista pelo pull',
    () async {
      await subject(cards: 1);
      await stats(queue: 1);
      await card();
      DateTime? remoteReviewedAt;

      sync.duringDrain = () async {
        final pending = await db.getPendingSyncItems('user-a');
        expect(pending, hasLength(1));
        final item = pending.single;
        final payload = jsonDecode(item.payloadJson) as Map<String, dynamic>;
        remoteReviewedAt = DateTime.parse(payload['lastReviewed']! as String);

        rawDb.execute(
          'UPDATE sync_queue_table SET created_at = 0 WHERE id = ?',
          [item.id],
        );
        await db.markSyncItemAsSucceeded(item.id, 'user-a');
        fire.info.document.values = {
          'streak': 2,
          'reviewQueue': 0,
          'progress': .2,
          'lastStudyDate': Timestamp.fromDate(remoteReviewedAt!),
        };
        fire.subjects.documents = [
          _QueryDoc('subject-1', {
            ...remoteSubject(),
            'cardsToReview': 0,
            'progress': .2,
          }),
        ];
        fire.cards.documents = [
          _QueryDoc('card-1', {
            'subjectId': 'subject-1',
            'question': 'Pergunta',
            'answer': 'Resposta',
            'lastReviewed': Timestamp.fromDate(remoteReviewedAt!),
          }),
        ];
      };

      final reconciled = repository.getStudyStatsStream().firstWhere(
        (value) => value.reviewQueue == 0 && value.progress == .2,
      );

      await repository.completeCard('card-1');
      await reconciled;

      expect((await db.select(db.studyStats).getSingle()).progress, .2);
      expect((await db.select(db.subjects).getSingle()).cardsToReview, 0);
      expect(
        (await db.select(db.flashcards).getSingle()).lastReviewed,
        remoteReviewedAt!.millisecondsSinceEpoch,
      );
      expect(await db.getPendingSyncItems('user-a'), isEmpty);
      expect(sync.calls, 1);
    },
  );

  test('troca de UID durante completeCard faz rollback integral', () async {
    await subject(cards: 1);
    await stats(queue: 1);
    await card();
    var observedReview = false;
    auth.uidForRead = (_) {
      final count =
          rawDb
                  .select(
                    "SELECT COUNT(*) AS count FROM sync_queue_table "
                    "WHERE collection = 'review_queue' "
                    "AND operation_type = 'update'",
                  )
                  .first['count']!
              as int;
      if (count > 0) {
        observedReview = true;
        return 'user-b';
      }
      return 'user-a';
    };

    await repository.completeCard('card-1');

    expect(observedReview, isTrue);
    expect((await db.select(db.studyStats).getSingle()).reviewQueue, 1);
    expect((await db.select(db.studyStats).getSingle()).progress, .2);
    expect((await db.select(db.subjects).getSingle()).cardsToReview, 1);
    expect((await db.select(db.flashcards).getSingle()).lastReviewed, null);
    expect(await db.getPendingSyncItems('user-a'), isEmpty);
    expect(sync.calls, 0);
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

  test('quota terminal reconcilia matéria local ausente no servidor', () async {
    fire.subjects.documents = [
      _QueryDoc('remote-a', remoteSubject('Remota A')),
      _QueryDoc('remote-b', remoteSubject('Remota B')),
      _QueryDoc('remote-c', remoteSubject('Remota C')),
    ];
    sync.duringDrain = () async {
      final pending = await db.getPendingSyncItems('user-a');
      expect(pending, hasLength(1));
      expect(pending.single.collection, 'subjects');
      expect(pending.single.operationType, 'create');
      await db.markSyncItemRejected(
        pending.single.id,
        'user-a',
        'QUOTA_EXCEEDED',
      );
    };
    final reconciled = repository.getSubjectsStream().firstWhere(
      (subjects) =>
          subjects.map((subject) => subject.id).toSet().containsAll({
            'remote-a',
            'remote-b',
            'remote-c',
          }) &&
          subjects.length == 3,
    );

    await repository.createSubject('Matemática local');
    final subjects = await reconciled;

    expect(subjects.map((subject) => subject.id).toSet(), {
      'remote-a',
      'remote-b',
      'remote-c',
    });
  });

  test(
    'create aceito remotamente preserva matéria após reconciliação',
    () async {
      sync.duringDrain = () async {
        final local = await db.select(db.subjects).getSingle();
        final pending = await db.getPendingSyncItems('user-a');
        expect(pending, hasLength(1));
        await (db.update(db.syncQueueTable)
              ..where((item) => item.id.equals(pending.single.id)))
            .write(const SyncQueueTableCompanion(createdAt: Value(0)));
        await db.markSyncItemAsSucceeded(pending.single.id, 'user-a');
        fire.subjects.documents = [
          _QueryDoc(local.id, remoteSubject('Matéria confirmada')),
        ];
      };
      final reconciled = repository.getSubjectsStream().firstWhere(
        (subjects) =>
            subjects.length == 1 &&
            subjects.single.title == 'Matéria confirmada',
      );

      await repository.createSubject('Matemática local');
      final subject = (await reconciled).single;

      expect(subject.title, 'Matéria confirmada');
      expect(fire.subjects.calls, 1);
    },
  );

  test('create retryable preserva matéria e fila sem iniciar GET', () async {
    sync.drains = false;
    final started = Completer<void>();
    final release = Completer<void>();
    sync.duringDrain = () async {
      started.complete();
      await release.future;
    };

    await repository.createSubject('Matemática local');
    await started.future;

    expect(await db.select(db.subjects).get(), hasLength(1));
    expect(await db.getPendingSyncItems('user-a'), hasLength(1));
    expect(
      fire.info.document.calls + fire.subjects.calls + fire.cards.calls,
      0,
    );

    release.complete();
    await pumpEventQueue();
    expect(
      fire.info.document.calls + fire.subjects.calls + fire.cards.calls,
      0,
    );
  });

  test('create e remove subject agendam imediatamente', () async {
    sync.duringDrain = () async {
      final local = await db.select(db.subjects).getSingle();
      final pending = await db.getPendingSyncItems('user-a');
      await (db.update(db.syncQueueTable)
            ..where((item) => item.id.equals(pending.single.id)))
          .write(const SyncQueueTableCompanion(createdAt: Value(0)));
      await db.markSyncItemAsSucceeded(pending.single.id, 'user-a');
      fire.subjects.documents = [
        _QueryDoc(local.id, remoteSubject('Matéria confirmada')),
      ];
    };
    final reconciled = repository.getSubjectsStream().firstWhere(
      (subjects) =>
          subjects.length == 1 && subjects.single.title == 'Matéria confirmada',
    );
    await repository.createSubject('Matemática');
    final created = (await reconciled).single;
    expect(sync.calls, 1);
    sync.duringDrain = null;
    await repository.removeSubject(created.id);
    expect(sync.calls, 2);
  });

  test('addStudyTime cria um único intent study_activity', () async {
    sync.drains = false;
    await subject();
    await stats();

    await repository.addStudyTime('subject-1', 1500);

    final queue = await db.getPendingSyncItems('user-a');
    expect(queue, hasLength(1));
    expect(queue.single.collection, 'study_activity');
    expect(queue.single.operationType, 'create');
    expect(
      queue.single.docId,
      matches(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          caseSensitive: false,
        ),
      ),
    );
    final payload =
        jsonDecode(queue.single.payloadJson) as Map<String, dynamic>;
    expect(payload.keys.toSet(), {
      'subjectId',
      'progressDelta',
      'occurredAt',
      'timeZoneOffsetMinutes',
    });
    expect(payload['subjectId'], 'subject-1');
    expect(payload['progressDelta'], .25);
    expect(DateTime.parse(payload['occurredAt'] as String).isUtc, isTrue);
    expect(payload['timeZoneOffsetMinutes'], isA<int>());
    expect((await db.select(db.studyStats).getSingle()).progress, .45);
    expect((await db.select(db.subjects).getSingle()).progress, .45);
  });

  test('addStudyTime sem subject preserva optimistic global', () async {
    sync.drains = false;
    await stats();

    await repository.addStudyTime('missing', 1500);

    final queue = await db.getPendingSyncItems('user-a');
    final payload =
        jsonDecode(queue.single.payloadJson) as Map<String, dynamic>;
    expect(queue, hasLength(1));
    expect(queue.single.collection, 'study_activity');
    expect(payload['subjectId'], null);
    expect((await db.select(db.studyStats).getSingle()).progress, .45);
    expect(await db.select(db.subjects).get(), isEmpty);
  });

  test('logStudySession cria intent study_activity global', () async {
    sync.drains = false;
    final state = StudyModel(streak: 2, reviewQueue: 3, progress: .2);

    await repository.logStudySession(state);

    final queue = await db.getPendingSyncItems('user-a');
    expect(queue, hasLength(1));
    expect(queue.single.collection, 'study_activity');
    expect(queue.single.operationType, 'create');
    final payload =
        jsonDecode(queue.single.payloadJson) as Map<String, dynamic>;
    expect(payload['subjectId'], null);
    expect(payload['progressDelta'], .1);
    expect(DateTime.parse(payload['occurredAt'] as String).isUtc, isTrue);
    expect(payload['timeZoneOffsetMinutes'], isA<int>());
    expect(
      (await db.select(db.studyStats).getSingle()).progress,
      closeTo(.3, 1e-9),
    );
  });

  test('troca de UID durante addStudyTime faz rollback integral', () async {
    await subject();
    await stats();
    var observedActivity = false;
    auth.uidForRead = (_) {
      final count =
          rawDb
                  .select('SELECT COUNT(*) AS count FROM sync_queue_table')
                  .first['count']!
              as int;
      if (count > 0) {
        observedActivity = true;
        return 'user-b';
      }
      return 'user-a';
    };

    await repository.addStudyTime('subject-1', 1500);

    expect(observedActivity, isTrue);
    expect((await db.select(db.studyStats).getSingle()).progress, .2);
    expect((await db.select(db.subjects).getSingle()).progress, .2);
    expect(await db.getPendingSyncItems('user-a'), isEmpty);
    expect(sync.calls, 0);
  });

  test('completeReview e reset criam intents duráveis', () async {
    final state = StudyModel(streak: 1, reviewQueue: 2, progress: .8);
    await repository.completeReview(state);
    await repository.resetDailyProgress(state);
    expect((await db.select(db.studyStats).getSingle()).reviewQueue, 1);
    expect((await db.select(db.studyStats).getSingle()).progress, 0);
    final queue = await db.getPendingSyncItems('user-a');
    expect(queue, hasLength(2));
    final reset = queue.singleWhere(
      (item) => item.collection == 'study_progress_reset',
    );
    expect(reset.operationType, 'create');
    expect(
      reset.docId,
      matches(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          caseSensitive: false,
        ),
      ),
    );
    final payload = jsonDecode(reset.payloadJson) as Map<String, dynamic>;
    expect(payload.keys, {'occurredAt'});
    expect(DateTime.parse(payload['occurredAt'] as String).isUtc, isTrue);
  });

  test('troca de UID durante reset faz rollback integral', () async {
    await stats(progress: .8);
    var observedReset = false;
    auth.uidForRead = (_) {
      final count =
          rawDb
                  .select(
                    "SELECT COUNT(*) AS count FROM sync_queue_table "
                    "WHERE collection = 'study_progress_reset'",
                  )
                  .first['count']!
              as int;
      if (count > 0) {
        observedReset = true;
        return 'user-b';
      }
      return 'user-a';
    };

    await repository.resetDailyProgress(
      StudyModel(streak: 1, reviewQueue: 0, progress: .8),
    );

    expect(observedReset, isTrue);
    expect((await db.select(db.studyStats).getSingle()).progress, .8);
    expect(await db.getPendingSyncItems('user-a'), isEmpty);
    expect(sync.calls, 0);
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

  test('pending study_activity protege stats durante pull stale', () async {
    await stats(progress: .45);
    fire.info.document.values = {'streak': 1, 'reviewQueue': 0, 'progress': .1};
    await db.insertSyncItem(
      ownerUid: 'user-a',
      collection: 'study_activity',
      docId: '7d287d4e-190f-42ab-90a8-a93696f8c462',
      operationType: 'create',
      payloadJson: jsonEncode({
        'subjectId': null,
        'progressDelta': .25,
        'occurredAt': '2026-09-09T12:00:00.000Z',
        'timeZoneOffsetMinutes': -180,
      }),
    );

    await repository.syncStudyFromFirebaseToLocal();

    expect((await db.select(db.studyStats).getSingle()).progress, .45);
  });

  test('pending study_progress_reset protege somente stats', () async {
    await stats(progress: .45);
    await subject();
    fire.info.document.values = {'streak': 1, 'reviewQueue': 0, 'progress': .1};
    fire.subjects.documents = [
      _QueryDoc('subject-1', remoteSubject('Matemática remota')),
    ];
    await db.insertSyncItem(
      ownerUid: 'user-a',
      collection: 'study_progress_reset',
      docId: '5a3ccf1f-d43e-4a34-823d-61ed255e568a',
      operationType: 'create',
      payloadJson: jsonEncode({'occurredAt': '2026-09-09T10:00:00.000Z'}),
    );

    await repository.syncStudyFromFirebaseToLocal();

    expect((await db.select(db.studyStats).getSingle()).progress, .45);
    expect(
      (await db.select(db.subjects).getSingle()).title,
      'Matemática remota',
    );
  });

  test('pending study_activity protege a matéria identificada', () async {
    await subject();
    fire.subjects.documents = [
      _QueryDoc('subject-1', remoteSubject('Remota stale')),
    ];
    await db.insertSyncItem(
      ownerUid: 'user-a',
      collection: 'study_activity',
      docId: '7d287d4e-190f-42ab-90a8-a93696f8c462',
      operationType: 'create',
      payloadJson: jsonEncode({
        'subjectId': 'subject-1',
        'progressDelta': .25,
        'occurredAt': '2026-09-09T12:00:00.000Z',
        'timeZoneOffsetMinutes': -180,
      }),
    );

    await repository.syncStudyFromFirebaseToLocal();

    expect((await db.select(db.subjects).getSingle()).title, 'Matemática');
  });

  test(
    'study_activity inválida protege stats sem proteger toda matéria',
    () async {
      await subject();
      await stats(progress: .45);
      fire.info.document.values = {
        'streak': 1,
        'reviewQueue': 0,
        'progress': .1,
      };
      await db.insertSyncItem(
        ownerUid: 'user-a',
        collection: 'study_activity',
        docId: '7d287d4e-190f-42ab-90a8-a93696f8c462',
        operationType: 'create',
        payloadJson: '{',
      );

      await repository.syncStudyFromFirebaseToLocal();

      expect((await db.select(db.studyStats).getSingle()).progress, .45);
      expect(await db.select(db.subjects).get(), isEmpty);
    },
  );

  test('study_activity criada durante pull não é sobrescrita', () async {
    await subject();
    await stats();
    fire.info.document.values = {'streak': 1, 'reviewQueue': 0, 'progress': .1};
    fire.subjects.documents = [
      _QueryDoc('subject-1', remoteSubject('Remota stale')),
    ];
    final started = Completer<void>();
    final release = Completer<void>();
    fire.info.document.beforeGet = () {
      started.complete();
      return release.future;
    };

    final pull = repository.syncStudyFromFirebaseToLocal();
    await started.future;
    sync.drains = false;
    await repository.addStudyTime('subject-1', 1500);
    release.complete();
    await pull;

    expect((await db.select(db.studyStats).getSingle()).progress, .45);
    final localSubject = await db.select(db.subjects).getSingle();
    expect(localSubject.title, 'Matemática');
    expect(localSubject.progress, .45);
  });

  test('study_progress_reset criado durante pull não é sobrescrito', () async {
    await stats(progress: .8);
    fire.info.document.values = {'streak': 1, 'reviewQueue': 0, 'progress': .6};
    final started = Completer<void>();
    final release = Completer<void>();
    fire.info.document.beforeGet = () {
      started.complete();
      return release.future;
    };

    final pull = repository.syncStudyFromFirebaseToLocal();
    await started.future;
    sync.drains = false;
    await repository.resetDailyProgress(
      StudyModel(streak: 1, reviewQueue: 0, progress: .8),
    );
    release.complete();
    await pull;

    expect((await db.select(db.studyStats).getSingle()).progress, 0);
    final queue = await db.getPendingSyncItems('user-a');
    expect(
      queue.where((item) => item.collection == 'study_progress_reset'),
      hasLength(1),
    );
  });

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
