import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:drift/drift.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/utils/app_logger.dart'; // 🚀 Nosso Logger
import 'package:life_os/features/study/data/models/study_model.dart';
import 'package:life_os/features/study/data/models/flashcard_model.dart';
import 'package:life_os/features/study/domain/entities/study_subject_entity.dart';
import 'package:life_os/core/security/input_sanitizer.dart';
import 'package:uuid/uuid.dart';

class StudyRepository {
  final AppDatabase _db;
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;
  final _uuid = const Uuid();

  StudyRepository(this._db, this._firestore, this._auth);

  // ===========================================================================
  // 1. LEITURA (STREAMS LOCAIS)
  // ===========================================================================

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

  // ===========================================================================
  // 2. ESCRITA (OFFLINE-FIRST)
  // ===========================================================================

  Future<void> createSubject(
    String title, {
    bool hasExam = false,
    DateTime? examDate,
  }) async {
    if (_auth.currentUser == null) return;
    final id = _uuid.v4();
    final cleanTitle = InputSanitizer.sanitize(title);

    try {
      // 1. Local
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

      // 2. Remoto em background
      unawaited(_createSubjectInFirestore(id, cleanTitle, hasExam, examDate));
    } catch (e, stack) {
      AppLogger.e('Erro ao criar matéria localmente', e, stack);
      rethrow;
    }
  }

  Future<void> completeCard(String cardId) async {
    if (_auth.currentUser == null) return;
    final nowEpoch = DateTime.now().millisecondsSinceEpoch;

    try {
      // 1. Leituras locais necessárias
      final cardData = await (_db.select(
        _db.flashcards,
      )..where((t) => t.id.equals(cardId))).getSingleOrNull();
      if (cardData == null) return;
      final subjectId = cardData.subjectId;

      final currentStats = await _db.select(_db.studyStats).getSingleOrNull();
      final currentQueue = currentStats?.reviewQueue ?? 0;
      final newQueue = (currentQueue > 0)
          ? (currentQueue - 1).clamp(0, 99999)
          : 0;

      final currentProgress = currentStats?.progress ?? 0.0;
      final newProgress = (currentProgress + 0.05).clamp(0.0, 1.0);

      // 2. Atualizações locais (Múltiplas tabelas)
      await (_db.update(_db.flashcards)..where((t) => t.id.equals(cardId)))
          .write(FlashcardsCompanion(lastReviewed: Value(nowEpoch)));

      await (_db.update(
        _db.studyStats,
      )..where((t) => t.id.equals('main'))).write(
        StudyStatsCompanion(
          reviewQueue: Value(newQueue),
          progress: Value(newProgress),
          lastStudyDate: Value(nowEpoch),
        ),
      );

      int? newCardsToReview;
      final subjectData = await (_db.select(
        _db.subjects,
      )..where((t) => t.id.equals(subjectId))).getSingleOrNull();

      if (subjectData != null) {
        newCardsToReview = (subjectData.cardsToReview > 0)
            ? subjectData.cardsToReview - 1
            : 0;
        await (_db.update(_db.subjects)..where((t) => t.id.equals(subjectId)))
            .write(SubjectsCompanion(cardsToReview: Value(newCardsToReview)));
      }

      // 3. Firebase em background
      unawaited(
        _completeCardInFirestore(
          cardId,
          subjectId,
          newQueue,
          newProgress,
          newCardsToReview,
          nowEpoch,
        ),
      );
    } catch (e, stack) {
      AppLogger.e('Erro ao completar flashcard', e, stack);
      rethrow;
    }
  }

  Future<void> removeSubject(String id) async {
    if (_auth.currentUser == null) return;

    try {
      // 1. Consultar localmente QUANTOS cards essa matéria tem (para não depender da nuvem)
      final flashcardsQuery = await (_db.select(
        _db.flashcards,
      )..where((t) => t.subjectId.equals(id))).get();
      final removedCardsCount = flashcardsQuery.length;

      // 2. Recalcular a fila geral local
      final currentStats = await _db.select(_db.studyStats).getSingleOrNull();
      final currentQueue = currentStats?.reviewQueue ?? 0;
      final newQueue = (currentQueue - removedCardsCount).clamp(0, 99999);

      await (_db.update(_db.studyStats)..where((t) => t.id.equals('main')))
          .write(StudyStatsCompanion(reviewQueue: Value(newQueue)));

      // 3. Exclusão em lote localmente (Cascade Delete)
      await _db.transaction(() async {
        await (_db.delete(
          _db.flashcards,
        )..where((t) => t.subjectId.equals(id))).go();
        await (_db.delete(_db.subjects)..where((t) => t.id.equals(id))).go();
      });

      // 4. Background sync
      unawaited(_removeSubjectFromFirestore(id, newQueue));
    } catch (e, stack) {
      AppLogger.e('Erro ao deletar matéria', e, stack);
      rethrow;
    }
  }

  Future<void> addFlashcard(
    String subjectId,
    String question,
    String answer,
  ) async {
    if (_auth.currentUser == null) return;

    final id = _uuid.v4();
    final cleanQuestion = InputSanitizer.sanitize(question);
    final cleanAnswer = InputSanitizer.sanitize(answer);

    try {
      // 1. Local
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

      // 2. Remoto em background
      unawaited(
        _addFlashcardInFirestore(id, subjectId, cleanQuestion, cleanAnswer),
      );
    } catch (e, stack) {
      AppLogger.e('Erro ao criar flashcard', e, stack);
      rethrow;
    }
  }

  Future<void> logStudySession(StudyModel currentStatus) async {
    if (_auth.currentUser == null) return;
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

    try {
      await (_db.update(
        _db.studyStats,
      )..where((t) => t.id.equals('main'))).write(
        StudyStatsCompanion(
          streak: Value(newStreak),
          progress: Value(newProgress),
          lastStudyDate: Value(now.millisecondsSinceEpoch),
        ),
      );
      unawaited(_logStudySessionInFirestore(newStreak, newProgress, now));
    } catch (e, stack) {
      AppLogger.e('Erro ao logar sessão', e, stack);
    }
  }

  // 🚀 NOVO MÉTODO: Adiciona o tempo de estudo processado pelo Timer de Foco
  Future<void> addStudyTime(String subjectId, int elapsedSeconds) async {
    if (_auth.currentUser == null) return;

    // 🚨 CORREÇÃO 1: Se o timer chegou a zero, assumimos o tempo padrão de 1 pomodoro (25 min = 1500s).
    final safeElapsed = elapsedSeconds <= 0 ? 1500 : elapsedSeconds;

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final nowEpoch = now.millisecondsSinceEpoch;

    try {
      final currentStats = await _db.select(_db.studyStats).getSingleOrNull();
      int newStreak = currentStats?.streak ?? 0;
      final lastStudyMillis = currentStats?.lastStudyDate;

      // Cálculo de Streak
      if (lastStudyMillis != null) {
        final last = DateTime.fromMillisecondsSinceEpoch(lastStudyMillis);
        final lastDate = DateTime(last.year, last.month, last.day);
        final difference = today.difference(lastDate).inDays;
        if (difference == 1) {
          newStreak++;
        } else if (difference > 1) {
          newStreak = 1;
        }
      } else {
        newStreak = 1;
      }

      final currentProgress = currentStats?.progress ?? 0.0;

      // 🚨 CORREÇÃO 2: Cálculo Proporcional com Bônus Mínimo de Teste
      double sessionProgressBonus = (safeElapsed / 1500) * 0.25;

      // Se você está testando com tempos de 10s, garante um ganho visível de 5% na barra!
      if (sessionProgressBonus < 0.05) {
        sessionProgressBonus = 0.05;
      }

      final newProgress = (currentProgress + sessionProgressBonus).clamp(
        0.0,
        1.0,
      );

      // 🚨 CORREÇÃO 3: Usar insertOnConflictUpdate garante que a estatística seja criada se não existir!
      await _db
          .into(_db.studyStats)
          .insertOnConflictUpdate(
            StudyStatsCompanion(
              id: const Value('main'),
              streak: Value(newStreak),
              progress: Value(newProgress),
              reviewQueue: Value(currentStats?.reviewQueue ?? 0),
              lastStudyDate: Value(nowEpoch),
            ),
          );

      // Atualiza o progresso específico da Disciplina selecionada
      final subjectData = await (_db.select(
        _db.subjects,
      )..where((t) => t.id.equals(subjectId))).getSingleOrNull();
      double subProgress = 0.0;

      if (subjectData != null) {
        subProgress = (subjectData.progress + sessionProgressBonus).clamp(
          0.0,
          1.0,
        );
        await (_db.update(
          _db.subjects,
        )..where((t) => t.id.equals(subjectId))).write(
          SubjectsCompanion(
            progress: Value(subProgress),
            streakDays: Value(newStreak),
          ),
        );
      }

      // Adicionamos um Log para você ver magicamente a porcentagem subindo no console
      AppLogger.i(
        "🔥 Foco Concluído! Bônus: +${(sessionProgressBonus * 100).toStringAsFixed(1)}% | Progresso Total: ${(newProgress * 100).toStringAsFixed(1)}%",
      );

      // Sincroniza com o Firebase
      unawaited(
        _syncStudyTimeInFirestore(
          subjectId,
          newStreak,
          newProgress,
          subProgress,
          now,
        ),
      );
    } catch (e, stack) {
      AppLogger.e('Erro ao processar tempo de estudo', e, stack);
      rethrow;
    }
  }

  Future<void> completeReview(StudyModel currentStatus) async {
    if (_auth.currentUser == null || currentStatus.reviewQueue <= 0) return;
    final safeNewQueue = (currentStatus.reviewQueue - 1).clamp(0, 99999);

    try {
      await (_db.update(_db.studyStats)..where((t) => t.id.equals('main')))
          .write(StudyStatsCompanion(reviewQueue: Value(safeNewQueue)));
      unawaited(_completeReviewInFirestore(safeNewQueue));
    } catch (e, stack) {
      AppLogger.e('Erro ao completar revisão geral', e, stack);
    }
  }

  Future<void> resetDailyProgress(StudyModel currentStatus) async {
    if (_auth.currentUser == null) return;
    try {
      await (_db.update(_db.studyStats)..where((t) => t.id.equals('main')))
          .write(const StudyStatsCompanion(progress: Value(0.0)));
      unawaited(_resetDailyProgressInFirestore());
    } catch (e, stack) {
      AppLogger.e('Erro ao resetar progresso diário', e, stack);
    }
  }

  // ===========================================================================
  // 3. SINCRONIZAÇÃO EM BACKGROUND (FIREBASE PULL & PUSH)
  // ===========================================================================

  Future<void> syncStudyFromFirebaseToLocal() async {
    final user = _auth.currentUser;
    if (user == null) return;

    try {
      // (O código de sincronização original mantido e protegido)
      final mainDoc = await _firestore
          .collection('users')
          .doc(user.uid)
          .collection('study_info')
          .doc('main')
          .get();
      if (mainDoc.exists) {
        final data = mainDoc.data()!;
        final rawQueue = data['reviewQueue'] ?? 0;
        await _db
            .into(_db.studyStats)
            .insertOnConflictUpdate(
              StudyStatsCompanion(
                id: const Value('main'),
                streak: Value(data['streak'] ?? 0),
                reviewQueue: Value(rawQueue < 0 ? 0 : rawQueue),
                progress: Value((data['progress'] ?? 0.0).toDouble()),
                lastStudyDate: Value(
                  (data['lastStudyDate'] as Timestamp?)?.millisecondsSinceEpoch,
                ),
              ),
            );
      }

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
    } catch (e, stack) {
      AppLogger.e('Erro ao sincronizar Área de Estudos do Firebase', e, stack);
    }
  }

  // --- Métodos privados Fire-and-Forget ---

  Future<void> _createSubjectInFirestore(
    String id,
    String title,
    bool hasExam,
    DateTime? examDate,
  ) async {
    try {
      await _firestore
          .collection('users')
          .doc(_auth.currentUser!.uid)
          .collection('subjects')
          .doc(id)
          .set({
            'title': title,
            'hasExam': hasExam,
            'examDate': examDate != null ? Timestamp.fromDate(examDate) : null,
            'createdAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
    } catch (e, stack) {
      AppLogger.e('Sync Error: Criar Subject', e, stack);
    }
  }

  Future<void> _completeCardInFirestore(
    String cardId,
    String subjectId,
    int newQueue,
    double newProgress,
    int? newCardsToReview,
    int nowEpoch,
  ) async {
    try {
      final batch = _firestore.batch();
      final uid = _auth.currentUser!.uid;

      // Usando set com merge: true para evitar erro de documento não encontrado (NOT_FOUND)
      batch.set(
        _firestore
            .collection('users')
            .doc(uid)
            .collection('review_queue')
            .doc(cardId),
        {'lastReviewed': Timestamp.fromMillisecondsSinceEpoch(nowEpoch)},
        SetOptions(merge: true),
      );

      batch.set(
        _firestore
            .collection('users')
            .doc(uid)
            .collection('study_info')
            .doc('main'),
        {
          'reviewQueue': newQueue,
          'progress': newProgress,
          'lastStudyDate': Timestamp.fromMillisecondsSinceEpoch(nowEpoch),
        },
        SetOptions(merge: true),
      );

      if (newCardsToReview != null) {
        batch.set(
          _firestore
              .collection('users')
              .doc(uid)
              .collection('subjects')
              .doc(subjectId),
          {'cardsToReview': newCardsToReview},
          SetOptions(merge: true),
        );
      }
      await batch.commit();
    } catch (e, stack) {
      AppLogger.e('Sync Error: Completar Flashcard', e, stack);
    }
  }

  Future<void> _removeSubjectFromFirestore(String id, int newQueue) async {
    try {
      final uid = _auth.currentUser!.uid;
      final flashcardsQuery = await _firestore
          .collection('users')
          .doc(uid)
          .collection('review_queue')
          .where('subjectId', isEqualTo: id)
          .get();

      final batch = _firestore.batch();
      for (var doc in flashcardsQuery.docs) {
        batch.delete(doc.reference);
      }
      batch.delete(
        _firestore.collection('users').doc(uid).collection('subjects').doc(id),
      );

      batch.set(
        _firestore
            .collection('users')
            .doc(uid)
            .collection('study_info')
            .doc('main'),
        {'reviewQueue': newQueue},
        SetOptions(merge: true),
      );

      await batch.commit();
    } catch (e, stack) {
      AppLogger.e('Sync Error: Deletar Subject', e, stack);
    }
  }

  Future<void> _addFlashcardInFirestore(
    String id,
    String subjectId,
    String question,
    String answer,
  ) async {
    try {
      final uid = _auth.currentUser!.uid;
      final batch = _firestore.batch();

      batch.set(
        _firestore
            .collection('users')
            .doc(uid)
            .collection('review_queue')
            .doc(id),
        {
          'subjectId': subjectId,
          'question': question,
          'answer': answer,
          'createdAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );

      batch.set(
        _firestore
            .collection('users')
            .doc(uid)
            .collection('study_info')
            .doc('main'),
        {'reviewQueue': FieldValue.increment(1)},
        SetOptions(merge: true),
      );

      batch.set(
        _firestore
            .collection('users')
            .doc(uid)
            .collection('subjects')
            .doc(subjectId),
        {'cardsToReview': FieldValue.increment(1)},
        SetOptions(merge: true),
      );

      await batch.commit();
    } catch (e, stack) {
      AppLogger.e('Sync Error: Adicionar Flashcard', e, stack);
    }
  }

  Future<void> _logStudySessionInFirestore(
    int streak,
    double progress,
    DateTime now,
  ) async {
    try {
      await _firestore
          .collection('users')
          .doc(_auth.currentUser!.uid)
          .collection('study_info')
          .doc('main')
          .set({
            'streak': streak,
            'progress': progress,
            'lastStudyDate': Timestamp.fromDate(now),
          }, SetOptions(merge: true));
    } catch (e, stack) {
      AppLogger.e('Sync Error: Logar Sessão', e, stack);
    }
  }

  Future<void> _completeReviewInFirestore(int safeNewQueue) async {
    try {
      await _firestore
          .collection('users')
          .doc(_auth.currentUser!.uid)
          .collection('study_info')
          .doc('main')
          .set({'reviewQueue': safeNewQueue}, SetOptions(merge: true));
    } catch (e, stack) {
      AppLogger.e('Sync Error: Fila de revisão', e, stack);
    }
  }

  Future<void> _resetDailyProgressInFirestore() async {
    try {
      await _firestore
          .collection('users')
          .doc(_auth.currentUser!.uid)
          .collection('study_info')
          .doc('main')
          .set({'progress': 0.0}, SetOptions(merge: true));
    } catch (e, stack) {
      AppLogger.e('Sync Error: Reset de progresso', e, stack);
    }
  }

  // 🚀 NOVO MÉTODO PRIVADO: Sincroniza informações de progresso do foco usando Batch atômico
  Future<void> _syncStudyTimeInFirestore(
    String subjectId,
    int streak,
    double progress,
    double subjectProgress,
    DateTime now,
  ) async {
    try {
      final uid = _auth.currentUser!.uid;
      final batch = _firestore.batch();

      // 1. Atualiza dados globais
      batch.set(
        _firestore
            .collection('users')
            .doc(uid)
            .collection('study_info')
            .doc('main'),
        {
          'streak': streak,
          'progress': progress,
          'lastStudyDate': Timestamp.fromDate(now),
        },
        SetOptions(merge: true),
      );

      // 2. Atualiza dados específicos da matéria
      batch.set(
        _firestore
            .collection('users')
            .doc(uid)
            .collection('subjects')
            .doc(subjectId),
        {'progress': subjectProgress, 'streakDays': streak},
        SetOptions(merge: true),
      );

      await batch.commit();
    } catch (e, stack) {
      AppLogger.e('Sync Error: Sincronizar Tempo de Estudo do Foco', e, stack);
    }
  }
}
