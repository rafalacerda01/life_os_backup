import 'dart:async';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/database_provider.dart';
import 'package:life_os/core/database/database_sync_policy.dart';
import 'package:life_os/core/database/local_database_identity.dart';
import 'package:life_os/core/database/local_mutation_gate.dart';
import 'package:life_os/core/services/firebase_auth_provider.dart';
import 'package:life_os/core/services/sync_manager_provider.dart';
import 'package:life_os/features/study/data/study_repository.dart';
import 'package:life_os/features/study/data/models/study_model.dart';
import 'package:life_os/features/study/presentation/providers/study_provider.dart';
import 'package:life_os/features/premium/domain/services/quota_service.dart';

void main() {
  const uid = 'local-v1-123e4567-e89b-42d3-a456-426614174000';
  late AppDatabase db;
  late StudyRepository repository;
  late DateTime clock;
  setUp(() {
    clock = DateTime(2026, 11, 18, 12);
    db = AppDatabase.forUser(
      identity: LocalDatabaseIdentity(uid),
      executor: NativeDatabase.memory(),
      syncPolicy: DatabaseSyncPolicy.localOnly,
    );
    repository = StudyRepository.local(db, reviewNow: () => clock);
  });
  tearDown(() => db.close());
  Future<String> subject(String title) async {
    await repository.createSubject(title);
    return (await db.select(db.subjects).get())
        .firstWhere((r) => r.title == title)
        .id;
  }

  Future<String> card(String id, String question) async {
    await repository.addFlashcard(id, question, 'Resposta local');
    return (await db.select(db.flashcards).get())
        .firstWhere((r) => r.question == question)
        .id;
  }

  StudyModel stale() => StudyModel(
    streak: 999,
    reviewQueue: 999,
    progress: .9,
    lastStudyDate: DateTime(2000),
  );

  test(
    'subject/card CRUD and review projections work without Firebase or new sync rows',
    () async {
      final id = await subject('Estudo local');
      final stream = StreamIterator(repository.getFlashcardsStream());
      try {
        expect(await stream.moveNext(), true);
        expect(stream.current, isEmpty);
        final flashcard = await card(id, 'Pergunta');
        expect(await stream.moveNext(), true);
        expect(stream.current.single.id, flashcard);
        expect((await repository.getStudyStatsStream().first).reviewQueue, 1);
        expect(
          (await repository.getSubjectsStream().first).single.cardsToReview,
          1,
        );
        await repository.completeCard(flashcard);
        expect(await stream.moveNext(), true);
        expect(stream.current, isEmpty);
        final before = (await db.select(db.studyStats).get()).single;
        await repository.completeCard(flashcard);
        expect((await db.select(db.studyStats).get()).single, before);
        expect(await db.select(db.flashcards).get(), hasLength(1));
        await repository.removeSubject(id);
        expect(await db.select(db.subjects).get(), isEmpty);
        expect(await db.select(db.flashcards).get(), isEmpty);
        expect(await db.select(db.syncQueueTable).get(), isEmpty);
      } finally {
        await stream.cancel();
      }
    },
  );
  test(
    'provider, review notice and explicit retry never touch remote SDK or manager',
    () async {
      var reads = 0;
      Never remote() {
        reads++;
        throw StateError('REMOTE_MUST_NOT_BE_READ');
      }

      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          firebaseAuthProvider.overrideWith((ref) => remote()),
          firebaseFirestoreProvider.overrideWith((ref) => remote()),
          syncManagerProvider.overrideWith((ref) => remote()),
        ],
      );
      try {
        final local = container.read(studyRepositoryProvider);
        await local.createSubject('provider');
        expect((await local.watchReviewCreationSync().first).hasNotice, false);
        final observed = ReviewCreationSyncState(
          () => true,
          indeterminate: 1,
          retryEligible: true,
          sessionToken: Object(),
          retryOperationId: 1,
        );
        expect(observed.canRequestRetry, true);
        await local.retryReviewCreationSync(observed);
        await local.syncStudyFromFirebaseToLocal();
        expect(reads, 0);
        expect(await db.select(db.syncQueueTable).get(), isEmpty);
      } finally {
        container.dispose();
      }
    },
  );
  test(
    'local pulls preserve records and stale UI snapshots cannot replace stored study counters',
    () async {
      final id = await subject('preserved');
      await card(id, 'one');
      await card(id, 'two');
      await repository.logStudySession(stale());
      final stats = (await db.select(db.studyStats).get()).single;
      expect(stats.reviewQueue, 2);
      expect(stats.streak, 1);
      expect(stats.progress, closeTo(.1, .00001));
      final before = await db.select(db.subjects).get();
      await repository.syncStudyFromFirebaseToLocal();
      expect(await db.select(db.subjects).get(), before);
      await repository.resetDailyProgress(stale());
      final reset = (await db.select(db.studyStats).get()).single;
      expect(reset.progress, 0);
      expect(reset.reviewQueue, 2);
      expect(reset.streak, 1);
      expect(await db.select(db.syncQueueTable).get(), isEmpty);
    },
  );
  test(
    'Free subjects quota is atomic and deletion releases one slot',
    () async {
      final results = await Future.wait(
        List.generate(8, (i) async {
          try {
            await repository.createSubject('concurrent-$i');
            return true;
          } on PlanQuotaExceeded {
            return false;
          }
        }),
      );
      expect(results.where((e) => e), hasLength(3));
      final rows = await db.select(db.subjects).get();
      expect(rows, hasLength(3));
      await repository.removeSubject(rows.first.id);
      await repository.createSubject('replacement');
      expect(await db.select(db.subjects).get(), hasLength(3));
      expect(await db.select(db.syncQueueTable).get(), isEmpty);
    },
  );
  test('concurrent reviews commit once per card per civil day', () async {
    final id = await subject('review');
    final flashcard = await card(id, 'question');
    await Future.wait(
      List.generate(8, (_) => repository.completeCard(flashcard)),
    );
    final row = (await db.select(db.studyStats).get()).single;
    expect(row.progress, closeTo(.05, .000001));
    expect(row.reviewQueue, 0);
    expect(row.streak, 1);
  });
  test(
    'day rollover counters include yesterday reviewed cards before a new creation',
    () async {
      final id = await subject('rollover');
      final first = await card(id, 'old');
      await repository.completeCard(first);
      clock = clock.add(const Duration(days: 1));
      await card(id, 'new');
      expect((await repository.getStudyStatsStream().first).reviewQueue, 2);
      expect((await db.select(db.studyStats).get()).single.reviewQueue, 2);
      expect((await db.select(db.subjects).get()).single.cardsToReview, 2);
      await repository.completeCard(first);
      expect((await db.select(db.studyStats).get()).single.reviewQueue, 1);
    },
  );
  test(
    'removing a subject subtracts its due cards and preserves another subject due count',
    () async {
      final a = await subject('a');
      final b = await subject('b');
      final reviewed = await card(a, 'a-reviewed');
      await card(a, 'a-due');
      await card(b, 'b-due');
      await repository.completeCard(reviewed);
      await repository.removeSubject(a);
      expect((await repository.getStudyStatsStream().first).reviewQueue, 1);
      expect((await db.select(db.studyStats).get()).single.reviewQueue, 1);
      expect((await db.select(db.flashcards).get()).single.subjectId, b);
    },
  );
  test(
    'invalid input or missing focus target cannot invent study progress',
    () async {
      await expectLater(repository.createSubject(' '), throwsArgumentError);
      await expectLater(
        repository.createSubject('exam', hasExam: true),
        throwsArgumentError,
      );
      final id = await subject('valid');
      await expectLater(
        repository.addFlashcard(id, ' ', 'answer'),
        throwsArgumentError,
      );
      for (final duration in [0, -1]) {
        await expectLater(
          repository.addStudyTime(id, duration),
          throwsArgumentError,
        );
      }
      await expectLater(
        repository.addStudyTime('missing', 60),
        throwsArgumentError,
      );
      expect(await db.select(db.studyStats).get(), isEmpty);
      await repository.addStudyTime(id, 60);
      expect(
        (await db.select(db.studyStats).get()).single.progress,
        closeTo(.05, .000001),
      );
      expect(await db.select(db.syncQueueTable).get(), isEmpty);
    },
  );
  test('detached session refuses local writes, resets and reads', () async {
    String? current = uid;
    db.localMutations.bindSessionReader(() => current);
    db.localMutations.openPreparedSession();
    final id = await subject('preserved');
    final first = await card(id, 'preserved-card');
    final before = await db.select(db.flashcards).get();
    current = null;
    db.localMutations.observeSession(null);
    for (final action in <Future<void> Function()>[
      () => repository.createSubject('late'),
      () => repository.addFlashcard(id, 'late', 'late'),
      () => repository.completeCard(first),
      () => repository.removeSubject(id),
      () => repository.logStudySession(stale()),
      () => repository.addStudyTime(id, 60),
      () => repository.resetDailyProgress(stale()),
    ]) {
      await expectLater(action(), throwsA(isA<LocalMutationUnavailable>()));
    }
    await expectLater(
      repository.getSubjectsStream().first,
      throwsA(isA<LocalMutationUnavailable>()),
    );
    current = uid;
    db.localMutations.openPreparedSession();
    expect(await db.select(db.flashcards).get(), before);
  });
  test('local constructor refuses remote-enabled storage', () async {
    final remote = AppDatabase(executor: NativeDatabase.memory());
    try {
      expect(() => StudyRepository.local(remote), throwsArgumentError);
    } finally {
      await remote.close();
    }
  });
}
