import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:drift/drift.dart' hide Query;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/security/input_sanitizer.dart';
import 'package:life_os/core/utils/app_logger.dart';
import 'package:life_os/features/study/data/models/flashcard_model.dart';
import 'package:life_os/features/study/data/models/study_model.dart';
import 'package:life_os/features/study/domain/entities/study_subject_entity.dart';
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
      if (row == null) {
        return StudyModel.initial();
      }

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
      final cardData = await (_db.select(
        _db.flashcards,
      )..where((t) => t.id.equals(cardId))).getSingleOrNull();

      if (cardData == null) return;

      final subjectId = cardData.subjectId;

      final currentStats = await _db.select(_db.studyStats).getSingleOrNull();

      final currentQueue = currentStats?.reviewQueue ?? 0;

      final newQueue = currentQueue > 0
          ? (currentQueue - 1).clamp(0, 99999).toInt()
          : 0;

      final currentProgress = currentStats?.progress ?? 0.0;

      final newProgress = (currentProgress + 0.05).clamp(0.0, 1.0).toDouble();

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
        newCardsToReview = subjectData.cardsToReview > 0
            ? subjectData.cardsToReview - 1
            : 0;

        await (_db.update(_db.subjects)..where((t) => t.id.equals(subjectId)))
            .write(SubjectsCompanion(cardsToReview: Value(newCardsToReview)));
      }

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
      final flashcardsQuery = await (_db.select(
        _db.flashcards,
      )..where((t) => t.subjectId.equals(id))).get();

      final removedCardsCount = flashcardsQuery.length;

      final currentStats = await _db.select(_db.studyStats).getSingleOrNull();

      final currentQueue = currentStats?.reviewQueue ?? 0;

      final newQueue = (currentQueue - removedCardsCount)
          .clamp(0, 99999)
          .toInt();

      await _db.transaction(() async {
        await (_db.delete(
          _db.flashcards,
        )..where((t) => t.subjectId.equals(id))).go();

        await (_db.delete(_db.subjects)..where((t) => t.id.equals(id))).go();

        await (_db.delete(
          _db.notificationsTable,
        )..where((t) => t.id.equals('exam_$id'))).go();

        await (_db.update(_db.studyStats)..where((t) => t.id.equals('main')))
            .write(StudyStatsCompanion(reviewQueue: Value(newQueue)));
      });

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

      if (difference == 1) {
        newStreak++;
      } else if (difference > 1) {
        newStreak = 1;
      }
    } else {
      newStreak = 1;
    }

    final newProgress = (currentStatus.progress + 0.1)
        .clamp(0.0, 1.0)
        .toDouble();

    try {
      await _db
          .into(_db.studyStats)
          .insertOnConflictUpdate(
            StudyStatsCompanion(
              id: const Value('main'),
              streak: Value(newStreak),
              progress: Value(newProgress),
              reviewQueue: Value(currentStatus.reviewQueue),
              lastStudyDate: Value(now.millisecondsSinceEpoch),
            ),
          );

      unawaited(_logStudySessionInFirestore(newStreak, newProgress, now));
    } catch (e, stack) {
      AppLogger.e('Erro ao logar sessão', e, stack);
    }
  }

  // ===========================================================================
  // TEMPO DE ESTUDO / FOCUS
  // ===========================================================================

  Future<void> addStudyTime(String subjectId, int elapsedSeconds) async {
    if (_auth.currentUser == null) return;

    final safeElapsed = elapsedSeconds <= 0 ? 1500 : elapsedSeconds;

    final now = DateTime.now();

    final today = DateTime(now.year, now.month, now.day);

    final nowEpoch = now.millisecondsSinceEpoch;

    try {
      final currentStats = await _db.select(_db.studyStats).getSingleOrNull();

      int newStreak = currentStats?.streak ?? 0;

      final lastStudyMillis = currentStats?.lastStudyDate;

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

      double sessionProgressBonus = (safeElapsed / 1500) * 0.25;

      if (sessionProgressBonus < 0.05) {
        sessionProgressBonus = 0.05;
      }

      final newProgress = (currentProgress + sessionProgressBonus)
          .clamp(0.0, 1.0)
          .toDouble();

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

      final subjectData = await (_db.select(
        _db.subjects,
      )..where((t) => t.id.equals(subjectId))).getSingleOrNull();

      double subjectProgress = 0.0;

      if (subjectData != null) {
        subjectProgress = (subjectData.progress + sessionProgressBonus)
            .clamp(0.0, 1.0)
            .toDouble();

        await (_db.update(
          _db.subjects,
        )..where((t) => t.id.equals(subjectId))).write(
          SubjectsCompanion(
            progress: Value(subjectProgress),
            streakDays: Value(newStreak),
          ),
        );
      }

      AppLogger.i(
        '🔥 Foco Concluído! '
        'Bônus: +${(sessionProgressBonus * 100).toStringAsFixed(1)}% | '
        'Progresso Total: '
        '${(newProgress * 100).toStringAsFixed(1)}%',
      );

      unawaited(
        _syncStudyTimeInFirestore(
          subjectId,
          newStreak,
          newProgress,
          subjectProgress,
          now,
        ),
      );
    } catch (e, stack) {
      AppLogger.e('Erro ao processar tempo de estudo', e, stack);
      rethrow;
    }
  }

  Future<void> completeReview(StudyModel currentStatus) async {
    if (_auth.currentUser == null || currentStatus.reviewQueue <= 0) {
      return;
    }

    final safeNewQueue = (currentStatus.reviewQueue - 1)
        .clamp(0, 99999)
        .toInt();

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
  // 3. SINCRONIZAÇÃO FIREBASE -> DRIFT
  // ===========================================================================

  Future<void> syncStudyFromFirebaseToLocal() async {
    final user = _auth.currentUser;

    if (user == null) return;

    final userRef = _firestore.collection('users').doc(user.uid);

    // -------------------------------------------------------------------------
    // Retry para documento
    // -------------------------------------------------------------------------

    Future<DocumentSnapshot<Map<String, dynamic>>?> getDocumentWithRetry(
      DocumentReference<Map<String, dynamic>> reference,
    ) async {
      const maxAttempts = 3;

      for (var attempt = 1; attempt <= maxAttempts; attempt++) {
        try {
          return await reference.get();
        } on FirebaseException catch (e, stack) {
          final isTransient =
              e.code == 'unavailable' ||
              e.code == 'deadline-exceeded' ||
              e.code == 'network-request-failed';

          if (!isTransient || attempt == maxAttempts) {
            AppLogger.e('Study Firebase Pull falhou: ${e.code}', e, stack);

            return null;
          }

          final delay = Duration(milliseconds: 500 * (1 << (attempt - 1)));

          AppLogger.w(
            'Firestore indisponível no Study. '
            'Tentativa $attempt/$maxAttempts. '
            'Retry em ${delay.inMilliseconds}ms.',
          );

          await Future<void>.delayed(delay);
        } catch (e, stack) {
          AppLogger.e('Erro inesperado ao ler documento do Study', e, stack);

          return null;
        }
      }

      return null;
    }

    // -------------------------------------------------------------------------
    // Retry para coleção
    // -------------------------------------------------------------------------

    Future<QuerySnapshot<Map<String, dynamic>>?> getCollectionWithRetry(
      Future<QuerySnapshot<Map<String, dynamic>>> Function() operation,
    ) async {
      const maxAttempts = 3;

      for (var attempt = 1; attempt <= maxAttempts; attempt++) {
        try {
          return await operation();
        } on FirebaseException catch (e, stack) {
          final isTransient =
              e.code == 'unavailable' ||
              e.code == 'deadline-exceeded' ||
              e.code == 'network-request-failed';

          if (!isTransient || attempt == maxAttempts) {
            AppLogger.e('Study Firebase Pull falhou: ${e.code}', e, stack);

            return null;
          }

          final delay = Duration(milliseconds: 500 * (1 << (attempt - 1)));

          AppLogger.w(
            'Firestore indisponível no Study. '
            'Tentativa $attempt/$maxAttempts. '
            'Retry em ${delay.inMilliseconds}ms.',
          );

          await Future<void>.delayed(delay);
        } catch (e, stack) {
          AppLogger.e(
            'Erro inesperado ao consultar coleção do Study',
            e,
            stack,
          );

          return null;
        }
      }

      return null;
    }

    // =========================================================================
    // 1. STUDY INFO / MAIN
    // =========================================================================

    try {
      final mainDoc = await getDocumentWithRetry(
        userRef.collection('study_info').doc('main'),
      );

      if (mainDoc != null && mainDoc.exists) {
        final data = mainDoc.data();

        if (data != null) {
          final rawQueue = data['reviewQueue'];

          final reviewQueue = rawQueue is num
              ? rawQueue.toInt().clamp(0, 1 << 31).toInt()
              : 0;

          final progress = data['progress'] is num
              ? (data['progress'] as num).toDouble().clamp(0.0, 1.0).toDouble()
              : 0.0;

          final rawStreak = data['streak'];

          final streak = rawStreak is num
              ? rawStreak.toInt().clamp(0, 1 << 31).toInt()
              : 0;

          final lastStudyDate = data['lastStudyDate'];

          final lastStudyDateEpoch = lastStudyDate is Timestamp
              ? lastStudyDate.millisecondsSinceEpoch
              : null;

          await _db
              .into(_db.studyStats)
              .insertOnConflictUpdate(
                StudyStatsCompanion(
                  id: const Value('main'),
                  streak: Value(streak),
                  reviewQueue: Value(reviewQueue),
                  progress: Value(progress),
                  lastStudyDate: Value(lastStudyDateEpoch),
                ),
              );
        }
      }
    } catch (e, stack) {
      AppLogger.e('Erro ao aplicar Study Info do Firebase no Drift', e, stack);
    }

    // =========================================================================
    // 2. SUBJECTS
    // =========================================================================

    try {
      final subjectsSnapshot = await getCollectionWithRetry(
        () => userRef.collection('subjects').get(),
      );

      if (subjectsSnapshot != null) {
        for (final doc in subjectsSnapshot.docs) {
          try {
            final data = doc.data();

            final examDate = data['examDate'];

            final examDateEpoch = examDate is Timestamp
                ? examDate.millisecondsSinceEpoch
                : null;

            final rawCardsToReview = data['cardsToReview'];

            final cardsToReview = rawCardsToReview is num
                ? rawCardsToReview.toInt().clamp(0, 1 << 31).toInt()
                : 0;

            final rawStreakDays = data['streakDays'];

            final streakDays = rawStreakDays is num
                ? rawStreakDays.toInt().clamp(0, 1 << 31).toInt()
                : 0;

            final rawProgress = data['progress'];

            final progress = rawProgress is num
                ? rawProgress.toDouble().clamp(0.0, 1.0).toDouble()
                : 0.0;

            await _db
                .into(_db.subjects)
                .insertOnConflictUpdate(
                  SubjectsCompanion(
                    id: Value(doc.id),
                    title: Value(data['title']?.toString() ?? ''),
                    cardsToReview: Value(cardsToReview),
                    streakDays: Value(streakDays),
                    progress: Value(progress),
                    hasExam: Value(data['hasExam'] == true),
                    examDate: Value(examDateEpoch),
                  ),
                );
          } catch (e, stack) {
            AppLogger.e(
              'Erro ao sincronizar subject ${doc.id} do Firebase',
              e,
              stack,
            );
          }
        }
      }
    } catch (e, stack) {
      AppLogger.e('Erro ao sincronizar coleção subjects do Study', e, stack);
    }

    // =========================================================================
    // 3. REVIEW QUEUE / FLASHCARDS
    // =========================================================================

    try {
      final flashcardsSnapshot = await getCollectionWithRetry(
        () => userRef.collection('review_queue').get(),
      );

      if (flashcardsSnapshot != null) {
        for (final doc in flashcardsSnapshot.docs) {
          try {
            final data = doc.data();

            final lastReviewed = data['lastReviewed'];

            final lastReviewedEpoch = lastReviewed is Timestamp
                ? lastReviewed.millisecondsSinceEpoch
                : null;

            await _db
                .into(_db.flashcards)
                .insertOnConflictUpdate(
                  FlashcardsCompanion(
                    id: Value(doc.id),
                    subjectId: Value(data['subjectId']?.toString() ?? ''),
                    question: Value(data['question']?.toString() ?? ''),
                    answer: Value(data['answer']?.toString() ?? ''),
                    lastReviewed: Value(lastReviewedEpoch),
                  ),
                );
          } catch (e, stack) {
            AppLogger.e(
              'Erro ao sincronizar flashcard ${doc.id} do Firebase',
              e,
              stack,
            );
          }
        }
      }
    } catch (e, stack) {
      AppLogger.e(
        'Erro ao sincronizar coleção review_queue do Study',
        e,
        stack,
      );
    }
  }

  // ===========================================================================
  // 4. FIREBASE - MÉTODOS PRIVADOS
  // ===========================================================================

  Future<void> _createSubjectInFirestore(
    String id,
    String title,
    bool hasExam,
    DateTime? examDate,
  ) async {
    final user = _auth.currentUser;

    if (user == null) return;

    try {
      await _firestore
          .collection('users')
          .doc(user.uid)
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
    final user = _auth.currentUser;

    if (user == null) return;

    try {
      final uid = user.uid;

      final batch = _firestore.batch();

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
    final user = _auth.currentUser;

    if (user == null) return;

    try {
      final uid = user.uid;

      final flashcardsQuery = await _firestore
          .collection('users')
          .doc(uid)
          .collection('review_queue')
          .where('subjectId', isEqualTo: id)
          .get();

      final batch = _firestore.batch();

      for (final doc in flashcardsQuery.docs) {
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
    final user = _auth.currentUser;

    if (user == null) return;

    try {
      final uid = user.uid;

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
    final user = _auth.currentUser;

    if (user == null) return;

    try {
      await _firestore
          .collection('users')
          .doc(user.uid)
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
    final user = _auth.currentUser;

    if (user == null) return;

    try {
      await _firestore
          .collection('users')
          .doc(user.uid)
          .collection('study_info')
          .doc('main')
          .set({'reviewQueue': safeNewQueue}, SetOptions(merge: true));
    } catch (e, stack) {
      AppLogger.e('Sync Error: Fila de revisão', e, stack);
    }
  }

  Future<void> _resetDailyProgressInFirestore() async {
    final user = _auth.currentUser;

    if (user == null) return;

    try {
      await _firestore
          .collection('users')
          .doc(user.uid)
          .collection('study_info')
          .doc('main')
          .set({'progress': 0.0}, SetOptions(merge: true));
    } catch (e, stack) {
      AppLogger.e('Sync Error: Reset de progresso', e, stack);
    }
  }

  Future<void> _syncStudyTimeInFirestore(
    String subjectId,
    int streak,
    double progress,
    double subjectProgress,
    DateTime now,
  ) async {
    final user = _auth.currentUser;

    if (user == null) return;

    try {
      final uid = user.uid;

      final batch = _firestore.batch();

      // -----------------------------------------------------------------------
      // 1. Dados globais
      // -----------------------------------------------------------------------

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

      // -----------------------------------------------------------------------
      // 2. Dados específicos da matéria
      // -----------------------------------------------------------------------

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
