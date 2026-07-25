import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:drift/drift.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/database_provider.dart';
import 'package:life_os/features/study/data/models/study_model.dart';
import 'package:life_os/features/study/data/models/flashcard_model.dart';
import 'package:life_os/features/study/domain/entities/study_subject_entity.dart';
import 'package:life_os/core/security/input_sanitizer.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter/foundation.dart';

final studyRepositoryProvider = Provider(
  (ref) => StudyRepository(
    ref.watch(databaseProvider),
    FirebaseFirestore.instance,
    FirebaseAuth.instance,
  ),
);

// --- PROVIDERS ---

final studyStreamProvider = StreamProvider<StudyModel>((ref) {
  return ref.watch(studyRepositoryProvider).getStudyStatsStream();
});

final subjectsStreamProvider =
    StreamProvider.autoDispose<List<StudySubjectEntity>>((ref) {
      return ref.watch(studyRepositoryProvider).getSubjectsStream();
    });

final flashcardStreamProvider = StreamProvider<List<FlashcardModel>>((ref) {
  return ref.watch(studyRepositoryProvider).getFlashcardsStream();
});

// --- REPOSITÓRIO ---

class StudyRepository {
  final AppDatabase _db;
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;
  final _uuid = const Uuid();

  StudyRepository(this._db, this._firestore, this._auth);

  Future<void> syncStudyFromFirebaseToLocal() async {
    final user = _auth.currentUser;
    if (user == null) return;

    try {
      // 1. Sincronizar Info Principal
      final mainDoc = await _firestore
          .collection('users')
          .doc(user.uid)
          .collection('study_info')
          .doc('main')
          .get();
      if (mainDoc.exists) {
        final data = mainDoc.data()!;
        final rawQueue = data['reviewQueue'] ?? 0;
        final safeQueue = rawQueue < 0 ? 0 : rawQueue;

        await _db
            .into(_db.studyStats)
            .insertOnConflictUpdate(
              StudyStatsCompanion(
                id: const Value('main'),
                streak: Value(data['streak'] ?? 0),
                reviewQueue: Value(safeQueue),
                progress: Value((data['progress'] ?? 0.0).toDouble()),
                lastStudyDate: Value(
                  (data['lastStudyDate'] as Timestamp?)?.millisecondsSinceEpoch,
                ),
              ),
            );
      }

      // 2. Sincronizar Disciplinas (Subjects)
      final subjectsSnapshot = await _firestore
          .collection('users')
          .doc(user.uid)
          .collection('subjects')
          .get();
      for (var doc in subjectsSnapshot.docs) {
        final data = doc.data();
        await _db
            .into(_db.subjects)
            .insertOnConflictUpdate(
              SubjectsCompanion(
                id: Value(doc.id),
                title: Value(data['title'] ?? ''),
                cardsToReview: Value(data['cardsToReview'] ?? 0),
                streakDays: Value(data['streakDays'] ?? 0),
                progress: Value((data['progress'] ?? 0.0).toDouble()),
                hasExam: Value(data['hasExam'] ?? false),
                examDate: Value(
                  (data['examDate'] as Timestamp?)?.millisecondsSinceEpoch,
                ),
              ),
            );
      }

      // 3. Sincronizar Flashcards (Review Queue)
      final flashcardsSnapshot = await _firestore
          .collection('users')
          .doc(user.uid)
          .collection('review_queue')
          .get();

      for (var doc in flashcardsSnapshot.docs) {
        final data = doc.data();
        await _db
            .into(_db.flashcards)
            .insertOnConflictUpdate(
              FlashcardsCompanion(
                id: Value(doc.id),
                subjectId: Value(data['subjectId'] ?? ''),
                question: Value(data['question'] ?? ''),
                answer: Value(data['answer'] ?? ''),
                lastReviewed: Value(
                  (data['lastReviewed'] as Timestamp?)?.millisecondsSinceEpoch,
                ),
              ),
            );
      }
    } catch (e) {
      debugPrint("Erro ao sincronizar Área de Estudos: $e");
    }
  }

  // 1. STREAM GETTERS (Lendo do local)
  Stream<StudyModel> getStudyStatsStream() {
    return _db.select(_db.studyStats).watchSingleOrNull().map((row) {
      if (row == null) return StudyModel.initial();
      return StudyModel(
        streak: row.streak,
        reviewQueue: row.reviewQueue < 0 ? 0 : row.reviewQueue,
        progress: row.progress,
        lastStudyDate: row.lastStudyDate != null
            ? DateTime.fromMillisecondsSinceEpoch(row.lastStudyDate!)
            : null,
      );
    });
  }

  Stream<List<StudySubjectEntity>> getSubjectsStream() {
    return _db
        .select(_db.subjects)
        .watch()
        .map(
          (rows) => rows
              .map(
                (r) => StudySubjectEntity(
                  id: r.id,
                  title: r.title,
                  cardsToReview: r.cardsToReview,
                  streakDays: r.streakDays,
                  progress: r.progress,
                  hasExam: r.hasExam,
                  examDate: r.examDate != null
                      ? DateTime.fromMillisecondsSinceEpoch(r.examDate!)
                      : null,
                ),
              )
              .toList(),
        );
  }

  Stream<List<FlashcardModel>> getFlashcardsStream() {
    final now = DateTime.now();
    final startOfToday = DateTime(
      now.year,
      now.month,
      now.day,
    ).millisecondsSinceEpoch;

    return (_db.select(_db.flashcards)..where(
          (t) =>
              t.lastReviewed.isNull() |
              t.lastReviewed.isSmallerThanValue(startOfToday),
        ))
        .watch()
        .map(
          (rows) => rows
              .map(
                (r) => FlashcardModel(
                  id: r.id,
                  question: r.question,
                  answer: r.answer,
                ),
              )
              .toList(),
        );
  }

  // Criação de Disciplina (Subjects)
  Future<void> createSubject(
    String title, {
    bool hasExam = false,
    DateTime? examDate,
  }) async {
    final user = _auth.currentUser;
    if (user == null) return;
    final id = _uuid.v4();
    final cleanTitle = InputSanitizer.sanitize(title);

    await _db
        .into(_db.subjects)
        .insert(
          SubjectsCompanion.insert(
            id: id,
            title: cleanTitle,
            cardsToReview: 0,
            streakDays: 0,
            progress: 0.0,
            hasExam: hasExam,
            examDate: Value(examDate?.millisecondsSinceEpoch),
          ),
        );

    await _firestore
        .collection('users')
        .doc(user.uid)
        .collection('subjects')
        .doc(id)
        .set({
          'title': cleanTitle,
          'hasExam': hasExam,
          'examDate': examDate != null ? Timestamp.fromDate(examDate) : null,
          'createdAt': FieldValue.serverTimestamp(),
        });
  }

  // Atualiza o card marcando que ele foi revisado hoje (Sem exclusão física)
  // Atualiza o card marcando que ele foi revisado hoje e avança o progresso automaticamente
  Future<void> completeCard(String cardId) async {
    final user = _auth.currentUser;
    if (user == null) return;

    final nowEpoch = DateTime.now().millisecondsSinceEpoch;

    // 1. Busca os dados do flashcard antes de atualizar para saber a qual matéria ele pertence
    final cardData = await (_db.select(
      _db.flashcards,
    )..where((t) => t.id.equals(cardId))).getSingleOrNull();

    if (cardData == null) return;
    final subjectId = cardData.subjectId;

    // 2. Atualiza o card localmente com a data da última revisão
    final cardQuery = _db.update(_db.flashcards)
      ..where((t) => t.id.equals(cardId));
    await cardQuery.write(FlashcardsCompanion(lastReviewed: Value(nowEpoch)));

    // 3. Calcula a nova fila geral com segurança matemática
    final currentStats = await _db.select(_db.studyStats).getSingleOrNull();
    final currentQueue = currentStats?.reviewQueue ?? 0;
    final newQueue = (currentQueue > 0)
        ? (currentQueue - 1).clamp(0, 99999)
        : 0;

    // Incrementa sutilmente o progresso do dia de forma automática (ex: +5% ou proporcional por card concluído)
    final currentProgress = currentStats?.progress ?? 0.0;
    final newProgress = (currentProgress + 0.05).clamp(0.0, 1.0);

    // 4. Atualiza as estatísticas gerais de estudo local (incluindo o progresso automático)
    final statsQuery = _db.update(_db.studyStats)
      ..where((t) => t.id.equals('main'));
    await statsQuery.write(
      StudyStatsCompanion(
        reviewQueue: Value(newQueue),
        progress: Value(newProgress),
        lastStudyDate: Value(nowEpoch),
      ),
    );

    // 5. Atualiza os dados da disciplina específica localmente (cardsToReview e progresso da matéria)
    final subjectData = await (_db.select(
      _db.subjects,
    )..where((t) => t.id.equals(subjectId))).getSingleOrNull();

    if (subjectData != null) {
      final currentCardsToReview = subjectData.cardsToReview;
      final newCardsToReview = (currentCardsToReview > 0)
          ? currentCardsToReview - 1
          : 0;

      // Exemplo de cálculo de progresso da disciplina
      // Se preferir calcular baseado no total de cards vs revisados, pode ajustar aqui
      final subQuery = _db.update(_db.subjects)
        ..where((t) => t.id.equals(subjectId));
      await subQuery.write(
        SubjectsCompanion(cardsToReview: Value(newCardsToReview)),
      );
    }

    // 6. Sincroniza tudo no Firestore em lote seguro (Batch)
    final batch = _firestore.batch();

    final cardRef = _firestore
        .collection('users')
        .doc(user.uid)
        .collection('review_queue')
        .doc(cardId);
    batch.update(cardRef, {
      'lastReviewed': Timestamp.fromMillisecondsSinceEpoch(nowEpoch),
    });

    final mainDocRef = _firestore
        .collection('users')
        .doc(user.uid)
        .collection('study_info')
        .doc('main');
    batch.update(mainDocRef, {
      'reviewQueue': newQueue,
      'progress': newProgress,
      'lastStudyDate': Timestamp.fromMillisecondsSinceEpoch(nowEpoch),
    });

    if (subjectData != null) {
      final subjectRef = _firestore
          .collection('users')
          .doc(user.uid)
          .collection('subjects')
          .doc(subjectId);

      final currentSubReview = subjectData.cardsToReview > 0
          ? subjectData.cardsToReview - 1
          : 0;
      batch.update(subjectRef, {'cardsToReview': currentSubReview});
    }

    await batch.commit();
  }

  Future<void> removeSubject(String id) async {
    final user = _auth.currentUser;
    if (user == null) return;

    // 1. Coleta os flashcards vinculados no Firestore antes de deletar a matéria
    final flashcardsQuery = await _firestore
        .collection('users')
        .doc(user.uid)
        .collection('review_queue')
        .where('subjectId', isEqualTo: id)
        .get();

    // 2. Prepara o batch do Firestore para apagar em cascata os flashcards e a matéria
    final batch = _firestore.batch();
    for (var doc in flashcardsQuery.docs) {
      batch.delete(doc.reference);
    }

    final subjectDocRef = _firestore
        .collection('users')
        .doc(user.uid)
        .collection('subjects')
        .doc(id);
    batch.delete(subjectDocRef);

    // Ajusta a fila de revisão local e no Firestore baseando-se na quantidade de cards removidos
    final removedCardsCount = flashcardsQuery.docs.length;
    final currentStats = await _db.select(_db.studyStats).getSingleOrNull();
    final currentQueue = currentStats?.reviewQueue ?? 0;
    final newQueue = (currentQueue - removedCardsCount).clamp(0, 99999);

    final statsQuery = _db.update(_db.studyStats)
      ..where((t) => t.id.equals('main'));
    await statsQuery.write(StudyStatsCompanion(reviewQueue: Value(newQueue)));

    final mainDocRef = _firestore
        .collection('users')
        .doc(user.uid)
        .collection('study_info')
        .doc('main');
    batch.update(mainDocRef, {'reviewQueue': newQueue});

    // Executa o batch no Firestore
    await batch.commit();

    // 3. Executa a exclusão no Drift localmente (com Cascade Delete na tabela)
    await _db.transaction(() async {
      await (_db.delete(
        _db.flashcards,
      )..where((t) => t.subjectId.equals(id))).go();
      await (_db.delete(_db.subjects)..where((t) => t.id.equals(id))).go();
    });
  }

  Future<void> logStudySession(StudyModel currentStatus) async {
    final user = _auth.currentUser;
    if (user == null) return;

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    int newStreak = currentStatus.streak;

    if (currentStatus.lastStudyDate != null) {
      final last = currentStatus.lastStudyDate!;
      final lastDate = DateTime(last.year, last.month, last.day);
      final difference = today.difference(lastDate).inDays;
      if (difference == 1)
        newStreak++;
      else if (difference > 1)
        newStreak = 1;
    } else {
      newStreak = 1;
    }

    final newProgress = (currentStatus.progress + 0.1).clamp(0.0, 1.0);

    final query = _db.update(_db.studyStats)..where((t) => t.id.equals('main'));
    await query.write(
      StudyStatsCompanion(
        streak: Value(newStreak),
        progress: Value(newProgress),
        lastStudyDate: Value(now.millisecondsSinceEpoch),
      ),
    );

    await _firestore
        .collection('users')
        .doc(user.uid)
        .collection('study_info')
        .doc('main')
        .set({
          'streak': newStreak,
          'progress': newProgress,
          'lastStudyDate': Timestamp.fromDate(now),
        }, SetOptions(merge: true));
  }

  Future<void> completeReview(StudyModel currentStatus) async {
    final user = _auth.currentUser;
    if (user == null || currentStatus.reviewQueue <= 0) return;

    final safeNewQueue = (currentStatus.reviewQueue - 1).clamp(0, 99999);

    final query = _db.update(_db.studyStats)..where((t) => t.id.equals('main'));
    await query.write(StudyStatsCompanion(reviewQueue: Value(safeNewQueue)));

    await _firestore
        .collection('users')
        .doc(user.uid)
        .collection('study_info')
        .doc('main')
        .update({'reviewQueue': safeNewQueue});
  }

  Future<void> resetDailyProgress(StudyModel currentStatus) async {
    final user = _auth.currentUser;
    if (user == null) return;

    final query = _db.update(_db.studyStats)..where((t) => t.id.equals('main'));
    await query.write(const StudyStatsCompanion(progress: Value(0.0)));

    await _firestore
        .collection('users')
        .doc(user.uid)
        .collection('study_info')
        .doc('main')
        .update({'progress': 0.0});
  }

  Future<void> addFlashcard(
    String subjectId,
    String question,
    String answer,
  ) async {
    final user = _auth.currentUser;
    if (user == null) return;

    final id = _uuid.v4();
    final cleanQuestion = InputSanitizer.sanitize(question);
    final cleanAnswer = InputSanitizer.sanitize(answer);

    await _db
        .into(_db.flashcards)
        .insert(
          FlashcardsCompanion.insert(
            id: id,
            subjectId: subjectId,
            question: cleanQuestion,
            answer: cleanAnswer,
          ),
        );

    final batch = _firestore.batch();
    final newCardRef = _firestore
        .collection('users')
        .doc(user.uid)
        .collection('review_queue')
        .doc(id);

    batch.set(newCardRef, {
      'subjectId': subjectId,
      'question': cleanQuestion,
      'answer': cleanAnswer,
      'createdAt': FieldValue.serverTimestamp(),
    });

    batch.update(
      _firestore
          .collection('users')
          .doc(user.uid)
          .collection('study_info')
          .doc('main'),
      {'reviewQueue': FieldValue.increment(1)},
    );

    batch.update(
      _firestore
          .collection('users')
          .doc(user.uid)
          .collection('subjects')
          .doc(subjectId),
      {'cardsToReview': FieldValue.increment(1)},
    );

    await batch.commit();
  }
}
