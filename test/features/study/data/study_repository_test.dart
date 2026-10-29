// ignore_for_file: subtype_of_sealed_class, must_be_immutable

import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/remote_send_permit.dart';
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
  int visibilityListeners = 0;
  final changes = StreamController<User?>.broadcast();
  void emitSession(String? uid) {
    user = uid == null ? null : _User(uid);
    changes.add(user);
  }

  @override
  Stream<User?> authStateChanges() => Stream<User?>.multi((controller) {
    visibilityListeners++;
    controller.add(user);
    final subscription = changes.stream.listen(controller.add);
    controller.onCancel = () {
      visibilityListeners--;
      unawaited(subscription.cancel());
    };
  });
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
  Future<int> cleanupSucceededSyncItems(
    String ownerUid,
    int olderThanEpochMs,
  ) async => 0;

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

class _VisibilityProbe {
  _VisibilityProbe(Stream<ReviewCreationSyncState> stream) {
    _subscription = stream.listen((value) {
      values.add(value);
      for (final waiter in List.of(_waiters)) {
        if (waiter.$1(value) && !waiter.$2.isCompleted) {
          waiter.$2.complete(value);
          _waiters.remove(waiter);
        }
      }
    });
  }
  late final StreamSubscription<ReviewCreationSyncState> _subscription;
  final values = <ReviewCreationSyncState>[];
  final _waiters =
      <
        (
          bool Function(ReviewCreationSyncState),
          Completer<ReviewCreationSyncState>,
        )
      >[];
  Future<ReviewCreationSyncState> until(
    bool Function(ReviewCreationSyncState) matches,
  ) {
    if (values.isNotEmpty && matches(values.last))
      return Future.value(values.last);
    final completer = Completer<ReviewCreationSyncState>();
    _waiters.add((matches, completer));
    return completer.future.timeout(const Duration(seconds: 5));
  }

  Future<void> cancel() => _subscription.cancel();
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
  Future<void> stats({
    int queue = 0,
    double progress = .2,
    int streak = 2,
    DateTime? lastStudyDate,
  }) => db
      .into(db.studyStats)
      .insert(
        StudyStatsCompanion.insert(
          id: 'main',
          streak: streak,
          reviewQueue: queue,
          progress: progress,
          lastStudyDate: Value(lastStudyDate?.millisecondsSinceEpoch),
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
    final now = DateTime(2026, 9, 10, 12);
    repository = StudyRepository(db, fire, auth, sync, reviewNow: () => now);
    sync.drains = false;
    await subject(cards: 1);
    await stats(queue: 1, streak: 5, lastStudyDate: DateTime(2026, 9, 9, 12));
    await card();
    await repository.completeCard('card-1');
    await repository.completeCard('card-1');
    final updatedStats = await db.select(db.studyStats).getSingle();
    expect(updatedStats.reviewQueue, 0);
    expect(updatedStats.progress, .25);
    expect(updatedStats.streak, 6);
    expect(updatedStats.lastStudyDate, now.millisecondsSinceEpoch);
    expect((await db.select(db.subjects).getSingle()).cardsToReview, 0);
    final queue = await db.getPendingSyncItems('user-a');
    expect(queue, hasLength(1));
    expect(queue.single.collection, 'review_queue');
    expect(queue.single.operationType, 'update');
    expect(queue.single.docId, 'card-1');
    final payload =
        jsonDecode(queue.single.payloadJson) as Map<String, dynamic>;
    expect(payload, {
      'subjectId': 'subject-1',
      'lastReviewed': now.toUtc().toIso8601String(),
      'timeZoneOffsetMinutes': now.timeZoneOffset.inMinutes,
    });
    expect(sync.calls, 1);
  });

  test('completeCard no mesmo dia local mantém streak', () async {
    final now = DateTime(2026, 9, 10, 12);
    repository = StudyRepository(db, fire, auth, sync, reviewNow: () => now);
    sync.drains = false;
    await subject(cards: 1);
    await stats(queue: 1, streak: 5, lastStudyDate: DateTime(2026, 9, 10, 8));
    await card();

    await repository.completeCard('card-1');

    final updatedStats = await db.select(db.studyStats).getSingle();
    expect(updatedStats.streak, 5);
    expect(updatedStats.lastStudyDate, now.millisecondsSinceEpoch);
  });

  test('completeCard após gap reinicia streak', () async {
    final now = DateTime(2026, 9, 10, 12);
    repository = StudyRepository(db, fire, auth, sync, reviewNow: () => now);
    sync.drains = false;
    await subject(cards: 1);
    await stats(queue: 1, streak: 5, lastStudyDate: DateTime(2026, 9, 7, 12));
    await card();

    await repository.completeCard('card-1');

    final updatedStats = await db.select(db.studyStats).getSingle();
    expect(updatedStats.streak, 1);
    expect(updatedStats.lastStudyDate, now.millisecondsSinceEpoch);
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
    // Reconciled: Rules C deny the obsolete absolute-counter producer.
    // Reset retains its own durable intent, UUID, payload and UTC assertions.
    final state = StudyModel(streak: 1, reviewQueue: 2, progress: .8);
    await stats(queue: 2, progress: .8, streak: 1);
    await subject(cards: 2);
    await card();
    final beforeStats = await db.select(db.studyStats).getSingle();
    final beforeCards = await db.select(db.flashcards).get();
    final beforeQueue = await db.select(db.syncQueueTable).get();
    await expectLater(
      repository.completeReview(state),
      throwsA(isA<UnsupportedError>()),
    );
    expect(await db.select(db.studyStats).getSingle(), beforeStats);
    expect(await db.select(db.flashcards).get(), beforeCards);
    expect(await db.select(db.syncQueueTable).get(), beforeQueue);
    expect(sync.calls, 0);
    await repository.resetDailyProgress(state);
    expect((await db.select(db.studyStats).getSingle()).reviewQueue, 2);
    expect((await db.select(db.studyStats).getSingle()).progress, 0);
    final queue = await db.getPendingSyncItems('user-a');
    expect(queue, hasLength(1));
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

  group('compatibilidade de matérias remotas históricas', () {
    Map<String, dynamic> legacySubject() => {
      'title': 'Matemática',
      'hasExam': false,
      'examDate': null,
      'createdAt': Timestamp.fromDate(DateTime.utc(2025, 1, 1)),
    };

    for (final fields in <Map<String, dynamic>>[
      {},
      {'cardsToReview': 4},
      {'streakDays': 3},
      {'progress': .4},
      {'cardsToReview': 4, 'streakDays': 3},
      {'cardsToReview': 4, 'progress': .4},
      {'streakDays': 3, 'progress': .4},
      {'cardsToReview': 4, 'streakDays': 3, 'progress': .4},
    ]) {
      final schema = fields.isEmpty
          ? 'histórico exato'
          : fields.keys.join(', ');
      test(
        'banco vazio hidrata $schema sem escrita remota ou SyncQueue',
        () async {
          final data = {...legacySubject(), ...fields};
          final remote = _QueryDoc('subject-1', Map.of(data));
          fire.subjects.documents = [remote];
          expect(await db.select(db.subjects).get(), isEmpty);

          await repository.syncStudyFromFirebaseToLocal();

          final local = await db.select(db.subjects).getSingle();
          expect(local.id, 'subject-1');
          expect(local.title, 'Matemática');
          expect(local.cardsToReview, fields['cardsToReview'] ?? 0);
          expect(local.streakDays, fields['streakDays'] ?? 0);
          expect(local.progress, fields['progress'] ?? 0.0);
          expect(local.hasExam, isFalse);
          expect(local.examDate, null);
          expect(fire.subjects.options?.source, Source.server);
          expect(remote.values, data);
          expect(await db.select(db.syncQueueTable).get(), isEmpty);
        },
      );
    }

    test('matéria local existente é hidratada pelo schema histórico', () async {
      await subject(cards: 9);
      fire.subjects.documents = [_QueryDoc('subject-1', legacySubject())];

      await repository.syncStudyFromFirebaseToLocal();

      final local = await db.select(db.subjects).getSingle();
      expect(local.id, 'subject-1');
      expect(local.title, 'Matemática');
      expect(local.cardsToReview, 0);
      expect(local.streakDays, 0);
      expect(local.progress, 0.0);
      expect(await db.select(db.syncQueueTable).get(), isEmpty);
    });

    for (final testCase in <String, Map<String, dynamic>>{
      'cardsToReview String': {'cardsToReview': '3'},
      'cardsToReview negativo': {'cardsToReview': -1},
      'cardsToReview null': {'cardsToReview': null},
      'cardsToReview fracionário': {'cardsToReview': 1.5},
      'streakDays negativo': {'streakDays': -1},
      'streakDays fracionário': {'streakDays': 1.5},
      'streakDays String': {'streakDays': '3'},
      'streakDays null': {'streakDays': null},
      'progress String': {'progress': '0.5'},
      'progress negativo': {'progress': -.1},
      'progress acima de um': {'progress': 1.1},
      'progress NaN': {'progress': double.nan},
      'progress infinito': {'progress': double.infinity},
      'progress null': {'progress': null},
      'title vazio': {'title': '   '},
      'title não String': {'title': 3},
      'hasExam não bool': {'hasExam': 'false'},
      'examDate inválido': {'examDate': 'invalid'},
    }.entries) {
      test('valor presente inválido rejeitado: ${testCase.key}', () async {
        fire.subjects.documents = [
          _QueryDoc('subject-1', {...legacySubject(), ...testCase.value}),
        ];

        await repository.syncStudyFromFirebaseToLocal();

        expect(await db.select(db.subjects).get(), isEmpty);
        expect(await db.select(db.syncQueueTable).get(), isEmpty);
      });
    }

    for (final field in ['title', 'hasExam']) {
      test('$field ausente continua rejeitado', () async {
        final data = legacySubject()..remove(field);
        fire.subjects.documents = [_QueryDoc('subject-1', data)];

        await repository.syncStudyFromFirebaseToLocal();

        expect(await db.select(db.subjects).get(), isEmpty);
      });
    }

    test('ID vazio continua rejeitado', () async {
      fire.subjects.documents = [_QueryDoc('   ', legacySubject())];

      await repository.syncStudyFromFirebaseToLocal();

      expect(await db.select(db.subjects).get(), isEmpty);
    });

    final examDate = DateTime.utc(2026, 11, 1);
    for (final testCase in <String, Object>{
      'Timestamp': Timestamp.fromDate(examDate),
      'DateTime': examDate,
      'String parseável': examDate.toIso8601String(),
    }.entries) {
      test(
        'schema moderno preserva examDate ${testCase.key} e metadata',
        () async {
          final data = {
            ...remoteSubject('Matemática'),
            'hasExam': true,
            'examDate': testCase.value,
            'createdAt': Timestamp.fromDate(DateTime.utc(2025, 1, 1)),
            'updatedAt': Timestamp.fromDate(DateTime.utc(2026, 1, 1)),
          };
          final remote = _QueryDoc('subject-1', Map.of(data));
          fire.subjects.documents = [remote];

          await repository.syncStudyFromFirebaseToLocal();

          final local = await db.select(db.subjects).getSingle();
          expect(local.title, 'Matemática');
          expect(local.cardsToReview, 2);
          expect(local.streakDays, 3);
          expect(local.progress, .4);
          expect(local.hasExam, isTrue);
          expect(local.examDate, examDate.millisecondsSinceEpoch);
          expect(remote.values, data);
          expect(await db.select(db.syncQueueTable).get(), isEmpty);
        },
      );
    }
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
  group('ReviewQueue prospective create protocol and unresolved pull', () {
    test(
      'new local creation persists original stable ID, canonical UTC and v1 atomically',
      () async {
        await subject();
        await repository.addFlashcard('subject-1', 'Pergunta', 'Resposta');
        final item = (await db.getPendingSyncItems('user-a')).single;
        final payload = jsonDecode(item.payloadJson) as Map<String, dynamic>;
        expect(payload.keys.toSet(), {
          'cardId',
          'subjectId',
          'question',
          'answer',
          'createdAt',
          'creationProtocolVersion',
        });
        expect(payload['creationProtocolVersion'], 1);
        expect(payload['cardId'], item.docId);
        expect((await db.select(db.flashcards).getSingle()).id, item.docId);
        final created = DateTime.parse(payload['createdAt'] as String);
        expect(created.isUtc, isTrue);
        expect(created.toIso8601String(), payload['createdAt']);
        expect(item.ownerUid, 'user-a');
        expect((await db.select(db.studyStats).getSingle()).reviewQueue, 1);
        expect((await db.select(db.subjects).getSingle()).cardsToReview, 1);
        final before = item.payloadJson;
        sync.drains = false;
        await repository.syncStudyFromFirebaseToLocal();
        expect(
          (await db.getPendingSyncItems('user-a')).single.payloadJson,
          before,
        );
      },
    );
    test('enqueue failure rolls back card and both local counters', () async {
      await subject(cards: 2);
      await stats(queue: 2);
      rawDb.execute(
        "CREATE TRIGGER fail_card_enqueue BEFORE INSERT ON sync_queue_table BEGIN SELECT RAISE(ABORT,'synthetic enqueue failure'); END;",
      );
      await expectLater(
        repository.addFlashcard('subject-1', 'Q', 'A'),
        throwsA(anything),
      );
      expect(await db.select(db.flashcards).get(), isEmpty);
      expect((await db.select(db.subjects).getSingle()).cardsToReview, 2);
      expect((await db.select(db.studyStats).getSingle()).reviewQueue, 2);
      expect(await db.getPendingSyncItems('user-a'), isEmpty);
    });
    for (final rejected in [false, true])
      for (final staleCard in [false, true])
        test(
          '${rejected ? 'rejected' : 'pending'} unresolved card survives ${staleCard ? 'old' : 'empty'} remote pull with counters',
          () async {
            await subject(cards: 7);
            await stats(queue: 7);
            await card();
            final id = await db.insertSyncItem(
              ownerUid: 'user-a',
              collection: 'review_queue',
              docId: 'card-1',
              operationType: 'create',
              payloadJson:
                  '{"subjectId":"subject-1","question":"Pergunta","answer":"Resposta","createdAt":"old local time"}',
            );
            if (rejected)
              await db.markSyncItemRejected(id, 'user-a', 'INVALID_PAYLOAD');
            final original =
                (await db.getSyncItemById(id))! as SyncQueueTableData;
            fire.info.document.values = {'reviewQueue': 0};
            if (staleCard) {
              fire.subjects.documents = [
                _QueryDoc('subject-1', remoteSubject('Old remote')),
              ];
              fire.cards.documents = [
                _QueryDoc('card-1', {
                  'subjectId': 'subject-1',
                  'question': 'Old',
                  'answer': 'Old',
                }),
              ];
            }
            await repository.syncStudyFromFirebaseToLocal();
            expect(
              (await db.select(db.flashcards).getSingle()).question,
              'Pergunta',
            );
            expect((await db.select(db.subjects).getSingle()).cardsToReview, 7);
            expect((await db.select(db.studyStats).getSingle()).reviewQueue, 7);
            final row = (await db.getSyncItemById(id))! as SyncQueueTableData;
            expect(row.status, original.status);
            expect(row.payloadJson, original.payloadJson);
            expect(row.id, id);
          },
        );
    for (final kind in [
      'other-owner',
      'other-family',
      'review-update',
      'resolved-card',
    ])
      test(
        '$kind rejected row preserves unresolved review data and unrelated pull',
        () async {
          await subject();
          await stats(queue: 7);
          final isB = kind == 'other-owner';
          if (isB) auth.user = _User('user-b');
          await db.insertSyncItem(
            ownerUid: 'user-a',
            collection: kind == 'other-family' ? 'tasks' : 'review_queue',
            docId: 'card-1',
            operationType: kind == 'review-update' ? 'update' : 'create',
            payloadJson: '{}',
          );
          final queued = (await db.select(db.syncQueueTable).get()).single;
          await db.markSyncItemRejected(queued.id, 'user-a', 'INVALID_PAYLOAD');
          if (kind != 'resolved-card') await card();
          fire.info.document.values = {'reviewQueue': 2};
          fire.subjects.documents = [
            _QueryDoc('subject-1', remoteSubject('New legitimate')),
          ];
          fire.cards.documents = [
            _QueryDoc('new-card', {
              'subjectId': 'subject-1',
              'question': 'Legitimate',
              'answer': 'New',
            }),
          ];
          await repository.syncStudyFromFirebaseToLocal();
          if (kind == 'review-update') {
            expect((await db.select(db.studyStats).getSingle()).reviewQueue, 7);
            expect(
              (await (db.select(
                db.flashcards,
              )..where((c) => c.id.equals('card-1'))).getSingle()).question,
              'Pergunta',
            );
            expect(
              (await db.select(db.subjects).getSingle()).title,
              'Matemática',
            );
            expect(
              (await (db.select(
                db.flashcards,
              )..where((c) => c.id.equals('new-card'))).getSingle()).question,
              'Legitimate',
            );
            expect(
              (await db.getSyncItemById(queued.id)).status,
              SyncQueuePersistenceStatus.rejected,
            );
          } else {
            expect((await db.select(db.studyStats).getSingle()).reviewQueue, 2);
            expect((await db.select(db.flashcards).getSingle()).id, 'new-card');
            expect(
              (await db.select(db.subjects).getSingle()).title,
              'New legitimate',
            );
          }
        },
      );
    test(
      'rejected create protects only its subject; another family hydrates normally',
      () async {
        await subject(cards: 7);
        await subject(id: 'subject-2');
        await stats(queue: 7);
        await card();
        final id = await db.insertSyncItem(
          ownerUid: 'user-a',
          collection: 'review_queue',
          docId: 'card-1',
          operationType: 'create',
          payloadJson: 'broken',
        );
        await db.markSyncItemRejected(id, 'user-a', 'INVALID_PAYLOAD');
        fire.subjects.documents = [
          _QueryDoc('subject-1', remoteSubject('Old')),
          _QueryDoc('subject-2', remoteSubject('Hydrated')),
        ];
        await repository.syncStudyFromFirebaseToLocal();
        final subjects = await db.select(db.subjects).get();
        expect(
          subjects.firstWhere((s) => s.id == 'subject-1').title,
          'Matemática',
        );
        expect(
          subjects.firstWhere((s) => s.id == 'subject-2').title,
          'Hydrated',
        );
        expect(await db.select(db.flashcards).get(), hasLength(1));
      },
    );
    test(
      'A to B during unresolved reconciliation cannot overwrite A or admit stale response',
      () async {
        await subject(cards: 7);
        await stats(queue: 7);
        await card();
        final id = await db.insertSyncItem(
          ownerUid: 'user-a',
          collection: 'review_queue',
          docId: 'card-1',
          operationType: 'create',
          payloadJson: '{}',
        );
        await db.markSyncItemRejected(id, 'user-a', 'INVALID_PAYLOAD');
        fire.cards.beforeGet = () async {
          auth.user = _User('user-b');
        };
        await repository.syncStudyFromFirebaseToLocal();
        expect(
          (await db.select(db.flashcards).getSingle()).question,
          'Pergunta',
        );
        expect((await db.select(db.studyStats).getSingle()).reviewQueue, 7);
        expect(
          (await db.select(db.syncQueueTable).getSingle()).ownerUid,
          'user-a',
        );
      },
    );
    test(
      'resolved succeeded creation does not prevent legitimate card deletion',
      () async {
        await subject();
        await stats(queue: 1);
        await card();
        final id = await db.insertSyncItem(
          ownerUid: 'user-a',
          collection: 'review_queue',
          docId: 'card-1',
          operationType: 'create',
          payloadJson: '{}',
        );
        await db.markSyncItemAsSucceeded(id, 'user-a');
        await db.customStatement(
          'UPDATE sync_queue_table SET created_at = 1 WHERE id = ?',
          [id],
        );
        fire.info.document.values = {'reviewQueue': 0};
        await repository.syncStudyFromFirebaseToLocal();
        expect(await db.select(db.flashcards).get(), isEmpty);
        expect((await db.select(db.studyStats).getSingle()).reviewQueue, 0);
      },
    );
  });
  group('ReviewQueue visibility from persisted local state', () {
    Map<String, dynamic> creation({bool legacy = false}) => {
      if (!legacy) 'creationProtocolVersion': 1,
      if (!legacy) 'cardId': 'card-1',
      'subjectId': 'subject-1',
      'question': 'Pergunta',
      'answer': 'Resposta',
      'createdAt': legacy
          ? '2026-10-28T12:34:56'
          : '2026-10-28T12:34:56.123456Z',
    };
    Future<int> pending({
      String uid = 'user-a',
      String id = 'card-1',
      bool legacy = false,
      String collection = 'review_queue',
      String operation = 'create',
    }) => db.insertSyncItem(
      ownerUid: uid,
      collection: collection,
      docId: id,
      operationType: operation,
      payloadJson: jsonEncode({
        ...creation(legacy: legacy),
        if (!legacy) 'cardId': id,
      }),
    );
    Future<_VisibilityProbe> probe() async {
      final p = _VisibilityProbe(repository.watchReviewCreationSync());
      addTearDown(p.cancel);
      return p;
    }

    test(
      'empty persisted queue emits no affected account state or remote pull',
      () async {
        final p = await probe();
        final state = await p.until((s) => s.isCurrent);
        expect(state.affected, 0);
        expect(fire.info.document.calls, 0);
        expect(fire.cards.calls, 0);
        expect(sync.calls, 0);
      },
    );
    test(
      'new local creation becomes ordinary pending without duplicate counters',
      () async {
        await subject();
        final p = await probe();
        await p.until((s) => s.isCurrent);
        await repository.addFlashcard('subject-1', 'Pergunta', 'Resposta');
        final state = await p.until((s) => s.pending == 1 && s.isCurrent);
        expect(state.recovery, 0);
        expect(state.indeterminate, 0);
        expect(state.canRequestRetry, isFalse);
        expect((await db.select(db.studyStats).getSingle()).reviewQueue, 1);
        expect((await db.select(db.subjects).getSingle()).cardsToReview, 1);
        expect(await db.select(db.flashcards).get(), hasLength(1));
      },
    );
    for (final outcome in ['APPLIED', 'REPLAYED'])
      test(
        'validated HTTP ACK $outcome removes visibility through actual Manager',
        () async {
          await subject(cards: 1);
          await stats(queue: 1);
          await card();
          await pending();
          final source = FirestoreSyncRemoteDataSource(
            fire,
            auth,
            captureRemoteSend: (uid) =>
                db.localMutations.captureRemoteSend(expectedUid: uid),
            idTokenProvider: (_, _) async => 'synthetic-token',
            appCheckTokenProvider: () async => 'synthetic-app-check',
            clientFactory: () => MockClient((request) async {
              final body = jsonDecode(request.body) as Map<String, dynamic>;
              final frame = <int>[];
              for (final text in [
                'review-create-v1',
                'user-a',
                body['cardId'],
                body['subjectId'],
                body['question'],
                body['answer'],
                body['createdAt'],
              ]) {
                final bytes = utf8.encode(text as String);
                frame
                  ..addAll(ascii.encode('${bytes.length}:'))
                  ..addAll(bytes);
              }
              return http.Response(
                jsonEncode({
                  'success': true,
                  'operation': 'create_review_card',
                  'version': 1,
                  'uid': 'user-a',
                  'operationId': 'card-1',
                  'fingerprint': sha256.convert(frame).toString(),
                  'outcome': outcome,
                  'effectsCommitted': true,
                }),
                200,
              );
            }),
          );
          final manager = SyncManager(
            queueStore: AppDatabaseSyncQueueStore(db),
            remoteDataSource: source,
            currentUserId: () => auth.currentUser?.uid,
          );
          addTearDown(manager.dispose);
          repository = StudyRepository(db, fire, auth, manager);
          final p = await probe();
          await p.until((s) => s.pending == 1 && s.isCurrent);
          expect(await manager.processPendingItems(), isTrue);
          expect(
            (await p.until((s) => s.isCurrent && s.affected == 0)).affected,
            0,
          );
          expect(
            (await db.select(db.syncQueueTable).getSingle()).status,
            SyncQueuePersistenceStatus.succeeded,
          );
          expect((await db.select(db.studyStats).getSingle()).reviewQueue, 1);
          expect((await db.select(db.subjects).getSingle()).cardsToReview, 1);
          expect(
            (await db.select(db.flashcards).getSingle()).question,
            'Pergunta',
          );
        },
      );
    for (final code in [
      'SYNC_TIMEOUT',
      'REVIEW_CREATE_ACK_INVALID',
      'REVIEW_CREATE_UNCONFIRMED',
      'FIRESTORE_PERMISSION_UNCONFIRMED',
      'PERMISSION-DENIED',
      'ACCOUNT_DELETION_BLOCKED',
      'NETWORK_ERROR',
      'BACKEND_503',
    ])
      test('$code is indeterminate, not account-deletion proof', () async {
        await subject();
        await card();
        final id = await pending();
        await db.markSyncItemRetryableFailure(id, 'user-a', code);
        final p = await probe(),
            state = await p.until((s) => s.isCurrent && s.affected > 0);
        expect(state.indeterminate, 1);
        expect(state.recovery, 0);
        expect(state.pending, 0);
        expect(
          (await db.getSyncItemById(id) as SyncQueueTableData).status,
          SyncQueuePersistenceStatus.pending,
        );
      });
    for (final code in [
      'REVIEW_CREATE_LEGACY_UNVERIFIED',
      'REVIEW_CREATE_FINGERPRINT_CONFLICT',
      'REVIEW_CREATE_RECEIPT_INVALID',
      'REVIEW_CREATE_ROOT_UNAVAILABLE',
      'REVIEW_CREATE_SUBJECT_UNAVAILABLE',
      'REVIEW_CREATE_SUBJECT_TOMBSTONED',
      'REVIEW_CREATE_STATE_INVALID',
    ])
      test('$code preserves recovery and original payload', () async {
        await subject();
        await card();
        final id = await pending();
        final original = (await db.getSyncItemById(id))! as SyncQueueTableData;
        await db.markSyncItemRetryableFailure(id, 'user-a', code);
        final p = await probe(),
            state = await p.until((s) => s.isCurrent && s.affected > 0);
        expect(state.recovery, 1);
        expect(state.canRequestRetry, isFalse);
        final row = (await db.getSyncItemById(id))! as SyncQueueTableData;
        expect(row.payloadJson, original.payloadJson);
        expect(row.docId, original.docId);
        expect(row.id, id);
      });
    test(
      'legacy without marker needs verification before any attempt, no promotion or fabricated UTC',
      () async {
        await subject();
        await card();
        final id = await pending(legacy: true), p = await probe();
        final before = (await db.getSyncItemById(id))! as SyncQueueTableData;
        expect(
          (await p.until((s) => s.isCurrent && s.affected > 0)).recovery,
          1,
        );
        expect(
          (await db.getSyncItemById(id) as SyncQueueTableData).payloadJson,
          before.payloadJson,
        );
        expect(sync.calls, 0);
      },
    );
    test(
      'terminal 403 rejected create remains visible only while local card exists',
      () async {
        await subject();
        await card();
        final id = await pending();
        await db.markSyncItemRejected(id, 'user-a', 'PERMISSION_DENIED');
        final p = await probe();
        expect(
          (await p.until((s) => s.isCurrent && s.affected > 0)).recovery,
          1,
        );
        await (db.delete(
          db.flashcards,
        )..where((t) => t.id.equals('card-1'))).go();
        expect(
          (await p.until((s) => s.isCurrent && s.affected == 0)).affected,
          0,
        );
        expect(
          (await db.getSyncItemById(id) as SyncQueueTableData).status,
          SyncQueuePersistenceStatus.rejected,
        );
        expect(await db.select(db.flashcards).get(), isEmpty);
      },
    );
    test(
      'unresolved rejected create still survives the existing empty pull',
      () async {
        await subject(cards: 7);
        await stats(queue: 7);
        await card();
        final id = await pending();
        await db.markSyncItemRejected(id, 'user-a', 'INVALID_PAYLOAD');
        final p = await probe();
        await p.until((s) => s.isCurrent && s.recovery == 1);
        fire.info.document.values = {'reviewQueue': 0};
        await repository.syncStudyFromFirebaseToLocal();
        expect((await db.select(db.flashcards).getSingle()).id, 'card-1');
        expect((await db.select(db.studyStats).getSingle()).reviewQueue, 7);
        expect((await db.select(db.subjects).getSingle()).cardsToReview, 7);
      },
    );
    for (final family in ['tasks', 'study_info', 'subjects'])
      test('rejected $family is not a ReviewQueue incident', () async {
        await subject();
        await card();
        final id = await pending(collection: family);
        await db.markSyncItemRejected(id, 'user-a', 'INVALID_PAYLOAD');
        final p = await probe();
        expect((await p.until((s) => s.isCurrent)).affected, 0);
      });
    test(
      'rejected review update is not classified as failed creation',
      () async {
        await subject();
        await card();
        final id = await pending(operation: 'update');
        await db.markSyncItemRejected(id, 'user-a', 'INVALID_PAYLOAD');
        final p = await probe();
        expect((await p.until((s) => s.isCurrent)).affected, 0);
      },
    );
    test(
      'counts deduplicate card identities and prefer recovery over ordinary pending',
      () async {
        await subject();
        await card();
        await pending();
        final rejected = await pending();
        await db.markSyncItemRejected(rejected, 'user-a', 'PERMISSION_DENIED');
        final p = await probe(),
            state = await p.until((s) => s.isCurrent && s.recovery == 1);
        expect(state.affected, 1);
        expect(state.pending, 0);
      },
    );
    test(
      'same UID A-B-A invalidates retained generation and old retry admission',
      () async {
        await subject();
        await card();
        final id = await pending();
        await db.markSyncItemRetryableFailure(id, 'user-a', 'SYNC_TIMEOUT');
        db.localMutations.bindSessionReader(() => auth.currentUser?.uid);
        db.localMutations.openPreparedSession();
        final p = await probe(),
            original = await p.until(
              (s) => s.isCurrent && s.indeterminate == 1,
            );
        auth.emitSession('user-b');
        db.localMutations.observeSession('user-b');
        expect(original.isCurrent, isFalse);
        auth.emitSession('user-a');
        db.localMutations.observeSession('user-a');
        db.localMutations.openPreparedSession();
        final state = await p.until(
          (s) =>
              s.isCurrent &&
              s.indeterminate == 1 &&
              !identical(s.sessionToken, original.sessionToken),
        );
        expect(original.isCurrent, isFalse);
        expect(state.affected, 1);
        await repository.retryReviewCreationSync(original);
        expect(sync.calls, 0);
      },
    );
    test(
      'logout hides old counts; return to A rehydrates own queue only',
      () async {
        await subject();
        await card();
        await pending();
        final p = await probe(),
            a = await p.until((s) => s.isCurrent && s.pending == 1);
        auth.emitSession(null);
        expect(a.isCurrent, isFalse);
        await p.until((s) => !s.isCurrent && s.affected == 0);
        auth.emitSession('user-a');
        final resumed = await p.until((s) => s.isCurrent && s.pending == 1);
        expect(identical(resumed.sessionToken, a.sessionToken), isFalse);
      },
    );
    test(
      'late A queue updates cannot publish A status to B; B has independent rows',
      () async {
        await subject();
        await card();
        await card(id: 'card-b');
        final aId = await pending();
        await pending(uid: 'user-b', id: 'card-b');
        final p = await probe();
        final a = await p.until((s) => s.isCurrent && s.pending == 1);
        auth.emitSession('user-b');
        expect(a.isCurrent, isFalse);
        final b = await p.until(
          (s) =>
              s.isCurrent &&
              s.pending == 1 &&
              !identical(s.sessionToken, a.sessionToken),
        );
        await db.markSyncItemRejected(
          aId,
          'user-a',
          'REVIEW_CREATE_FINGERPRINT_CONFLICT',
        );
        final bAfter = await p.until(
          (s) => s.isCurrent && identical(s.sessionToken, b.sessionToken),
        );
        expect(bAfter.recovery, 0);
        auth.emitSession('user-a');
        expect(
          (await p.until((s) => s.isCurrent && s.recovery == 1)).affected,
          1,
        );
      },
    );
    test(
      'cancelling visibility invalidates snapshots and removes Auth observer',
      () async {
        await subject();
        await card();
        await pending();
        final p = await probe(),
            state = await p.until((s) => s.isCurrent && s.pending == 1);
        expect(auth.visibilityListeners, 1);
        await p.cancel();
        expect(auth.visibilityListeners, 0);
        expect(state.isCurrent, isFalse);
      },
    );
    test(
      'manual retry drains existing Manager only, never marks ACK or mutates identity/counters',
      () async {
        await subject(cards: 1);
        await stats(queue: 1);
        await card();
        final id = await pending();
        await db.markSyncItemRetryableFailure(id, 'user-a', 'SYNC_TIMEOUT');
        final original = (await db.getSyncItemById(id))! as SyncQueueTableData;
        final p = await probe(),
            state = await p.until((s) => s.isCurrent && s.indeterminate == 1);
        sync.drains = false;
        await repository.retryReviewCreationSync(state);
        expect(sync.calls, 1);
        final row = (await db.getSyncItemById(id))! as SyncQueueTableData;
        expect(row.payloadJson, original.payloadJson);
        expect(row.id, id);
        expect(row.status, SyncQueuePersistenceStatus.pending);
        expect((await db.select(db.studyStats).getSingle()).reviewQueue, 1);
        expect((await db.select(db.subjects).getSingle()).cardsToReview, 1);
        expect(fire.info.document.calls, 0);
      },
    );
    test('isSynced false does not reinterpret succeeded as pending', () async {
      await subject();
      await card();
      final id = await pending();
      await db.markSyncItemAsSucceeded(id, 'user-a');
      await db.customStatement(
        'UPDATE sync_queue_table SET is_synced = 0 WHERE id = ?',
        [id],
      );
      final p = await probe();
      expect((await p.until((s) => s.isCurrent)).affected, 0);
    });
  });
  group('S2 obsolete absolute review producer', () {
    for (final queue in [-1, 0, 2]) {
      for (final signedIn in [false, true]) {
        test(
          'fails without any business effect: queue=$queue signedIn=$signedIn',
          () async {
            await stats(queue: 7, progress: .6, streak: 4);
            await subject(cards: 7);
            await card();
            auth.user = signedIn ? _User('user-a') : null;
            final statsBefore = await db.select(db.studyStats).get();
            final cardsBefore = await db.select(db.flashcards).get();
            final subjectsBefore = await db.select(db.subjects).get();
            final rowsBefore = await db.select(db.syncQueueTable).get();
            final readsBefore = auth.reads;
            await expectLater(
              repository.completeReview(
                StudyModel(streak: 1, reviewQueue: queue, progress: .8),
              ),
              throwsA(
                isA<UnsupportedError>().having(
                  (e) => e.message,
                  'sanitized error',
                  'STUDY_INFO_LEGACY_REVIEW_DISABLED',
                ),
              ),
            );
            expect(auth.reads, readsBefore);
            expect(await db.select(db.studyStats).get(), statsBefore);
            expect(await db.select(db.flashcards).get(), cardsBefore);
            expect(await db.select(db.subjects).get(), subjectsBefore);
            expect(await db.select(db.syncQueueTable).get(), rowsBefore);
            expect(sync.calls, 0);
            expect(fire.info.document.calls, 0);
          },
        );
      }
    }
    test('empty database is not initialized by obsolete method', () async {
      await expectLater(
        repository.completeReview(
          StudyModel(streak: 0, reviewQueue: 2, progress: 0),
        ),
        throwsA(isA<UnsupportedError>()),
      );
      expect(await db.select(db.studyStats).get(), isEmpty);
      expect(await db.select(db.flashcards).get(), isEmpty);
      expect(await db.select(db.syncQueueTable).get(), isEmpty);
      expect(sync.calls, 0);
    });
  });
  group('S3 queue-first Study visibility', () {
    Map<String, dynamic> v1(String id) => {
      'creationProtocolVersion': 1,
      'cardId': id,
      'subjectId': 'subject-1',
      'question': 'Pergunta',
      'answer': 'Resposta',
      'createdAt': '2026-10-28T12:34:56.123456Z',
    };
    Future<int> intent({
      String uid = 'user-a',
      String collection = 'review_queue',
      String id = 'card-1',
      String operation = 'create',
      String status = SyncQueuePersistenceStatus.pending,
      String? payload,
      int attempts = 0,
      String? code,
    }) => db
        .into(db.syncQueueTable)
        .insert(
          SyncQueueTableCompanion.insert(
            ownerUid: Value(uid),
            collection: collection,
            docId: id,
            operationType: operation,
            payloadJson: payload ?? jsonEncode(v1(id)),
            createdAt: 1,
            status: Value(status),
            attemptCount: Value(attempts),
            lastErrorCode: Value(code),
          ),
        );
    Future<_VisibilityProbe> watch() async {
      final p = _VisibilityProbe(repository.watchReviewCreationSync());
      addTearDown(p.cancel);
      return p;
    }

    for (final legacy in [false, true]) {
      test(
        'pending missing card is an operation, never a fabricated card; legacy=$legacy',
        () async {
          final id = await intent(
            payload: legacy ? '  {"question":"old"}  ' : null,
          );
          final original = await db.getSyncItemById(id), p = await watch();
          final state = await p.until(
            (s) => s.isCurrent && s.pendingWithoutCard == 1,
          );
          expect(state.affected, 0);
          expect(state.legacyPending, legacy ? 1 : 0);
          expect(state.hasNotice, isTrue);
          expect(state.needsVerification, isTrue);
          expect(state.headBlocked, isTrue);
          expect(state.waitingBehindHead, 0);
          expect(state.canRequestRetry, isFalse);
          await repository.retryReviewCreationSync(state);
          expect(sync.calls, 0);
          expect(await db.getSyncItemById(id), original);
          expect(await db.select(db.flashcards).get(), isEmpty);
        },
      );
    }
    for (final operation in [' CrEaTe ', '\tUPDATE\n']) {
      test(
        'StudyInfo contract HOLD visible without card, independent of payload/attempts: $operation',
        () async {
          final id = await intent(
            collection: '\tstudy_info\n',
            id: '\u00a0main\ufeff',
            operation: operation,
            payload: ' private malformed JSON ',
            attempts: 9,
            code: 'OLD_PRIVATE_CODE',
          );
          final original = await db.getSyncItemById(id), p = await watch();
          final state = await p.until(
            (s) => s.isCurrent && s.studyInfoHold == 1,
          );
          expect(state.affected, 0);
          expect(state.pendingWithoutCard, 0);
          expect(state.headBlocked, isTrue);
          expect(state.canRequestRetry, isFalse);
          await repository.retryReviewCreationSync(state);
          expect(sync.calls, 0);
          expect(await db.getSyncItemById(id), original);
        },
      );
    }
    test(
      'counts existing cards distinctly and missing operations individually, never adding rejected or succeeded as pending',
      () async {
        await subject();
        await card();
        await intent();
        await intent(payload: '{}');
        await intent(id: 'orphan');
        await intent(id: 'orphan');
        await intent(collection: 'study_info', id: 'main', operation: 'update');
        await intent(
          id: 'rejected-orphan',
          status: SyncQueuePersistenceStatus.rejected,
        );
        await intent(
          id: 'done-orphan',
          status: SyncQueuePersistenceStatus.succeeded,
        );
        final original = await db.select(db.syncQueueTable).get(),
            p = await watch();
        final state = await p.until(
          (s) => s.isCurrent && s.pendingWithoutCard == 2,
        );
        expect(state.affected, 1);
        expect(state.recovery, 1);
        expect(state.studyInfoHold, 1);
        expect(state.rejectedWithoutCard, 1);
        expect(state.legacyPending, 1);
        // The first operation is a valid v1 head; later problems do not prove it blocked.
        expect(state.headBlocked, isFalse);
        expect(state.waitingBehindHead, 0);
        expect(state.canRequestRetry, isFalse);
        expect(await db.select(db.syncQueueTable).get(), original);
      },
    );
    test(
      'only the minimum pending ID proves a problematic head and counts later pending of that owner',
      () async {
        await intent(
          id: 'old-rejected',
          status: SyncQueuePersistenceStatus.rejected,
        );
        await intent(collection: 'study_info', id: 'main', operation: 'update');
        await intent(collection: 'tasks', id: 'task-after');
        await intent(id: 'orphan-after');
        await intent(uid: 'user-b', id: 'b');
        await intent(id: 'done', status: SyncQueuePersistenceStatus.succeeded);
        final p = await watch(),
            s = await p.until((s) => s.isCurrent && s.studyInfoHold == 1);
        expect(s.headBlocked, isTrue);
        expect(s.waitingBehindHead, 2);
        expect(s.pendingWithoutCard, 1);
        expect(s.affected, 0);
        expect(sync.calls, 0);
      },
    );
    for (final kind in ['study', 'legacy', 'orphan']) {
      test(
        'problematic $kind behind another family is visible but not called the FIFO head',
        () async {
          await subject();
          await card();
          await intent(collection: 'tasks', id: 'actual-head');
          if (kind == 'study') {
            await intent(
              collection: 'study_info',
              id: 'main',
              operation: 'update',
            );
          } else {
            await intent(
              id: kind == 'orphan' ? 'missing' : 'card-1',
              payload: kind == 'legacy' ? '{}' : null,
            );
          }
          final p = await watch(),
              s = await p.until((s) => s.isCurrent && s.hasNotice);
          expect(s.needsVerification, isTrue);
          expect(s.headBlocked, isFalse);
          expect(s.waitingBehindHead, 0);
          expect(s.canRequestRetry, isFalse);
          expect(sync.calls, 0);
        },
      );
    }
    test(
      'rejected missing card is retained separately and never pins FIFO or shows fictitious pending',
      () async {
        final id = await intent(status: SyncQueuePersistenceStatus.rejected),
            original = await db.getSyncItemById(id);
        final p = await watch(), s = await p.until((s) => s.isCurrent);
        expect(s.rejectedWithoutCard, 1);
        expect(s.affected, 0);
        expect(s.pendingWithoutCard, 0);
        expect(s.hasNotice, isFalse);
        expect(s.headBlocked, isFalse);
        expect(s.waitingBehindHead, 0);
        expect(await db.getSyncItemById(id), original);
      },
    );
    test(
      'succeeded StudyInfo and ReviewQueue without cards never produce pending notice',
      () async {
        await intent(status: SyncQueuePersistenceStatus.succeeded);
        await intent(
          collection: 'study_info',
          id: 'main',
          operation: 'update',
          status: SyncQueuePersistenceStatus.succeeded,
        );
        final p = await watch(), s = await p.until((s) => s.isCurrent);
        expect(s.hasNotice, isFalse);
        expect(s.studyInfoHold, 0);
        expect(s.pendingWithoutCard, 0);
        expect(s.affected, 0);
      },
    );
    for (final patch in [
      <String, dynamic>{'createdAt': '2026-10-28T12:34:56'},
      {'question': 'different'},
      {'extra': true},
    ]) {
      test(
        'v1 marker alone does not admit manual retry: ${patch.keys.single}',
        () async {
          await subject();
          await card();
          await intent(
            payload: jsonEncode({...v1('card-1'), ...patch}),
            attempts: 1,
            code: 'SYNC_TIMEOUT',
          );
          final p = await watch(),
              s = await p.until((s) => s.isCurrent && s.hasNotice);
          expect(s.recovery, 1);
          expect(s.canRequestRetry, isFalse);
          await repository.retryReviewCreationSync(s);
          expect(sync.calls, 0);
        },
      );
    }
    test(
      'retry revalidates current FIFO and card context, so a stale tap cannot send an orphan',
      () async {
        await subject();
        await card();
        final id = await intent(attempts: 1, code: 'SYNC_TIMEOUT'),
            p = await watch();
        final s = await p.until((s) => s.isCurrent && s.canRequestRetry);
        final original = await db.getSyncItemById(id);
        // Remove only the synthetic local card before the watch notification is consumed.
        await (db.delete(
          db.flashcards,
        )..where((t) => t.id.equals('card-1'))).go();
        await repository.retryReviewCreationSync(s);
        expect(sync.calls, 0);
        expect(await db.getSyncItemById(id), original);
        final orphan = await p.until(
          (s) => s.isCurrent && s.pendingWithoutCard == 1,
        );
        expect(s.isCurrent, isFalse);
        expect(orphan.canRequestRetry, isFalse);
        expect(await db.select(db.flashcards).get(), isEmpty);
      },
    );
    test(
      'current v1 head retries only through Manager and never reports delivery or changes rows itself',
      () async {
        await subject();
        await card();
        await stats(queue: 1);
        await intent(attempts: 2, code: 'SYNC_TIMEOUT');
        final rows = await db.select(db.syncQueueTable).get(),
            p = await watch();
        final s = await p.until((s) => s.isCurrent && s.canRequestRetry);
        sync.drains = false;
        await repository.retryReviewCreationSync(s);
        expect(sync.calls, 1);
        expect(await db.select(db.syncQueueTable).get(), rows);
        expect((await db.select(db.studyStats).getSingle()).reviewQueue, 1);
        expect(fire.info.document.calls, 0);
        expect(fire.cards.calls, 0);
      },
    );
    test(
      'SQL read failure retains observed incidents but withdraws FIFO proof and retry',
      () async {
        await intent(collection: 'study_info', id: 'main', operation: 'update');
        await intent(id: 'orphan');
        final rows = await db.select(db.syncQueueTable).get(),
            p = await watch();
        final s = await p.until(
          (s) =>
              s.isCurrent && s.studyInfoHold == 1 && s.pendingWithoutCard == 1,
        );
        expect(s.waitingBehindHead, 1);
        rawDb.execute('ALTER TABLE sync_queue_table RENAME TO saved_queue');
        db.markTablesUpdated({db.syncQueueTable});
        final failed = await p.until((s) => s.isCurrent && !s.queueVerified);
        expect(failed.hasNotice, isTrue);
        expect(failed.studyInfoHold, 1);
        expect(failed.pendingWithoutCard, 1);
        expect(failed.headBlocked, isFalse);
        expect(failed.waitingBehindHead, 0);
        expect(failed.canRequestRetry, isFalse);
        expect(s.isCurrent, isFalse);
        rawDb.execute('ALTER TABLE saved_queue RENAME TO sync_queue_table');
        db.markTablesUpdated({db.syncQueueTable});
        await p.until((s) => s.isCurrent && s.queueVerified);
        expect(await db.select(db.syncQueueTable).get(), rows);
        expect(sync.calls, 0);
      },
    );
    test(
      'A-B-A, late A rows, logout and disposal preserve each session projection',
      () async {
        final aId = await intent(id: 'orphan-a');
        await intent(
          uid: 'user-b',
          collection: 'study_info',
          id: 'main',
          operation: 'update',
        );
        final p = await watch(),
            a = await p.until((s) => s.isCurrent && s.pendingWithoutCard == 1);
        auth.emitSession('user-b');
        final b = await p.until((s) => s.isCurrent && s.studyInfoHold == 1);
        expect(a.isCurrent, isFalse);
        expect(b.pendingWithoutCard, 0);
        await db.markSyncItemRejected(
          aId,
          'user-a',
          'REVIEW_CREATE_LEGACY_UNVERIFIED',
        );
        final bAfter = await p.until(
          (s) => s.isCurrent && s.studyInfoHold == 1,
        );
        expect(bAfter.pendingWithoutCard, 0);
        auth.emitSession('user-a');
        final returned = await p.until(
          (s) => s.isCurrent && s.rejectedWithoutCard == 1,
        );
        expect(returned.hasNotice, isFalse);
        expect(returned.studyInfoHold, 0);
        expect(bAfter.isCurrent, isFalse);
        await repository.retryReviewCreationSync(a);
        expect(sync.calls, 0);
        auth.emitSession(null);
        await p.until((s) => !s.isCurrent && !s.hasNotice);
        await p.cancel();
        expect(auth.visibilityListeners, 0);
        expect(returned.isCurrent, isFalse);
      },
    );
  });
  group('F01 Study verification visibility and protected pull', () {
    Future<int> intent({
      bool deleting = false,
      String uid = 'user-a',
      String status = SyncQueuePersistenceStatus.pending,
      String? code,
      String? payload,
    }) => db
        .into(db.syncQueueTable)
        .insert(
          SyncQueueTableCompanion.insert(
            ownerUid: Value(uid),
            collection: deleting ? 'subjects' : 'review_queue',
            docId: deleting ? 'subject-1' : 'card-1',
            operationType: deleting ? 'delete' : 'update',
            payloadJson:
                payload ??
                (deleting
                    ? '{}'
                    : jsonEncode({
                        'subjectId': 'subject-1',
                        'lastReviewed': '2026-10-29T12:00:00.000Z',
                        'timeZoneOffsetMinutes': -180,
                      })),
            createdAt: 1,
            status: Value(status),
            lastErrorCode: Value(code),
            attemptCount: const Value(1),
          ),
        );
    Future<_VisibilityProbe> watch() async {
      final probe = _VisibilityProbe(repository.watchReviewCreationSync());
      addTearDown(probe.cancel);
      return probe;
    }

    test(
      'F01 SQL failure retains known verification incidents without FIFO proof',
      () async {
        await intent(code: 'STUDY_REVIEW_STATE_INVALID');
        await intent(
          deleting: true,
          status: SyncQueuePersistenceStatus.rejected,
          code: 'INVALID_PAYLOAD',
        );
        final rows = await db.select(db.syncQueueTable).get(),
            probe = await watch();
        final original = await probe.until(
          (s) => s.isCurrent && s.studyVerification == 2,
        );
        rawDb.execute('ALTER TABLE sync_queue_table RENAME TO saved_f01_queue');
        try {
          db.markTablesUpdated({db.syncQueueTable});
          final failed = await probe.until(
            (s) => s.isCurrent && !s.queueVerified,
          );
          expect(failed.studyStateHold, 1);
          expect(failed.studyStateRejected, 1);
          expect(failed.hasNotice, isTrue);
          expect(failed.needsVerification, isTrue);
          expect(failed.headBlocked, isFalse);
          expect(failed.waitingBehindHead, 0);
          expect(failed.canRequestRetry, isFalse);
          expect(original.isCurrent, isFalse);
        } finally {
          rawDb.execute(
            'ALTER TABLE saved_f01_queue RENAME TO sync_queue_table',
          );
          db.markTablesUpdated({db.syncQueueTable});
        }
        await probe.until((s) => s.isCurrent && s.queueVerified);
        expect(await db.select(db.syncQueueTable).get(), rows);
        expect(sync.calls, 0);
      },
    );
    for (final deleting in [false, true]) {
      final code = deleting
          ? 'STUDY_REVIEW_QUEUE_STATE_INVALID'
          : 'STUDY_REVIEW_STATE_INVALID';
      test(
        'F01 actual transport and Manager stop $code before any Study GET',
        () async {
          await subject(cards: 7);
          await stats(queue: 7);
          await card();
          final id = await intent(deleting: deleting),
              before = await db.getSyncItemById(id);
          var sends = 0;
          final remote = FirestoreSyncRemoteDataSource(
            fire,
            auth,
            captureRemoteSend: (_) => RemoteSendPermit(() => true),
            clientFactory: () => MockClient((_) async {
              sends++;
              return http.Response(jsonEncode({'code': code}), 409);
            }),
            idTokenProvider: (_, _) async => 'synthetic-token',
            appCheckTokenProvider: () async => 'synthetic-app-check',
          );
          final manager = SyncManager(
            queueStore: AppDatabaseSyncQueueStore(db),
            remoteDataSource: remote,
            currentUserId: () => 'user-a',
          );
          addTearDown(manager.dispose);
          final actual = StudyRepository(db, fire, auth, manager);
          await actual.syncStudyFromFirebaseToLocal();
          final held = await db.getSyncItemById(id);
          expect(held.lastErrorCode, code);
          expect(held.status, SyncQueuePersistenceStatus.pending);
          expect(held.attemptCount, before.attemptCount + 1);
          expect(held.payloadJson, before.payloadJson);
          await actual.syncStudyFromFirebaseToLocal();
          expect(await db.getSyncItemById(id), held);
          expect(sends, 1);
          expect(fire.info.document.calls, 0);
          expect(fire.subjects.calls, 0);
          expect(fire.cards.calls, 0);
          expect((await db.select(db.studyStats).getSingle()).reviewQueue, 7);
        },
      );
      for (final rejected in [false, true]) {
        for (final earlier in [false, true]) {
          test(
            '$code rejected=$rejected earlier=$earlier is visible without inventing FIFO or card counts',
            () async {
              Future<void> task() async {
                await db
                    .into(db.syncQueueTable)
                    .insert(
                      SyncQueueTableCompanion.insert(
                        collection: 'tasks',
                        docId: 'task',
                        operationType: 'update',
                        payloadJson: '{}',
                        ownerUid: const Value('user-a'),
                        createdAt: 1,
                      ),
                    );
              }

              if (earlier) await task();
              await intent(
                deleting: deleting,
                status: rejected
                    ? SyncQueuePersistenceStatus.rejected
                    : SyncQueuePersistenceStatus.pending,
                code: rejected ? 'INVALID_PAYLOAD' : code,
                payload: ' private malformed payload ',
              );
              if (!earlier) await task();
              await intent(uid: 'user-b', deleting: deleting, code: code);
              final before = await db.select(db.syncQueueTable).get(),
                  probe = await watch();
              final state = await probe.until(
                (s) => s.isCurrent && s.studyVerification == 1,
              );
              expect(state.studyStateHold, rejected ? 0 : 1);
              expect(state.studyStateRejected, rejected ? 1 : 0);
              expect(state.hasNotice, isTrue);
              expect(state.needsVerification, isTrue);
              expect(state.affected, 0);
              expect(state.pendingWithoutCard, 0);
              expect(state.headBlocked, !rejected && !earlier);
              expect(state.waitingBehindHead, !rejected && !earlier ? 1 : 0);
              expect(state.canRequestRetry, isFalse);
              await repository.retryReviewCreationSync(state);
              expect(sync.calls, 0);
              expect(await db.select(db.syncQueueTable).get(), before);
            },
          );
        }
        for (final local in [false, true]) {
          for (final remotePresent in [false, true]) {
            test(
              '$code rejected=$rejected local=$local remote=$remotePresent protects unresolved data and deletion intent',
              () async {
                await stats(queue: 7, progress: .8, streak: 6);
                if (local) {
                  await subject(cards: 7);
                  await card(lastReviewed: DateTime.utc(2026, 10, 29));
                }
                await intent(
                  deleting: deleting,
                  status: rejected
                      ? SyncQueuePersistenceStatus.rejected
                      : SyncQueuePersistenceStatus.pending,
                  code: rejected ? 'INVALID_PAYLOAD' : code,
                );
                final rows = await db.select(db.syncQueueTable).get();
                final beforeStats = await db.select(db.studyStats).getSingle();
                final beforeSubjects = await db.select(db.subjects).get();
                final beforeCards = await db.select(db.flashcards).get();
                fire.info.document.values = {
                  'reviewQueue': 0,
                  'progress': .1,
                  'streak': 0,
                };
                fire.subjects.documents = [
                  if (remotePresent)
                    _QueryDoc('subject-1', remoteSubject('Stale')),
                  _QueryDoc('unrelated', remoteSubject('Unrelated')),
                ];
                fire.cards.documents = [
                  if (remotePresent)
                    _QueryDoc('card-1', {
                      'subjectId': 'subject-1',
                      'question': 'Stale Q',
                      'answer': 'Stale A',
                      'lastReviewed': Timestamp.fromDate(
                        DateTime.utc(2026, 10, 1),
                      ),
                    }),
                  _QueryDoc('unrelated-card', {
                    'subjectId': 'unrelated',
                    'question': 'Q',
                    'answer': 'A',
                    'lastReviewed': null,
                  }),
                ];
                await repository.syncStudyFromFirebaseToLocal();
                expect(await db.select(db.studyStats).getSingle(), beforeStats);
                final affectedSubjects = await (db.select(
                  db.subjects,
                )..where((s) => s.id.equals('subject-1'))).get();
                final affectedCards = await (db.select(
                  db.flashcards,
                )..where((c) => c.id.equals('card-1'))).get();
                expect(affectedSubjects, beforeSubjects);
                expect(affectedCards, beforeCards);
                expect(await db.select(db.syncQueueTable).get(), rows);
                expect(
                  (await (db.select(
                    db.flashcards,
                  )..where((c) => c.id.equals('unrelated-card'))).get()),
                  hasLength(1),
                );
              },
            );
          }
        }
      }
    }
    test(
      'F01 observer invalidates HOLD across A-B-A and logout without requeue or sends',
      () async {
        await intent(code: 'STUDY_REVIEW_STATE_INVALID');
        await intent(
          uid: 'user-b',
          deleting: true,
          status: SyncQueuePersistenceStatus.rejected,
          code: 'INVALID_PAYLOAD',
        );
        final rows = await db.select(db.syncQueueTable).get(),
            probe = await watch();
        final a = await probe.until(
          (s) => s.isCurrent && s.studyStateHold == 1,
        );
        auth.emitSession('user-b');
        final b = await probe.until(
          (s) => s.isCurrent && s.studyStateRejected == 1,
        );
        expect(a.isCurrent, isFalse);
        expect(b.studyStateHold, 0);
        auth.emitSession('user-a');
        final back = await probe.until(
          (s) => s.isCurrent && s.studyStateHold == 1,
        );
        expect(b.isCurrent, isFalse);
        expect(identical(back.sessionToken, a.sessionToken), isFalse);
        await repository.retryReviewCreationSync(a);
        await repository.retryReviewCreationSync(back);
        expect(sync.calls, 0);
        auth.emitSession(null);
        await probe.until((s) => !s.isCurrent && !s.hasNotice);
        expect(back.isCurrent, isFalse);
        expect(await db.select(db.syncQueueTable).get(), rows);
      },
    );
    test(
      'F01 rejected review with unreadable payload still protects local parent from cascade',
      () async {
        await stats(queue: 7);
        await subject(cards: 7);
        await card();
        await intent(
          status: SyncQueuePersistenceStatus.rejected,
          code: 'INVALID_PAYLOAD',
          payload: 'not-json',
        );
        final old = await db.select(db.flashcards).getSingle();
        fire.info.document.values = {'reviewQueue': 0};
        await repository.syncStudyFromFirebaseToLocal();
        expect(await db.select(db.flashcards).getSingle(), old);
        expect((await db.select(db.subjects).getSingle()).id, 'subject-1');
        expect((await db.select(db.studyStats).getSingle()).reviewQueue, 7);
      },
    );
  });
}
