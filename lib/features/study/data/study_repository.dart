import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:drift/drift.dart' hide Query;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/security/input_sanitizer.dart';
import 'package:life_os/core/services/sync_manager.dart';
import 'package:life_os/core/utils/app_logger.dart';
import 'package:life_os/features/study/data/models/flashcard_model.dart';
import 'package:life_os/features/study/data/models/study_model.dart';
import 'package:life_os/features/study/domain/entities/study_subject_entity.dart';
import 'package:uuid/uuid.dart';

class _StudySessionChanged implements Exception {
  const _StudySessionChanged();
}

class _RemoteStudyStats {
  final int? streak;
  final int? reviewQueue;
  final double? progress;
  final bool hasLastStudyDate;
  final DateTime? lastStudyDate;

  const _RemoteStudyStats({
    required this.streak,
    required this.reviewQueue,
    required this.progress,
    required this.hasLastStudyDate,
    required this.lastStudyDate,
  });
}

class _RemoteStudySubject {
  final String id;
  final String title;
  final int cardsToReview;
  final int streakDays;
  final double progress;
  final bool hasExam;
  final DateTime? examDate;

  const _RemoteStudySubject({
    required this.id,
    required this.title,
    required this.cardsToReview,
    required this.streakDays,
    required this.progress,
    required this.hasExam,
    required this.examDate,
  });
}

class _RemoteFlashcard {
  final String id;
  final String subjectId;
  final String question;
  final String answer;
  final DateTime? lastReviewed;

  const _RemoteFlashcard({
    required this.id,
    required this.subjectId,
    required this.question,
    required this.answer,
    required this.lastReviewed,
  });
}

class StudyRepository {
  final AppDatabase _db;
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;
  final SyncManager _syncManager;
  final _uuid = const Uuid();

  StudyRepository(this._db, this._firestore, this._auth, this._syncManager);

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
    final expectedUid = _currentUid;
    if (expectedUid == null) return;

    final id = _uuid.v4();
    final cleanTitle = InputSanitizer.sanitize(title);

    try {
      await _db.transactionWithSync(
        ownerUid: expectedUid,
        localOperation: () async {
          _requireCurrentUser(expectedUid);
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
          _requireCurrentUser(expectedUid);
        },
        collection: 'subjects',
        docId: id,
        operationType: 'create',
        payloadJson: jsonEncode({
          'title': cleanTitle,
          'hasExam': hasExam,
          'examDate': examDate?.toIso8601String(),
        }),
      );
      _schedulePendingStudySync();
    } on _StudySessionChanged {
      return;
    } catch (e, stack) {
      AppLogger.e('Erro ao criar matéria localmente', e, stack);
      rethrow;
    }
  }

  Future<void> completeCard(String cardId) async {
    final expectedUid = _currentUid;
    if (expectedUid == null) return;

    final now = DateTime.now();
    final nowEpoch = now.millisecondsSinceEpoch;
    var didMutate = false;

    try {
      await _db.transaction(() async {
        _requireCurrentUser(expectedUid);
        final card = await (_db.select(
          _db.flashcards,
        )..where((table) => table.id.equals(cardId))).getSingleOrNull();
        if (card == null || _isSameLocalDay(card.lastReviewed, now)) return;

        final subject = await (_db.select(
          _db.subjects,
        )..where((table) => table.id.equals(card.subjectId))).getSingleOrNull();
        if (subject == null) {
          AppLogger.w('Flashcard referencia uma matéria local inexistente.');
          return;
        }

        final stats = await _db.select(_db.studyStats).getSingleOrNull();
        _requireCurrentUser(expectedUid);
        final newQueue = ((stats?.reviewQueue ?? 0) - 1)
            .clamp(0, 99999)
            .toInt();
        final newProgress = ((stats?.progress ?? 0) + 0.05)
            .clamp(0.0, 1.0)
            .toDouble();
        final newCardsToReview = (subject.cardsToReview - 1)
            .clamp(0, 99999)
            .toInt();

        await (_db.update(_db.flashcards)
              ..where((table) => table.id.equals(cardId)))
            .write(FlashcardsCompanion(lastReviewed: Value(nowEpoch)));
        await _upsertStudyStats(
          current: stats,
          reviewQueue: newQueue,
          progress: newProgress,
          lastStudyDate: nowEpoch,
        );
        await (_db.update(_db.subjects)
              ..where((table) => table.id.equals(card.subjectId)))
            .write(SubjectsCompanion(cardsToReview: Value(newCardsToReview)));

        await _enqueue(
          ownerUid: expectedUid,
          collection: 'review_queue',
          docId: cardId,
          operationType: 'update',
          payload: {
            'subjectId': card.subjectId,
            'lastReviewed': now.toIso8601String(),
          },
        );
        _requireCurrentUser(expectedUid);
        didMutate = true;
      });

      if (didMutate) _schedulePendingStudySync();
    } on _StudySessionChanged {
      return;
    } catch (e, stack) {
      AppLogger.e('Erro ao completar flashcard', e, stack);
      rethrow;
    }
  }

  Future<void> removeSubject(String id) async {
    final expectedUid = _currentUid;
    if (expectedUid == null) return;

    try {
      await _db.transactionWithSync(
        ownerUid: expectedUid,
        localOperation: () async {
          _requireCurrentUser(expectedUid);
          final flashcardsQuery = await (_db.select(
            _db.flashcards,
          )..where((table) => table.subjectId.equals(id))).get();
          final currentStats = await _db
              .select(_db.studyStats)
              .getSingleOrNull();
          _requireCurrentUser(expectedUid);
          final currentQueue = currentStats?.reviewQueue ?? 0;
          final newQueue = (currentQueue - flashcardsQuery.length)
              .clamp(0, 99999)
              .toInt();

          await (_db.delete(
            _db.flashcards,
          )..where((table) => table.subjectId.equals(id))).go();

          await (_db.delete(
            _db.subjects,
          )..where((table) => table.id.equals(id))).go();

          await (_db.delete(
            _db.notificationsTable,
          )..where((table) => table.id.equals('exam_$id'))).go();

          if (currentStats != null) {
            await (_db.update(_db.studyStats)
                  ..where((table) => table.id.equals('main')))
                .write(StudyStatsCompanion(reviewQueue: Value(newQueue)));
          }
          _requireCurrentUser(expectedUid);
        },
        collection: 'subjects',
        docId: id,
        operationType: 'delete',
        payloadJson: jsonEncode({'subjectId': id}),
      );
      _schedulePendingStudySync();
    } on _StudySessionChanged {
      return;
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
    final expectedUid = _currentUid;
    if (expectedUid == null) return;

    final id = _uuid.v4();
    final cleanQuestion = InputSanitizer.sanitize(question);
    final cleanAnswer = InputSanitizer.sanitize(answer);
    final createdAt = DateTime.now();
    var didMutate = false;

    try {
      await _db.transaction(() async {
        _requireCurrentUser(expectedUid);
        final subject = await (_db.select(
          _db.subjects,
        )..where((table) => table.id.equals(subjectId))).getSingleOrNull();
        if (subject == null) return;

        final stats = await _db.select(_db.studyStats).getSingleOrNull();
        _requireCurrentUser(expectedUid);
        final newQueue = (stats?.reviewQueue ?? 0) + 1;
        final newCardsToReview = subject.cardsToReview + 1;

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
        await (_db.update(_db.subjects)
              ..where((table) => table.id.equals(subjectId)))
            .write(SubjectsCompanion(cardsToReview: Value(newCardsToReview)));
        await _upsertStudyStats(current: stats, reviewQueue: newQueue);

        await _enqueue(
          ownerUid: expectedUid,
          collection: 'review_queue',
          docId: id,
          operationType: 'create',
          payload: {
            'subjectId': subjectId,
            'question': cleanQuestion,
            'answer': cleanAnswer,
            'createdAt': createdAt.toIso8601String(),
          },
        );
        _requireCurrentUser(expectedUid);
        didMutate = true;
      });

      if (didMutate) _schedulePendingStudySync();
    } on _StudySessionChanged {
      return;
    } catch (e, stack) {
      AppLogger.e('Erro ao criar flashcard', e, stack);
      rethrow;
    }
  }

  Future<void> logStudySession(StudyModel currentStatus) async {
    final expectedUid = _currentUid;
    if (expectedUid == null) return;

    final now = DateTime.now();
    final newStreak = _nextStreak(
      currentStatus.streak,
      currentStatus.lastStudyDate,
      now,
    );
    final newProgress = (currentStatus.progress + 0.1)
        .clamp(0.0, 1.0)
        .toDouble();

    try {
      await _db.transactionWithSync(
        ownerUid: expectedUid,
        localOperation: () async {
          _requireCurrentUser(expectedUid);
          await _db
              .into(_db.studyStats)
              .insertOnConflictUpdate(
                StudyStatsCompanion.insert(
                  id: 'main',
                  streak: newStreak,
                  reviewQueue: currentStatus.reviewQueue,
                  progress: newProgress,
                  lastStudyDate: Value(now.millisecondsSinceEpoch),
                ),
              );
          _requireCurrentUser(expectedUid);
        },
        collection: 'study_info',
        docId: 'main',
        operationType: 'update',
        payloadJson: jsonEncode({
          'streak': newStreak,
          'progress': newProgress,
          'lastStudyDate': now.toIso8601String(),
        }),
      );
      _schedulePendingStudySync();
    } on _StudySessionChanged {
      return;
    } catch (e, stack) {
      AppLogger.e('Erro ao logar sessão', e, stack);
    }
  }

  // ===========================================================================
  // TEMPO DE ESTUDO / FOCUS
  // ===========================================================================

  Future<void> addStudyTime(String subjectId, int elapsedSeconds) async {
    final expectedUid = _currentUid;
    if (expectedUid == null) return;

    final safeElapsed = elapsedSeconds <= 0 ? 1500 : elapsedSeconds;
    final now = DateTime.now();
    final nowEpoch = now.millisecondsSinceEpoch;

    try {
      await _db.transaction(() async {
        _requireCurrentUser(expectedUid);
        final stats = await _db.select(_db.studyStats).getSingleOrNull();
        final subject = await (_db.select(
          _db.subjects,
        )..where((table) => table.id.equals(subjectId))).getSingleOrNull();
        _requireCurrentUser(expectedUid);

        final lastStudyDate = stats?.lastStudyDate == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(stats!.lastStudyDate!);
        final newStreak = _nextStreak(stats?.streak ?? 0, lastStudyDate, now);
        final bonus = ((safeElapsed / 1500) * 0.25).clamp(0.05, 1.0).toDouble();
        final newProgress = ((stats?.progress ?? 0) + bonus)
            .clamp(0.0, 1.0)
            .toDouble();

        await _upsertStudyStats(
          current: stats,
          streak: newStreak,
          progress: newProgress,
          lastStudyDate: nowEpoch,
        );
        await _enqueue(
          ownerUid: expectedUid,
          collection: 'study_info',
          docId: 'main',
          operationType: 'update',
          payload: {
            'streak': newStreak,
            'progress': newProgress,
            'lastStudyDate': now.toIso8601String(),
          },
        );

        if (subject != null) {
          final subjectProgress = (subject.progress + bonus)
              .clamp(0.0, 1.0)
              .toDouble();
          await (_db.update(
            _db.subjects,
          )..where((table) => table.id.equals(subjectId))).write(
            SubjectsCompanion(
              progress: Value(subjectProgress),
              streakDays: Value(newStreak),
            ),
          );
          await _enqueue(
            ownerUid: expectedUid,
            collection: 'subjects',
            docId: subjectId,
            operationType: 'update',
            payload: {'progress': subjectProgress, 'streakDays': newStreak},
          );
        }
        _requireCurrentUser(expectedUid);
      });
      _schedulePendingStudySync();
    } on _StudySessionChanged {
      return;
    } catch (e, stack) {
      AppLogger.e('Erro ao processar tempo de estudo', e, stack);
      rethrow;
    }
  }

  Future<void> completeReview(StudyModel currentStatus) async {
    final expectedUid = _currentUid;
    if (expectedUid == null || currentStatus.reviewQueue <= 0) return;

    final safeNewQueue = (currentStatus.reviewQueue - 1)
        .clamp(0, 99999)
        .toInt();

    try {
      await _db.transactionWithSync(
        ownerUid: expectedUid,
        localOperation: () async {
          _requireCurrentUser(expectedUid);
          final stats = await _db.select(_db.studyStats).getSingleOrNull();
          await _upsertStudyStats(
            current: stats,
            fallback: currentStatus,
            reviewQueue: safeNewQueue,
          );
          _requireCurrentUser(expectedUid);
        },
        collection: 'study_info',
        docId: 'main',
        operationType: 'update',
        payloadJson: jsonEncode({'reviewQueue': safeNewQueue}),
      );
      _schedulePendingStudySync();
    } on _StudySessionChanged {
      return;
    } catch (e, stack) {
      AppLogger.e('Erro ao completar revisão geral', e, stack);
    }
  }

  Future<void> resetDailyProgress(StudyModel currentStatus) async {
    final expectedUid = _currentUid;
    if (expectedUid == null) return;

    try {
      await _db.transactionWithSync(
        ownerUid: expectedUid,
        localOperation: () async {
          _requireCurrentUser(expectedUid);
          final stats = await _db.select(_db.studyStats).getSingleOrNull();
          await _upsertStudyStats(
            current: stats,
            fallback: currentStatus,
            progress: 0,
          );
          _requireCurrentUser(expectedUid);
        },
        collection: 'study_info',
        docId: 'main',
        operationType: 'update',
        payloadJson: jsonEncode({'progress': 0.0}),
      );
      _schedulePendingStudySync();
    } on _StudySessionChanged {
      return;
    } catch (e, stack) {
      AppLogger.e('Erro ao resetar progresso diário', e, stack);
    }
  }

  // ===========================================================================
  // 3. SINCRONIZAÇÃO FIREBASE -> DRIFT
  // ===========================================================================

  Future<void> syncStudyFromFirebaseToLocal() async {
    final expectedUid = _currentUid;
    if (expectedUid == null) return;

    try {
      final pullStartedAt = DateTime.now().millisecondsSinceEpoch;
      final queueDrained = await _syncManager.processPendingItems();
      if (!queueDrained || !_isCurrentUser(expectedUid)) return;

      final userRef = _firestore.collection('users').doc(expectedUid);
      final mainDoc = await _getStudyDocument(
        userRef.collection('study_info').doc('main'),
      );
      if (mainDoc == null) return;
      final subjectsSnapshot = await _getStudyCollection(
        userRef.collection('subjects'),
      );
      if (subjectsSnapshot == null) return;
      final flashcardsSnapshot = await _getStudyCollection(
        userRef.collection('review_queue'),
      );
      if (flashcardsSnapshot == null) return;
      _requireCurrentUser(expectedUid);

      final remoteStats = mainDoc.exists
          ? _parseRemoteStudyStats(mainDoc.data())
          : null;
      if (mainDoc.exists && remoteStats == null) {
        AppLogger.w('SYNC Study: informações remotas inválidas ignoradas.');
      }

      final remoteSubjects = <_RemoteStudySubject>[];
      for (final doc in subjectsSnapshot.docs) {
        final parsed = _parseRemoteSubject(doc.id, doc.data());
        if (parsed == null) {
          AppLogger.w('SYNC Study: matéria remota inválida ignorada.');
        } else {
          remoteSubjects.add(parsed);
        }
      }

      final remoteFlashcards = <_RemoteFlashcard>[];
      for (final doc in flashcardsSnapshot.docs) {
        final parsed = _parseRemoteFlashcard(doc.id, doc.data());
        if (parsed == null) {
          AppLogger.w('SYNC Study: flashcard remoto inválido ignorado.');
        } else {
          remoteFlashcards.add(parsed);
        }
      }

      await _reconcileStudySnapshot(
        expectedUid: expectedUid,
        pullStartedAt: pullStartedAt,
        remoteStats: remoteStats,
        remoteSubjects: remoteSubjects,
        remoteFlashcards: remoteFlashcards,
      );
    } on _StudySessionChanged {
      return;
    } catch (_) {
      AppLogger.w('Não foi possível sincronizar os estudos neste momento.');
    }
  }

  String? get _currentUid {
    final uid = _auth.currentUser?.uid.trim();
    return uid == null || uid.isEmpty ? null : uid;
  }

  bool _isCurrentUser(String expectedUid) =>
      _auth.currentUser?.uid == expectedUid;

  void _requireCurrentUser(String expectedUid) {
    if (!_isCurrentUser(expectedUid)) {
      throw const _StudySessionChanged();
    }
  }

  void _schedulePendingStudySync() {
    unawaited(
      _syncManager.processPendingItems().catchError((Object _, StackTrace _) {
        AppLogger.w('Não foi possível enviar estudos pendentes agora.');
        return false;
      }),
    );
  }

  Future<void> _enqueue({
    required String ownerUid,
    required String collection,
    required String docId,
    required String operationType,
    required Map<String, dynamic> payload,
  }) async {
    await _db.insertSyncItem(
      ownerUid: ownerUid,
      collection: collection,
      docId: docId,
      operationType: operationType,
      payloadJson: jsonEncode(payload),
    );
  }

  Future<void> _upsertStudyStats({
    required StudyStat? current,
    StudyModel? fallback,
    int? streak,
    int? reviewQueue,
    double? progress,
    int? lastStudyDate,
  }) async {
    await _db
        .into(_db.studyStats)
        .insertOnConflictUpdate(
          StudyStatsCompanion.insert(
            id: 'main',
            streak: streak ?? current?.streak ?? fallback?.streak ?? 0,
            reviewQueue:
                reviewQueue ??
                current?.reviewQueue ??
                fallback?.reviewQueue ??
                0,
            progress: progress ?? current?.progress ?? fallback?.progress ?? 0,
            lastStudyDate: Value(
              lastStudyDate ??
                  current?.lastStudyDate ??
                  fallback?.lastStudyDate?.millisecondsSinceEpoch,
            ),
          ),
        );
  }

  int _nextStreak(int current, DateTime? lastStudyDate, DateTime now) {
    if (lastStudyDate == null) return 1;
    final today = DateTime(now.year, now.month, now.day);
    final last = DateTime(
      lastStudyDate.year,
      lastStudyDate.month,
      lastStudyDate.day,
    );
    final difference = today.difference(last).inDays;
    if (difference == 1) return current + 1;
    if (difference > 1) return 1;
    return current;
  }

  bool _isSameLocalDay(int? epoch, DateTime now) {
    if (epoch == null) return false;
    final date = DateTime.fromMillisecondsSinceEpoch(epoch);
    return date.year == now.year &&
        date.month == now.month &&
        date.day == now.day;
  }

  Future<DocumentSnapshot<Map<String, dynamic>>?> _getStudyDocument(
    DocumentReference<Map<String, dynamic>> reference,
  ) async {
    try {
      return await reference.get(const GetOptions(source: Source.server));
    } catch (_) {
      return null;
    }
  }

  Future<QuerySnapshot<Map<String, dynamic>>?> _getStudyCollection(
    CollectionReference<Map<String, dynamic>> reference,
  ) async {
    try {
      return await reference.get(const GetOptions(source: Source.server));
    } catch (_) {
      return null;
    }
  }

  Future<void> _reconcileStudySnapshot({
    required String expectedUid,
    required int pullStartedAt,
    required _RemoteStudyStats? remoteStats,
    required List<_RemoteStudySubject> remoteSubjects,
    required List<_RemoteFlashcard> remoteFlashcards,
  }) async {
    await _db.transaction(() async {
      _requireCurrentUser(expectedUid);
      final authoritativeItems =
          await (_db.select(_db.syncQueueTable)..where(
                (item) =>
                    item.ownerUid.equals(expectedUid) &
                    (item.collection.equals('study_info') |
                        item.collection.equals('subjects') |
                        item.collection.equals('review_queue')) &
                    (item.status.equals(SyncQueuePersistenceStatus.pending) |
                        (item.status.equals(
                              SyncQueuePersistenceStatus.succeeded,
                            ) &
                            item.createdAt.isBiggerOrEqualValue(
                              pullStartedAt,
                            ))),
              ))
              .get();

      final reviewMutations = authoritativeItems.where(
        (item) =>
            item.collection == 'review_queue' &&
            (item.operationType == 'create' || item.operationType == 'update'),
      );
      final protectStats =
          authoritativeItems.any(
            (item) => item.collection == 'study_info' && item.docId == 'main',
          ) ||
          reviewMutations.isNotEmpty;
      final protectSubjects = authoritativeItems
          .where((item) => item.collection == 'subjects')
          .map((item) => item.docId)
          .toSet();
      var protectAllSubjects = false;
      for (final item in reviewMutations) {
        try {
          final payload = jsonDecode(item.payloadJson);
          final subjectId = payload is Map<String, dynamic>
              ? payload['subjectId']
              : null;
          if (subjectId is String && subjectId.trim().isNotEmpty) {
            protectSubjects.add(subjectId);
          } else {
            protectAllSubjects = true;
          }
        } on FormatException {
          protectAllSubjects = true;
        }
      }
      final protectCards = authoritativeItems
          .where((item) => item.collection == 'review_queue')
          .map((item) => item.docId)
          .toSet();
      _requireCurrentUser(expectedUid);

      if (!protectStats && remoteStats != null) {
        await _applyRemoteStudyStats(expectedUid, remoteStats);
      }

      for (final subject in remoteSubjects) {
        _requireCurrentUser(expectedUid);
        if (protectAllSubjects || protectSubjects.contains(subject.id))
          continue;
        await _db
            .into(_db.subjects)
            .insertOnConflictUpdate(
              SubjectsCompanion.insert(
                id: subject.id,
                title: subject.title,
                cardsToReview: subject.cardsToReview,
                streakDays: subject.streakDays,
                progress: subject.progress,
                hasExam: subject.hasExam,
                examDate: Value(subject.examDate?.millisecondsSinceEpoch),
              ),
            );
        _requireCurrentUser(expectedUid);
      }

      for (final card in remoteFlashcards) {
        _requireCurrentUser(expectedUid);
        if (protectCards.contains(card.id)) continue;
        final subject = await (_db.select(
          _db.subjects,
        )..where((table) => table.id.equals(card.subjectId))).getSingleOrNull();
        _requireCurrentUser(expectedUid);
        if (subject == null) {
          AppLogger.w('SYNC Study: flashcard sem matéria válida ignorado.');
          continue;
        }
        await _db
            .into(_db.flashcards)
            .insertOnConflictUpdate(
              FlashcardsCompanion.insert(
                id: card.id,
                subjectId: card.subjectId,
                question: card.question,
                answer: card.answer,
                lastReviewed: Value(card.lastReviewed?.millisecondsSinceEpoch),
              ),
            );
        _requireCurrentUser(expectedUid);
      }
    });
  }

  _RemoteStudyStats? _parseRemoteStudyStats(Map<String, dynamic>? data) {
    if (data == null || data.isEmpty) return null;
    final streak = data['streak'];
    final queue = data['reviewQueue'];
    final progress = data['progress'];
    final hasDate = data.containsKey('lastStudyDate');
    final date = hasDate ? _parseRemoteDate(data['lastStudyDate']) : null;
    if ((data.containsKey('streak') && (streak is! int || streak < 0)) ||
        (data.containsKey('reviewQueue') && (queue is! int || queue < 0)) ||
        (data.containsKey('progress') && !_isValidProgress(progress)) ||
        (hasDate && date == null)) {
      return null;
    }
    return _RemoteStudyStats(
      streak: streak as int?,
      reviewQueue: queue as int?,
      progress: progress == null ? null : (progress as num).toDouble(),
      hasLastStudyDate: hasDate,
      lastStudyDate: date,
    );
  }

  _RemoteStudySubject? _parseRemoteSubject(
    String id,
    Map<String, dynamic> data,
  ) {
    final title = data['title'];
    final cards = data['cardsToReview'];
    final streak = data['streakDays'];
    final progress = data['progress'];
    final hasExam = data['hasExam'];
    final rawExamDate = data['examDate'];
    final examDate = rawExamDate == null ? null : _parseRemoteDate(rawExamDate);
    if (id.trim().isEmpty ||
        title is! String ||
        title.trim().isEmpty ||
        cards is! int ||
        cards < 0 ||
        streak is! int ||
        streak < 0 ||
        !_isValidProgress(progress) ||
        hasExam is! bool ||
        (rawExamDate != null && examDate == null)) {
      return null;
    }
    return _RemoteStudySubject(
      id: id,
      title: title,
      cardsToReview: cards,
      streakDays: streak,
      progress: (progress as num).toDouble(),
      hasExam: hasExam,
      examDate: examDate,
    );
  }

  _RemoteFlashcard? _parseRemoteFlashcard(
    String id,
    Map<String, dynamic> data,
  ) {
    final subjectId = data['subjectId'];
    final question = data['question'];
    final answer = data['answer'];
    final rawReviewed = data['lastReviewed'];
    final reviewed = rawReviewed == null ? null : _parseRemoteDate(rawReviewed);
    if (id.trim().isEmpty ||
        subjectId is! String ||
        subjectId.trim().isEmpty ||
        question is! String ||
        question.trim().isEmpty ||
        answer is! String ||
        answer.trim().isEmpty ||
        (rawReviewed != null && reviewed == null)) {
      return null;
    }
    return _RemoteFlashcard(
      id: id,
      subjectId: subjectId,
      question: question,
      answer: answer,
      lastReviewed: reviewed,
    );
  }

  bool _isValidProgress(Object? value) {
    if (value is! num) return false;
    final progress = value.toDouble();
    return progress.isFinite && progress >= 0 && progress <= 1;
  }

  DateTime? _parseRemoteDate(Object? value) => switch (value) {
    Timestamp timestamp => timestamp.toDate(),
    DateTime date => date,
    String text => DateTime.tryParse(text),
    _ => null,
  };

  Future<void> _applyRemoteStudyStats(
    String expectedUid,
    _RemoteStudyStats remote,
  ) async {
    _requireCurrentUser(expectedUid);
    final current = await _db.select(_db.studyStats).getSingleOrNull();
    _requireCurrentUser(expectedUid);
    if (current == null) {
      await _db
          .into(_db.studyStats)
          .insert(
            StudyStatsCompanion.insert(
              id: 'main',
              streak: remote.streak ?? 0,
              reviewQueue: remote.reviewQueue ?? 0,
              progress: remote.progress ?? 0,
              lastStudyDate: Value(
                remote.hasLastStudyDate
                    ? remote.lastStudyDate?.millisecondsSinceEpoch
                    : null,
              ),
            ),
          );
      _requireCurrentUser(expectedUid);
      return;
    }

    await (_db.update(
      _db.studyStats,
    )..where((table) => table.id.equals('main'))).write(
      StudyStatsCompanion(
        streak: remote.streak == null
            ? const Value.absent()
            : Value(remote.streak!),
        reviewQueue: remote.reviewQueue == null
            ? const Value.absent()
            : Value(remote.reviewQueue!),
        progress: remote.progress == null
            ? const Value.absent()
            : Value(remote.progress!),
        lastStudyDate: remote.hasLastStudyDate
            ? Value(remote.lastStudyDate?.millisecondsSinceEpoch)
            : const Value.absent(),
      ),
    );
    _requireCurrentUser(expectedUid);
  }
}
