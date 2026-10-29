import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:drift/drift.dart' hide Query;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/local_mutation_gate.dart';
import 'package:life_os/core/security/input_sanitizer.dart';
import 'package:life_os/core/services/sync_manager.dart';
import 'package:life_os/core/services/sync_remote_data_source.dart'
    show LegacyStudyInfoOperation, StudyStateHoldOperation;
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

/// Local visibility only: card counts, operation counts and FIFO proof are distinct.
class ReviewCreationSyncState {
  const ReviewCreationSyncState(
    this._isCurrent, {
    this.pending = 0,
    this.indeterminate = 0,
    this.recovery = 0,
    this.pendingWithoutCard = 0,
    this.studyInfoHold = 0,
    this.studyStateHold = 0,
    this.studyStateRejected = 0,
    this.rejectedWithoutCard = 0,
    this.legacyPending = 0,
    this.headBlocked = false,
    this.waitingBehindHead = 0,
    this.queueVerified = true,
    this.retryEligible = false,
    int? retryOperationId,
    required this.sessionToken,
    // Public parameter, private field: keep row identity out of the view API.
    // ignore: prefer_initializing_formals
  }) : _retryOperationId = retryOperationId;

  const ReviewCreationSyncState.empty()
    : pending = 0,
      indeterminate = 0,
      recovery = 0,
      pendingWithoutCard = 0,
      studyInfoHold = 0,
      studyStateHold = 0,
      studyStateRejected = 0,
      rejectedWithoutCard = 0,
      legacyPending = 0,
      headBlocked = false,
      waitingBehindHead = 0,
      queueVerified = false,
      retryEligible = false,
      _retryOperationId = null,
      sessionToken = null,
      _isCurrent = null;

  final int pending;
  final int indeterminate;
  final int recovery;
  final int pendingWithoutCard;
  final int studyInfoHold;
  final int studyStateHold;
  final int studyStateRejected;
  int get studyVerification => studyStateHold + studyStateRejected;
  final int rejectedWithoutCard;
  final int legacyPending;
  final bool headBlocked;
  final int waitingBehindHead;
  final bool queueVerified;
  final bool retryEligible;
  final int? _retryOperationId;
  final Object? sessionToken;
  final bool Function()? _isCurrent;
  bool get isCurrent {
    try {
      return _isCurrent?.call() ?? false;
    } catch (_) {
      return false;
    }
  }

  // Historical E counts still mean distinct cards that actually exist locally.
  int get affected => pending + indeterminate + recovery;
  bool get hasNotice =>
      affected > 0 ||
      pendingWithoutCard > 0 ||
      studyInfoHold > 0 ||
      studyVerification > 0;
  bool get needsVerification =>
      recovery > 0 ||
      pendingWithoutCard > 0 ||
      studyInfoHold > 0 ||
      studyVerification > 0 ||
      (!queueVerified && hasNotice);
  bool get canRequestRetry =>
      isCurrent &&
      queueVerified &&
      retryEligible &&
      recovery == 0 &&
      pendingWithoutCard == 0 &&
      studyInfoHold == 0 &&
      studyVerification == 0 &&
      indeterminate > 0;
}

class StudyRepository {
  static const _dueCardsPredicate =
      '(cards.last_reviewed IS NULL OR cards.last_reviewed < ?)';

  final AppDatabase _db;
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;
  final SyncManager _syncManager;
  final DateTime Function() _reviewNow;
  final _uuid = const Uuid();

  StudyRepository(
    this._db,
    this._firestore,
    this._auth,
    this._syncManager, {
    DateTime Function()? reviewNow,
  }) : _reviewNow = reviewNow ?? DateTime.now;

  Selectable<QueryRow> _reviewCreationRows(String uid) => _db.customSelect(
    '''SELECT q.*, c.id AS local_card_id, c.subject_id AS local_subject_id,
              c.question AS local_question, c.answer AS local_answer,
              s.id AS local_subject_present
       FROM sync_queue_table AS q
       LEFT JOIN flashcards AS c ON c.id = q.doc_id
       LEFT JOIN subjects AS s ON s.id = c.subject_id
       WHERE q.owner_uid = ? AND q.status != ? ORDER BY q.id ASC''',
    variables: [
      Variable<String>(uid),
      Variable<String>(SyncQueuePersistenceStatus.succeeded),
    ],
    readsFrom: {_db.syncQueueTable, _db.flashcards, _db.subjects},
  );

  // Conservative UI admission, not a replacement for the transport's validator.
  // No repair/normalization of payloads or inference of a historical ACK.
  bool _eligibleReviewCreation(QueryRow row, SyncQueueTableData item) {
    try {
      final data = jsonDecode(item.payloadJson);
      const keys = {
        'creationProtocolVersion',
        'cardId',
        'subjectId',
        'question',
        'answer',
        'createdAt',
      };
      final id = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$');
      if (data is! Map<String, dynamic> ||
          data.length != keys.length ||
          !data.keys.every(keys.contains) ||
          data['creationProtocolVersion'] is! int ||
          data['creationProtocolVersion'] != 1 ||
          data['cardId'] != item.docId ||
          !id.hasMatch(item.docId) ||
          data['subjectId'] is! String ||
          !id.hasMatch(data['subjectId'] as String) ||
          row.readNullable<String>('local_card_id') == null ||
          row.readNullable<String>('local_subject_present') !=
              data['subjectId'] ||
          row.readNullable<String>('local_subject_id') != data['subjectId'])
        return false;
      for (final field in ['question', 'answer']) {
        final text = data[field];
        if (text is! String ||
            text.trim().isEmpty ||
            utf8.decode(utf8.encode(text)) != text ||
            row.readNullable<String>('local_$field') != text)
          return false;
      }
      final time = data['createdAt'];
      if (time is! String ||
          !RegExp(
            r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}(\d{3})?Z$',
          ).hasMatch(time))
        return false;
      final date = DateTime.tryParse(time);
      if (date == null ||
          !date.isUtc ||
          date.year < 1 ||
          date.year > 9999 ||
          date.toIso8601String() != time)
        return false;
      return utf8
              .encode(
                jsonEncode({
                  'operation': 'create_review_card',
                  'version': 1,
                  'cardId': data['cardId'],
                  'subjectId': data['subjectId'],
                  'question': data['question'],
                  'answer': data['answer'],
                  'createdAt': time,
                }),
              )
              .length <=
          512 * 1024;
    } catch (_) {
      return false;
    }
  }

  ReviewCreationSyncState _summarizeReviewCreation(
    List<QueryRow> rows,
    bool Function() admitted,
    Object sessionToken,
  ) {
    final cards = <String, int>{};
    int? head;
    var missing = 0, hold = 0, rejectedMissing = 0, legacy = 0;
    var stateHold = 0, stateRejected = 0;
    var blockedHead = false, eligibleHead = false;
    final pendingIds = <int>[];
    const recoveryCodes = {
      'REVIEW_CREATE_LEGACY_UNVERIFIED',
      'REVIEW_CREATE_FINGERPRINT_CONFLICT',
      'REVIEW_CREATE_RECEIPT_INVALID',
      'REVIEW_CREATE_ROOT_UNAVAILABLE',
      'REVIEW_CREATE_SUBJECT_UNAVAILABLE',
      'REVIEW_CREATE_SUBJECT_TOMBSTONED',
      'REVIEW_CREATE_STATE_INVALID',
    };
    for (final row in rows) {
      final item = _db.syncQueueTable.map(row.data);
      final pending = item.status == SyncQueuePersistenceStatus.pending;
      if (pending) {
        head ??= item.id;
        pendingIds.add(item.id);
      }
      final atHead = pending && item.id == head;
      if (LegacyStudyInfoOperation.isBlocked(item)) {
        if (pending) {
          hold++;
          if (atHead) blockedHead = true;
        }
        continue;
      }
      if (StudyStateHoldOperation.isHeld(item)) {
        stateHold++;
        if (atHead) blockedHead = true;
        continue;
      }
      if (StudyStateHoldOperation.isHistoricalRejected(item)) {
        stateRejected++;
        continue;
      }
      if (item.collection.trim() != 'review_queue' ||
          item.operationType.trim().toLowerCase() != 'create')
        continue;
      final hasCard = row.readNullable<String>('local_card_id') != null;
      var versioned = false;
      try {
        final data = jsonDecode(item.payloadJson);
        versioned =
            data is Map<String, dynamic> &&
            data['creationProtocolVersion'] is int &&
            data['creationProtocolVersion'] == 1;
      } catch (_) {
        /* Unknown legacy is preserved, never promoted. */
      }
      if (pending && !versioned) legacy++;
      if (!hasCard) {
        if (pending) {
          missing++;
          if (atHead) blockedHead = true;
        } else if (item.status == SyncQueuePersistenceStatus.rejected) {
          rejectedMissing++;
        }
        continue;
      }
      final valid = _eligibleReviewCreation(row, item);
      final needsVerification =
          !pending ||
          !versioned ||
          !valid ||
          recoveryCodes.contains(item.lastErrorCode);
      final attempted =
          item.lastErrorCode != null ||
          item.attemptCount > 0 ||
          item.lastAttemptAt != null;
      final severity = needsVerification
          ? 2
          : attempted
          ? 1
          : 0;
      if (!cards.containsKey(item.docId) || cards[item.docId]! < severity)
        cards[item.docId] = severity;
      if (atHead) {
        blockedHead = needsVerification;
        eligibleHead = !needsVerification && attempted;
      }
    }
    return ReviewCreationSyncState(
      admitted,
      pending: cards.values.where((v) => v == 0).length,
      indeterminate: cards.values.where((v) => v == 1).length,
      recovery: cards.values.where((v) => v == 2).length,
      pendingWithoutCard: missing,
      studyInfoHold: hold,
      studyStateHold: stateHold,
      studyStateRejected: stateRejected,
      rejectedWithoutCard: rejectedMissing,
      legacyPending: legacy,
      headBlocked: blockedHead,
      waitingBehindHead: blockedHead
          ? pendingIds.where((id) => id > head!).length
          : 0,
      retryEligible: eligibleHead,
      retryOperationId: eligibleHead ? head : null,
      sessionToken: sessionToken,
    );
  }

  /// Observe only persisted local rows belonging to this prepared session.
  /// No pull, remote receipt read, polling, queue mutation or payload exposure.
  Stream<ReviewCreationSyncState> watchReviewCreationSync() {
    late StreamController<ReviewCreationSyncState> output;
    StreamSubscription<User?>? authSubscription;
    StreamSubscription<List<QueryRow>>? rowsSubscription;
    var generation = 0;
    var cancelled = false;

    void observeSession() {
      final currentGeneration = ++generation;
      final previous = rowsSubscription;
      rowsSubscription = null;
      if (previous != null)
        unawaited(previous.cancel().catchError((Object _) {}));
      output.add(const ReviewCreationSyncState.empty());
      final uid = _currentUid;
      if (uid == null || cancelled) return;
      final sessionToken = Object();
      final bool Function() admitted;
      try {
        final permit = _db.localMutations.captureRemoteSend(expectedUid: uid);
        admitted = () =>
            !cancelled &&
            generation == currentGeneration &&
            _isCurrentUser(uid) &&
            permit.isCurrent;
      } catch (_) {
        return;
      }
      var last = const ReviewCreationSyncState.empty();
      var revision = 0;
      void readFailed() {
        if (cancelled || generation != currentGeneration || !admitted()) return;
        final currentRevision = ++revision;
        last = ReviewCreationSyncState(
          () => admitted() && revision == currentRevision,
          indeterminate: last.pending + last.indeterminate,
          recovery: last.recovery,
          pendingWithoutCard: last.pendingWithoutCard,
          studyInfoHold: last.studyInfoHold,
          studyStateHold: last.studyStateHold,
          studyStateRejected: last.studyStateRejected,
          rejectedWithoutCard: last.rejectedWithoutCard,
          legacyPending: last.legacyPending,
          queueVerified: false,
          sessionToken: sessionToken,
        );
        output.add(last);
      }

      try {
        rowsSubscription = _reviewCreationRows(uid).watch().listen((rows) {
          if (cancelled || generation != currentGeneration) return;
          if (!admitted()) {
            output.add(const ReviewCreationSyncState.empty());
            return;
          }
          final currentRevision = ++revision;
          try {
            last = _summarizeReviewCreation(
              rows,
              () => admitted() && revision == currentRevision,
              sessionToken,
            );
            if (last.isCurrent) output.add(last);
          } catch (_) {
            readFailed();
          }
        }, onError: (Object _) => readFailed());
      } catch (_) {
        readFailed();
      }
    }

    output = StreamController<ReviewCreationSyncState>(
      onListen: () {
        observeSession();
        // Every event invalidates old callbacks, including queued A -> B -> A.
        authSubscription = _auth.authStateChanges().listen(
          (_) => observeSession(),
          onError: (Object _) {
            if (cancelled) return;
            generation++;
            output.add(const ReviewCreationSyncState.empty());
            final previous = rowsSubscription;
            rowsSubscription = null;
            if (previous != null)
              unawaited(previous.cancel().catchError((Object _) {}));
          },
        );
      },
      onCancel: () async {
        cancelled = true;
        generation++;
        await authSubscription?.cancel();
        await rowsSubscription?.cancel();
      },
    );
    return output.stream;
  }

  /// Explicit user request for the current UID's existing FIFO drain only.
  /// Rejected/legacy operations are never promoted, requeued or repaired here.
  Future<void> retryReviewCreationSync(ReviewCreationSyncState observed) async {
    if (!observed.canRequestRetry) return;
    final uid = _currentUid;
    if (uid == null) return;
    try {
      final permit = _db.localMutations.captureRemoteSend(expectedUid: uid);
      if (!observed.isCurrent ||
          !permit.isCurrent ||
          observed._retryOperationId == null)
        return;
      // A queued SQL notification can lag the user's tap. Re-read the actual
      // FIFO/context without writes before admitting a manual drain.
      final rows = await _reviewCreationRows(uid).get();
      if (!observed.isCurrent || !permit.isCurrent) return;
      final fresh = _summarizeReviewCreation(
        rows,
        () => observed.isCurrent && permit.isCurrent,
        observed.sessionToken!,
      );
      if (!fresh.canRequestRetry ||
          fresh._retryOperationId != observed._retryOperationId)
        return;
      await _syncManager.processPendingItems();
    } catch (_) {
      /* Persisted queue remains the only delivery truth. */
    }
  }

  // ===========================================================================
  // 1. LEITURA (STREAMS LOCAIS)
  // ===========================================================================

  Stream<StudyModel> getStudyStatsStream() {
    return _db
        .customSelect(
          '''
          SELECT
            stats.streak AS streak,
            stats.progress AS progress,
            stats.last_study_date AS last_study_date,
            COUNT(cards.id) AS due_count
          FROM (SELECT 1) AS singleton
          LEFT JOIN study_stats AS stats ON stats.id = 'main'
          LEFT JOIN flashcards AS cards ON $_dueCardsPredicate
          GROUP BY stats.streak, stats.progress, stats.last_study_date
          ''',
          variables: [Variable.withInt(_startOfReviewDayEpoch())],
          readsFrom: {_db.studyStats, _db.subjects, _db.flashcards},
        )
        .watchSingle()
        .map((row) {
          final lastStudyDate = row.readNullable<int>('last_study_date');
          return StudyModel(
            streak: row.readNullable<int>('streak') ?? 0,
            reviewQueue: row.read<int>('due_count'),
            progress: row.readNullable<double>('progress') ?? 0,
            lastStudyDate: lastStudyDate != null
                ? DateTime.fromMillisecondsSinceEpoch(lastStudyDate)
                : null,
          );
        });
  }

  Stream<List<StudySubjectEntity>> getSubjectsStream() {
    return _db
        .customSelect(
          '''
          SELECT
            subjects.id AS subject_id,
            subjects.title AS title,
            subjects.streak_days AS streak_days,
            subjects.progress AS progress,
            subjects.has_exam AS has_exam,
            subjects.exam_date AS exam_date,
            COUNT(cards.id) AS due_count
          FROM subjects
          LEFT JOIN flashcards AS cards
            ON cards.subject_id = subjects.id
            AND $_dueCardsPredicate
          GROUP BY
            subjects.id,
            subjects.title,
            subjects.streak_days,
            subjects.progress,
            subjects.has_exam,
            subjects.exam_date
          ''',
          variables: [Variable.withInt(_startOfReviewDayEpoch())],
          readsFrom: {_db.subjects, _db.flashcards},
        )
        .watch()
        .map(
          (rows) => rows.map((r) {
            final examDate = r.readNullable<int>('exam_date');
            return StudySubjectEntity(
              id: r.read<String>('subject_id'),
              title: r.read<String>('title'),
              cardsToReview: r.read<int>('due_count'),
              streakDays: r.read<int>('streak_days'),
              progress: r.read<double>('progress'),
              hasExam: r.read<bool>('has_exam'),
              examDate: examDate != null
                  ? DateTime.fromMillisecondsSinceEpoch(examDate)
                  : null,
            );
          }).toList(),
        );
  }

  Stream<List<FlashcardModel>> getFlashcardsStream() {
    return _db
        .customSelect(
          '''
          SELECT cards.id, cards.question, cards.answer
          FROM flashcards AS cards
          WHERE $_dueCardsPredicate
          ''',
          variables: [Variable.withInt(_startOfReviewDayEpoch())],
          readsFrom: {_db.subjects, _db.flashcards},
        )
        .watch()
        .map(
          (rows) => rows
              .map(
                (r) => FlashcardModel(
                  id: r.read<String>('id'),
                  question: r.read<String>('question'),
                  answer: r.read<String>('answer'),
                ),
              )
              .toList(),
        );
  }

  int _startOfReviewDayEpoch() {
    final now = _reviewNow();
    return DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
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
      unawaited(syncStudyFromFirebaseToLocal());
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

    final now = _reviewNow();
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
        final currentLastStudyDate = stats?.lastStudyDate == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(stats!.lastStudyDate!);
        final newStreak = _nextStreak(
          stats?.streak ?? 0,
          currentLastStudyDate,
          now,
        );
        final newLastStudyDate =
            stats?.lastStudyDate != null && stats!.lastStudyDate! > nowEpoch
            ? stats.lastStudyDate!
            : nowEpoch;
        final newCardsToReview = (subject.cardsToReview - 1)
            .clamp(0, 99999)
            .toInt();

        await (_db.update(_db.flashcards)
              ..where((table) => table.id.equals(cardId)))
            .write(FlashcardsCompanion(lastReviewed: Value(nowEpoch)));
        await _upsertStudyStats(
          current: stats,
          streak: newStreak,
          reviewQueue: newQueue,
          progress: newProgress,
          lastStudyDate: newLastStudyDate,
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
            'lastReviewed': now.toUtc().toIso8601String(),
            'timeZoneOffsetMinutes': now.timeZoneOffset.inMinutes,
          },
        );
        _requireCurrentUser(expectedUid);
        didMutate = true;
      });

      if (didMutate) unawaited(syncStudyFromFirebaseToLocal());
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
    final createdAt = DateTime.now().toUtc().toIso8601String();
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
            'createdAt': createdAt,
            'cardId': id,
            'creationProtocolVersion': 1,
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

    final activityId = _uuid.v4();
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
        collection: 'study_activity',
        docId: activityId,
        operationType: 'create',
        payloadJson: jsonEncode({
          'subjectId': null,
          'progressDelta': 0.1,
          'occurredAt': now.toUtc().toIso8601String(),
          'timeZoneOffsetMinutes': now.timeZoneOffset.inMinutes,
        }),
      );
      unawaited(syncStudyFromFirebaseToLocal());
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

    final activityId = _uuid.v4();
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
        }
        await _enqueue(
          ownerUid: expectedUid,
          collection: 'study_activity',
          docId: activityId,
          operationType: 'create',
          payload: {
            'subjectId': subject == null ? null : subjectId,
            'progressDelta': bonus,
            'occurredAt': now.toUtc().toIso8601String(),
            'timeZoneOffsetMinutes': now.timeZoneOffset.inMinutes,
          },
        );
        _requireCurrentUser(expectedUid);
      });
      unawaited(syncStudyFromFirebaseToLocal());
    } on _StudySessionChanged {
      return;
    } catch (e, stack) {
      AppLogger.e('Erro ao processar tempo de estudo', e, stack);
      rethrow;
    }
  }

  /// Absolute legacy counters cannot identify the reviewed card or its effects.
  /// Keep the signature until old callers are removed; never enqueue this intent.
  Future<void> completeReview(StudyModel currentStatus) async {
    throw UnsupportedError('STUDY_INFO_LEGACY_REVIEW_DISABLED');
  }

  Future<void> resetDailyProgress(StudyModel currentStatus) async {
    final expectedUid = _currentUid;
    if (expectedUid == null) return;

    final resetId = _uuid.v4();
    final now = DateTime.now();

    try {
      await _db.transaction(() async {
        _requireCurrentUser(expectedUid);
        final stats = await _db.select(_db.studyStats).getSingleOrNull();
        await _upsertStudyStats(
          current: stats,
          fallback: currentStatus,
          progress: 0,
        );
        await _enqueue(
          ownerUid: expectedUid,
          collection: 'study_progress_reset',
          docId: resetId,
          operationType: 'create',
          payload: {'occurredAt': now.toUtc().toIso8601String()},
        );
        _requireCurrentUser(expectedUid);
      });
      unawaited(syncStudyFromFirebaseToLocal());
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
      final admission = _db.localMutations.capture(expectedUid: expectedUid);
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

      final remoteSubjectDocIds = subjectsSnapshot.docs
          .map((doc) => doc.id)
          .toSet();
      final remoteFlashcardDocIds = flashcardsSnapshot.docs
          .map((doc) => doc.id)
          .toSet();

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
        admission: admission,
        expectedUid: expectedUid,
        pullStartedAt: pullStartedAt,
        remoteStats: remoteStats,
        remoteSubjects: remoteSubjects,
        remoteFlashcards: remoteFlashcards,
        remoteSubjectDocIds: remoteSubjectDocIds,
        remoteFlashcardDocIds: remoteFlashcardDocIds,
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
    required LocalMutationTicket admission,
    required String expectedUid,
    required int pullStartedAt,
    required _RemoteStudyStats? remoteStats,
    required List<_RemoteStudySubject> remoteSubjects,
    required List<_RemoteFlashcard> remoteFlashcards,
    required Set<String> remoteSubjectDocIds,
    required Set<String> remoteFlashcardDocIds,
  }) async {
    await _db.transaction(admission: admission, waitForReopen: false, () async {
      _requireCurrentUser(expectedUid);
      final authoritativeItems =
          await (_db.select(_db.syncQueueTable)..where(
                (item) =>
                    item.ownerUid.equals(expectedUid) &
                    (item.collection.equals('study_info') |
                        item.collection.equals('subjects') |
                        item.collection.equals('review_queue') |
                        item.collection.equals('study_activity') |
                        item.collection.equals('study_progress_reset')) &
                    (item.status.equals(SyncQueuePersistenceStatus.pending) |
                        (item.status.equals(
                              SyncQueuePersistenceStatus.succeeded,
                            ) &
                            item.createdAt.isBiggerOrEqualValue(
                              pullStartedAt,
                            ))),
              ))
              .get();

      // A rejected creation remains unresolved while its original local card
      // exists. Scope by queue owner/family/type/docId, never by e-mail or by
      // inferred remote effects. Resolved/removed local cards do not pin pulls.
      final rejectedCreates =
          await (_db.select(_db.syncQueueTable)..where(
                (item) =>
                    item.ownerUid.equals(expectedUid) &
                    item.collection.equals('review_queue') &
                    item.operationType.equals('create') &
                    item.status.equals(SyncQueuePersistenceStatus.rejected),
              ))
              .get();
      final historicalStudy =
          (await (_db.select(_db.syncQueueTable)..where(
                    (item) =>
                        item.ownerUid.equals(expectedUid) &
                        item.status.equals(SyncQueuePersistenceStatus.rejected),
                  ))
                  .get())
              .where(StudyStateHoldOperation.isHistoricalRejected)
              .toList();
      final rejectedReviews = historicalStudy.where(
        StudyStateHoldOperation.isReview,
      );
      final unresolvedSubjectDeletes =
          [...authoritativeItems, ...historicalStudy]
              .where(StudyStateHoldOperation.isSubjectDelete)
              .map((item) => item.docId.trim())
              .toSet();
      final unresolvedIds = [
        ...rejectedCreates,
        ...rejectedReviews,
      ].map((item) => item.docId).toSet();
      final unresolvedCards = (await _db.select(_db.flashcards).get())
          .where((card) => unresolvedIds.contains(card.id))
          .toList();
      _requireCurrentUser(expectedUid);

      final reviewMutations = [...authoritativeItems, ...rejectedReviews].where(
        (item) =>
            StudyStateHoldOperation.isReview(item) ||
            (item.collection == 'review_queue' &&
                item.operationType == 'create'),
      );
      final studyActivities = authoritativeItems.where(
        (item) =>
            item.collection == 'study_activity' &&
            item.operationType == 'create',
      );
      final progressResets = authoritativeItems.where(
        (item) =>
            item.collection == 'study_progress_reset' &&
            item.operationType == 'create',
      );
      final protectStats =
          authoritativeItems.any(
            (item) => item.collection == 'study_info' && item.docId == 'main',
          ) ||
          reviewMutations.isNotEmpty ||
          unresolvedCards.isNotEmpty ||
          studyActivities.isNotEmpty ||
          progressResets.isNotEmpty ||
          unresolvedSubjectDeletes.isNotEmpty;
      final protectSubjects = authoritativeItems
          .where((item) => item.collection == 'subjects')
          .map((item) => item.docId)
          .toSet();
      for (final item in studyActivities) {
        try {
          final payload = jsonDecode(item.payloadJson);
          final subjectId = payload is Map<String, dynamic>
              ? payload['subjectId']
              : null;
          if (subjectId is String && subjectId.trim().isNotEmpty) {
            protectSubjects.add(subjectId);
          }
        } on FormatException {
          // Stats remain protected even when the subject cannot be identified.
        }
      }
      protectSubjects.addAll(unresolvedCards.map((card) => card.subjectId));
      protectSubjects.addAll(unresolvedSubjectDeletes);
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
      protectCards.addAll(unresolvedCards.map((card) => card.id));
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
        if (protectCards.contains(card.id) ||
            unresolvedSubjectDeletes.contains(card.subjectId))
          continue;
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

      _requireCurrentUser(expectedUid);
      final localFlashcards = await _db.select(_db.flashcards).get();
      _requireCurrentUser(expectedUid);
      for (final card in localFlashcards) {
        if (remoteFlashcardDocIds.contains(card.id) ||
            protectCards.contains(card.id) ||
            unresolvedSubjectDeletes.contains(card.subjectId)) {
          protectSubjects.add(card.subjectId);
          continue;
        }
        _requireCurrentUser(expectedUid);
        await (_db.delete(
          _db.flashcards,
        )..where((table) => table.id.equals(card.id))).go();
        _requireCurrentUser(expectedUid);
      }

      final localSubjects = await _db.select(_db.subjects).get();
      _requireCurrentUser(expectedUid);
      for (final subject in localSubjects) {
        if (remoteSubjectDocIds.contains(subject.id) ||
            protectAllSubjects ||
            protectSubjects.contains(subject.id)) {
          continue;
        }
        _requireCurrentUser(expectedUid);
        await (_db.delete(
          _db.subjects,
        )..where((table) => table.id.equals(subject.id))).go();
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
    final cards = data.containsKey('cardsToReview') ? data['cardsToReview'] : 0;
    final streak = data.containsKey('streakDays') ? data['streakDays'] : 0;
    final progress = data.containsKey('progress') ? data['progress'] : 0.0;
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
