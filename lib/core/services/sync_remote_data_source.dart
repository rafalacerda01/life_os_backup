import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'package:life_os/core/database/app_database.dart';

import 'sync_operation_result.dart';

abstract interface class SyncRemoteDataSource {
  Future<SyncOperationResult> process(String uid, SyncQueueTableData item);
}

typedef SyncAppCheckTokenProvider = Future<String?> Function();

class FirestoreSyncRemoteDataSource implements SyncRemoteDataSource {
  static final RegExp _uuidV4Pattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    caseSensitive: false,
  );

  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;
  final http.Client Function() _clientFactory;
  final Future<String?> Function(User user, bool forceRefresh)?
  _idTokenProvider;
  final SyncAppCheckTokenProvider _appCheckTokenProvider;
  final Duration _requestTimeout;

  FirestoreSyncRemoteDataSource(
    this._firestore,
    this._auth, {
    http.Client Function()? clientFactory,
    Future<String?> Function(User user, bool forceRefresh)? idTokenProvider,
    SyncAppCheckTokenProvider? appCheckTokenProvider,
    Duration requestTimeout = const Duration(seconds: 15),
  }) : _clientFactory = clientFactory ?? http.Client.new,
       // ignore: prefer_initializing_formals
       _idTokenProvider = idTokenProvider,
       _appCheckTokenProvider =
           appCheckTokenProvider ??
           (() => FirebaseAppCheck.instance.getToken()),
       // ignore: prefer_initializing_formals
       _requestTimeout = requestTimeout;

  static const String _backendSyncUrl = String.fromEnvironment(
    'LIFE_OS_SYNC_BACKEND_URL',
    defaultValue: 'https://life-os-backend-gray.vercel.app/api/sync',
  );

  @override
  Future<SyncOperationResult> process(
    String uid,
    SyncQueueTableData item,
  ) async {
    final collection = item.collection.trim();
    final docId = item.docId.trim();
    final operationType = item.operationType.trim().toLowerCase();

    if (collection.isEmpty || docId.isEmpty) {
      return const SyncOperationResult.invalidPayload(
        message: 'Collection ou docId inválidos.',
      );
    }

    if (!{
      'create',
      'update',
      'delete',
      'batch_delete',
    }.contains(operationType)) {
      return const SyncOperationResult.unsupportedOperation(
        message: 'OperationType não suportado.',
      );
    }

    try {
      // ----------------------------------------------------------------------
      // CREATE DE HÁBITO
      // Obrigatoriamente passa pelo backend para enforcement de quota.
      // ----------------------------------------------------------------------
      if (collection == 'habits' && operationType == 'create') {
        return _createHabitServerSide(expectedUid: uid, item: item);
      }

      if (collection == 'habits' && operationType == 'update') {
        return _updateHabitServerSide(expectedUid: uid, item: item);
      }

      if (collection == 'tasks' && operationType == 'create') {
        return _createTaskServerSide(expectedUid: uid, item: item);
      }

      if (collection == 'tasks' && operationType == 'update') {
        return _updateTaskServerSide(expectedUid: uid, item: item);
      }

      if (collection == 'tasks' && operationType == 'delete') {
        return _deleteTaskServerSide(expectedUid: uid, item: item);
      }

      // ----------------------------------------------------------------------
      // CREATE DE GOALS
      // Obrigatoriamente passa pelo backend para enforcement de quota.
      // ----------------------------------------------------------------------

      if (collection == 'goals' && operationType == 'create') {
        return _createGoalServerSide(expectedUid: uid, item: item);
      }

      if (collection == 'goals' && operationType == 'delete') {
        return _deleteGoalServerSide(expectedUid: uid, item: item);
      }

      // ----------------------------------------------------------------------
      // CREATE DE SUBJECTS
      // Obrigatoriamente passa pelo backend para enforcement de quota.
      // ----------------------------------------------------------------------

      if (collection == 'subjects' && operationType == 'create') {
        return _createSubjectServerSide(expectedUid: uid, item: item);
      }

      if (collection == 'subjects' && operationType == 'delete') {
        return _deleteSubjectServerSide(expectedUid: uid, item: item);
      }

      if (collection == 'study_activity' && operationType == 'create') {
        return _applyStudyActivityServerSide(expectedUid: uid, item: item);
      }

      // ----------------------------------------------------------------------
      // CREATE DE MEDICATIONS
      // Obrigatoriamente passa pelo backend para enforcement de quota.
      // ----------------------------------------------------------------------

      if (collection == 'medications' && operationType == 'create') {
        return _createMedicationServerSide(expectedUid: uid, item: item);
      }

      if (collection == 'medications' && operationType == 'delete') {
        return _deleteMedicationServerSide(expectedUid: uid, item: item);
      }

      // ----------------------------------------------------------------------
      // CREATE DE TRANSACTIONS
      // Obrigatoriamente passa pelo backend para enforcement de quota.
      // ----------------------------------------------------------------------

      if (collection == 'transactions' && operationType == 'create') {
        return _createTransactionServerSide(expectedUid: uid, item: item);
      }

      if (collection == 'transactions' && operationType == 'delete') {
        return _deleteTransactionServerSide(expectedUid: uid, item: item);
      }
      // ----------------------------------------------------------------------
      // DELETE DE HÁBITO
      // A operação batch_delete do hábito também passa pelo backend,
      // pois precisa manter habitsCount consistente.
      // ----------------------------------------------------------------------
      if (collection == 'batch' && operationType == 'batch_delete') {
        return _deleteHabitServerSide(expectedUid: uid, item: item);
      }

      // ----------------------------------------------------------------------
      // OPERAÇÕES FIRESTORE NORMAIS
      // Updates competitivos de Task/Habit são tratados acima pelo backend.
      // ----------------------------------------------------------------------
      final documentRef = _firestore
          .collection('users')
          .doc(uid)
          .collection(collection)
          .doc(docId);

      if (collection == 'study_info' &&
          (operationType == 'create' || operationType == 'update')) {
        if (docId != 'main') {
          return const SyncOperationResult.invalidPayload(
            message: 'Documento de informações de estudo inválido.',
          );
        }

        final data = _decodePayload(item.payloadJson);
        await documentRef.set(
          _prepareStudyInfoPayload(data),
          SetOptions(merge: true),
        );
        return const SyncOperationResult.success();
      }

      if (collection == 'review_queue' && operationType == 'create') {
        final data = _decodePayload(item.payloadJson);
        final prepared = _prepareReviewQueueCreatePayload(data);
        final subjectId = prepared['subjectId']! as String;
        final userRef = _firestore.collection('users').doc(uid);
        final subjectRef = userRef.collection('subjects').doc(subjectId);
        final studyInfoRef = userRef.collection('study_info').doc('main');

        await _firestore.runTransaction((transaction) async {
          final cardSnapshot = await transaction.get(documentRef);
          final subjectSnapshot = await transaction.get(subjectRef);

          if (cardSnapshot.exists) return;
          if (!subjectSnapshot.exists) {
            throw const FormatException('Matéria remota não encontrada.');
          }

          transaction.set(documentRef, prepared);
          transaction.set(studyInfoRef, {
            'reviewQueue': FieldValue.increment(1),
          }, SetOptions(merge: true));
          transaction.update(subjectRef, {
            'cardsToReview': FieldValue.increment(1),
          });
        });
        return const SyncOperationResult.success();
      }

      if (collection == 'review_queue' && operationType == 'update') {
        final data = _decodePayload(item.payloadJson);
        final prepared = _prepareReviewQueueUpdatePayload(data);
        final subjectId = prepared['subjectId']! as String;
        final lastReviewed = prepared['lastReviewed']! as Timestamp;
        final userRef = _firestore.collection('users').doc(uid);
        final subjectRef = userRef.collection('subjects').doc(subjectId);
        final studyInfoRef = userRef.collection('study_info').doc('main');

        await _firestore.runTransaction((transaction) async {
          final cardSnapshot = await transaction.get(documentRef);
          final subjectSnapshot = await transaction.get(subjectRef);
          final studyInfoSnapshot = await transaction.get(studyInfoRef);

          final cardData = cardSnapshot.data();
          final subjectData = subjectSnapshot.data();
          final studyInfoData = studyInfoSnapshot.data();
          if (!cardSnapshot.exists || cardData == null) {
            throw const FormatException('Flashcard remoto não encontrado.');
          }
          if (!subjectSnapshot.exists || subjectData == null) {
            throw const FormatException('Matéria remota não encontrada.');
          }
          if (cardData['subjectId'] != subjectId) {
            throw const FormatException('Matéria do flashcard inválida.');
          }

          final currentLastReviewed = cardData['lastReviewed'];
          final currentReviewDate = switch (currentLastReviewed) {
            null => null,
            Timestamp timestamp => timestamp.toDate(),
            DateTime date => date,
            _ => throw const FormatException(
              'Data de revisão remota inválida.',
            ),
          };
          if (currentReviewDate != null &&
              _isSameLocalDay(currentReviewDate, lastReviewed.toDate())) {
            return;
          }

          final currentReviewQueue = studyInfoData?['reviewQueue'];
          final currentProgress = studyInfoData?['progress'];
          final currentCardsToReview = subjectData['cardsToReview'];
          if (currentReviewQueue != null &&
              (currentReviewQueue is! int || currentReviewQueue < 0)) {
            throw const FormatException('Fila de revisão remota inválida.');
          }
          if (currentProgress != null && !_isFiniteProgress(currentProgress)) {
            throw const FormatException('Progresso remoto inválido.');
          }
          if (currentCardsToReview is! int || currentCardsToReview < 0) {
            throw const FormatException('Contador remoto da matéria inválido.');
          }

          final newReviewQueue = ((currentReviewQueue as int? ?? 0) - 1)
              .clamp(0, 1 << 31)
              .toInt();
          final newCardsToReview = (currentCardsToReview - 1)
              .clamp(0, 1 << 31)
              .toInt();
          final newProgress = ((currentProgress as num? ?? 0).toDouble() + 0.05)
              .clamp(0.0, 1.0)
              .toDouble();

          transaction.update(documentRef, {'lastReviewed': lastReviewed});
          transaction.set(studyInfoRef, {
            'reviewQueue': newReviewQueue,
            'progress': newProgress,
            'lastStudyDate': lastReviewed,
          }, SetOptions(merge: true));
          transaction.update(subjectRef, {'cardsToReview': newCardsToReview});
        });
        return const SyncOperationResult.success();
      }

      switch (operationType) {
        case 'create':
        case 'update':
          final data = _decodePayload(item.payloadJson);

          if (collection == 'health_info') {
            await documentRef.set(
              _prepareHealthPayload(data),
              SetOptions(merge: true),
            );
            return const SyncOperationResult.success();
          }

          if (operationType == 'create') {
            await documentRef.set(data);
          } else {
            await documentRef.update(
              collection == 'goals' ? _prepareGoalUpdatePayload(data) : data,
            );
          }

          return const SyncOperationResult.success();

        case 'delete':
          await documentRef.delete();

          return const SyncOperationResult.success();

        case 'batch_delete':
          return const SyncOperationResult.unsupportedOperation(
            message: 'batch_delete não suportado para esta coleção.',
          );
      }

      return const SyncOperationResult.unsupportedOperation(
        message: 'OperationType não suportado.',
      );
    } on FirebaseException catch (error) {
      if (collection == 'health_info' &&
          (error.code == 'permission-denied' ||
              error.code == 'unauthenticated')) {
        return SyncOperationResult.retryable(code: error.code.toUpperCase());
      }

      if (operationType == 'update' && error.code == 'not-found') {
        return SyncOperationResult.invalidPayload(
          message:
              'FIRESTORE_NOT_FOUND: '
              '${error.message ?? 'Documento não encontrado para atualização.'}',
        );
      }

      return _mapFirebaseError(error);
    } on FormatException catch (error) {
      return SyncOperationResult.invalidPayload(message: error.message);
    } catch (error) {
      return SyncOperationResult.retryable(
        message: error.toString(),
        code: 'UNEXPECTED_SYNC_ERROR',
      );
    }
  }

  Map<String, dynamic> _prepareStudyInfoPayload(Map<String, dynamic> data) {
    const allowedFields = {
      'reviewQueue',
      'progress',
      'streak',
      'lastStudyDate',
    };
    if (data.isEmpty || data.keys.any((key) => !allowedFields.contains(key))) {
      throw const FormatException('Payload de informações de estudo inválido.');
    }

    final prepared = Map<String, dynamic>.from(data);
    if (data.containsKey('reviewQueue')) {
      final reviewQueue = data['reviewQueue'];
      if (reviewQueue is! int || reviewQueue < 0) {
        throw const FormatException('Fila de revisão inválida.');
      }
    }

    if (data.containsKey('progress')) {
      final progress = data['progress'];
      final value = progress is num ? progress.toDouble() : double.nan;
      if (!value.isFinite || value < 0 || value > 1) {
        throw const FormatException('Progresso de estudo inválido.');
      }
      prepared['progress'] = value;
    }

    if (data.containsKey('streak')) {
      final streak = data['streak'];
      if (streak is! int || streak < 0) {
        throw const FormatException('Sequência de estudo inválida.');
      }
    }

    if (data.containsKey('lastStudyDate')) {
      prepared['lastStudyDate'] = _parseQueuedTimestamp(
        data['lastStudyDate'],
        fieldName: 'Data de estudo',
      );
    }

    return prepared;
  }

  Map<String, dynamic> _prepareReviewQueueCreatePayload(
    Map<String, dynamic> data,
  ) {
    const fields = {'subjectId', 'question', 'answer', 'createdAt'};
    if (!_hasExactFields(data, fields)) {
      throw const FormatException('Payload de criação de flashcard inválido.');
    }

    for (final field in const ['subjectId', 'question', 'answer']) {
      final value = data[field];
      if (value is! String || value.trim().isEmpty) {
        throw const FormatException('Conteúdo do flashcard inválido.');
      }
    }

    return {
      'subjectId': data['subjectId'],
      'question': data['question'],
      'answer': data['answer'],
      'createdAt': _parseQueuedTimestamp(
        data['createdAt'],
        fieldName: 'Data de criação',
      ),
    };
  }

  Map<String, dynamic> _prepareReviewQueueUpdatePayload(
    Map<String, dynamic> data,
  ) {
    if (!_hasExactFields(data, const {'subjectId', 'lastReviewed'})) {
      throw const FormatException(
        'Payload de atualização de flashcard inválido.',
      );
    }

    final subjectId = data['subjectId'];
    if (subjectId is! String || subjectId.trim().isEmpty) {
      throw const FormatException('Matéria do flashcard inválida.');
    }

    return {
      'subjectId': subjectId,
      'lastReviewed': _parseQueuedTimestamp(
        data['lastReviewed'],
        fieldName: 'Data de revisão',
      ),
    };
  }

  bool _hasExactFields(Map<String, dynamic> data, Set<String> fields) {
    return data.length == fields.length && data.keys.every(fields.contains);
  }

  bool _isFiniteProgress(Object? value) {
    if (value is! num) return false;
    final progress = value.toDouble();
    return progress.isFinite && progress >= 0 && progress <= 1;
  }

  bool _isSameLocalDay(DateTime first, DateTime second) {
    final firstLocal = first.toLocal();
    final secondLocal = second.toLocal();
    return firstLocal.year == secondLocal.year &&
        firstLocal.month == secondLocal.month &&
        firstLocal.day == secondLocal.day;
  }

  Timestamp _parseQueuedTimestamp(Object? value, {required String fieldName}) {
    final parsed = value is String ? DateTime.tryParse(value) : null;
    if (parsed == null) {
      throw FormatException('$fieldName inválida.');
    }
    return Timestamp.fromDate(parsed);
  }

  Map<String, dynamic> _prepareGoalUpdatePayload(Map<String, dynamic> data) {
    if (data.isEmpty ||
        data.keys.any((key) => key != 'currentValue' && key != 'lastReset')) {
      throw const FormatException('Payload de atualização de meta inválido.');
    }

    final currentValue = data['currentValue'];
    if (data.containsKey('currentValue') && currentValue is! int) {
      throw const FormatException('Progresso da meta inválido.');
    }

    final prepared = Map<String, dynamic>.from(data);
    if (data.containsKey('lastReset')) {
      final rawLastReset = data['lastReset'];
      final parsedLastReset = rawLastReset is String
          ? DateTime.tryParse(rawLastReset)
          : null;
      if (parsedLastReset == null) {
        throw const FormatException('Data de reset da meta inválida.');
      }
      prepared['lastReset'] = Timestamp.fromDate(parsedLastReset);
    }

    return prepared;
  }

  Future<SyncOperationResult> _createTransactionServerSide({
    required String expectedUid,
    required SyncQueueTableData item,
  }) async {
    final data = _decodePayload(item.payloadJson);

    final title = data['title'];
    final amount = data['amount'];
    final type = data['type'];
    final category = data['category'];
    final date = data['date'];

    if (title is! String ||
        amount is! num ||
        type is! String ||
        category is! String ||
        date is! String) {
      return const SyncOperationResult.invalidPayload(
        message: 'Payload de criação de transação inválido.',
      );
    }

    return _postToSyncBackend(expectedUid, {
      'operation': 'create_transaction',
      'transactionId': item.docId,
      'title': title,
      'amount': amount.toDouble(),
      'type': type,
      'category': category,
      'date': date,
    });
  }

  Future<SyncOperationResult> _deleteTransactionServerSide({
    required String expectedUid,
    required SyncQueueTableData item,
  }) async {
    return _postToSyncBackend(expectedUid, {
      'operation': 'delete_transaction',
      'transactionId': item.docId,
    });
  }

  Future<SyncOperationResult> _createMedicationServerSide({
    required String expectedUid,
    required SyncQueueTableData item,
  }) async {
    final data = _decodePayload(item.payloadJson);

    final name = data['name'];
    final startDate = data['startDate'];
    final durationDays = data['durationDays'];
    final endDate = data['endDate'];

    if (name is! String ||
        startDate is! String ||
        (durationDays != null && durationDays is! int) ||
        (endDate != null && endDate is! String)) {
      return const SyncOperationResult.invalidPayload(
        message: 'Payload de criação de medicamento inválido.',
      );
    }

    return _postToSyncBackend(expectedUid, {
      'operation': 'create_medication',
      'medicationId': item.docId,
      'name': name,
      'startDate': startDate,
      'durationDays': durationDays,
      'endDate': endDate,
    });
  }

  Future<SyncOperationResult> _deleteMedicationServerSide({
    required String expectedUid,
    required SyncQueueTableData item,
  }) async {
    return _postToSyncBackend(expectedUid, {
      'operation': 'delete_medication',
      'medicationId': item.docId,
    });
  }

  Future<SyncOperationResult> _createSubjectServerSide({
    required String expectedUid,
    required SyncQueueTableData item,
  }) async {
    final data = _decodePayload(item.payloadJson);

    final title = data['title'];
    final hasExam = data['hasExam'];
    final examDate = data['examDate'];

    if (title is! String ||
        hasExam is! bool ||
        (examDate != null && examDate is! String)) {
      return const SyncOperationResult.invalidPayload(
        message: 'Payload de criação de matéria inválido.',
      );
    }

    return _postToSyncBackend(expectedUid, {
      'operation': 'create_subject',
      'subjectId': item.docId,
      'title': title,
      'hasExam': hasExam,
      'examDate': examDate,
    });
  }

  Future<SyncOperationResult> _deleteSubjectServerSide({
    required String expectedUid,
    required SyncQueueTableData item,
  }) async {
    return _postToSyncBackend(expectedUid, {
      'operation': 'delete_subject',
      'subjectId': item.docId,
    });
  }

  Future<SyncOperationResult> _applyStudyActivityServerSide({
    required String expectedUid,
    required SyncQueueTableData item,
  }) async {
    final data = _decodePayload(item.payloadJson);
    if (!_uuidV4Pattern.hasMatch(item.docId) ||
        !_hasExactFields(data, const {
          'subjectId',
          'progressDelta',
          'occurredAt',
          'timeZoneOffsetMinutes',
        })) {
      return const SyncOperationResult.invalidPayload(
        message: 'Payload de atividade de estudo inválido.',
      );
    }

    final subjectId = data['subjectId'];
    final progressDelta = data['progressDelta'];
    final occurredAt = data['occurredAt'];
    final timeZoneOffsetMinutes = data['timeZoneOffsetMinutes'];
    final parsedOccurredAt = occurredAt is String
        ? DateTime.tryParse(occurredAt)
        : null;
    final delta = progressDelta is num ? progressDelta.toDouble() : double.nan;

    if ((subjectId != null &&
            (subjectId is! String ||
                subjectId.trim().isEmpty ||
                subjectId.length > 128 ||
                subjectId.contains('/'))) ||
        !delta.isFinite ||
        delta <= 0 ||
        delta > 1 ||
        parsedOccurredAt == null ||
        timeZoneOffsetMinutes is! int ||
        timeZoneOffsetMinutes < -840 ||
        timeZoneOffsetMinutes > 840) {
      return const SyncOperationResult.invalidPayload(
        message: 'Payload de atividade de estudo inválido.',
      );
    }

    return _postToSyncBackend(expectedUid, {
      'operation': 'apply_study_activity',
      'mutationId': item.docId,
      'subjectId': subjectId,
      'progressDelta': delta,
      'occurredAt': occurredAt,
      'timeZoneOffsetMinutes': timeZoneOffsetMinutes,
    });
  }

  Future<SyncOperationResult> _createGoalServerSide({
    required String expectedUid,
    required SyncQueueTableData item,
  }) async {
    final data = _decodePayload(item.payloadJson);

    final title = data['title'];
    final period = data['period'];
    final targetValue = data['targetValue'];
    final createdAt = data['createdAt'];

    if (title is! String ||
        period is! String ||
        targetValue is! int ||
        createdAt is! String) {
      return const SyncOperationResult.invalidPayload(
        message: 'Payload de criação de meta inválido.',
      );
    }

    return _postToSyncBackend(expectedUid, {
      'operation': 'create_goal',
      'goalId': item.docId,
      'title': title,
      'period': period,
      'targetValue': targetValue,
      'createdAt': createdAt,
    });
  }

  Future<SyncOperationResult> _deleteGoalServerSide({
    required String expectedUid,
    required SyncQueueTableData item,
  }) async {
    return _postToSyncBackend(expectedUid, {
      'operation': 'delete_goal',
      'goalId': item.docId,
    });
  }

  Future<SyncOperationResult> _createTaskServerSide({
    required String expectedUid,
    required SyncQueueTableData item,
  }) async {
    final data = _decodePayload(item.payloadJson);

    final title = data['title'];
    final priority = data['priority'];
    final date = data['date'];

    if (title is! String || priority is! String || date is! String) {
      return const SyncOperationResult.invalidPayload(
        message: 'Payload de criação de tarefa inválido.',
      );
    }

    return _postToSyncBackend(expectedUid, {
      'operation': 'create_task',
      'taskId': item.docId,
      'title': title,
      'priority': priority,
      'date': date,
    });
  }

  Future<SyncOperationResult> _updateTaskServerSide({
    required String expectedUid,
    required SyncQueueTableData item,
  }) async {
    final data = _decodePayload(item.payloadJson);
    final isCompleted = data['isCompleted'];

    if (data.length != 1 || isCompleted is! bool) {
      return const SyncOperationResult.invalidPayload(
        message: 'Payload de atualização de tarefa inválido.',
      );
    }

    return _postToSyncBackend(expectedUid, {
      'operation': 'update_task',
      'taskId': item.docId,
      'isCompleted': isCompleted,
    });
  }

  Future<SyncOperationResult> _deleteTaskServerSide({
    required String expectedUid,
    required SyncQueueTableData item,
  }) async {
    return _postToSyncBackend(expectedUid, {
      'operation': 'delete_task',
      'taskId': item.docId,
    });
  }

  Future<SyncOperationResult> _createHabitServerSide({
    required String expectedUid,
    required SyncQueueTableData item,
  }) async {
    final data = _decodePayload(item.payloadJson);

    final title = data['title'];
    final completedDates = data['completedDates'];

    if (title is! String || completedDates is! List) {
      return const SyncOperationResult.invalidPayload(
        message: 'Payload de criação de hábito inválido.',
      );
    }

    return _postToSyncBackend(expectedUid, {
      'operation': 'create_habit',
      'habitId': item.docId,
      'title': title,
      'completedDates': completedDates,
    });
  }

  Future<SyncOperationResult> _updateHabitServerSide({
    required String expectedUid,
    required SyncQueueTableData item,
  }) async {
    final data = _decodePayload(item.payloadJson);
    final completedDates = data['completedDates'];
    final competitiveCompletionId = data['competitiveCompletionId'];

    if (completedDates is! List ||
        !completedDates.every((date) => date is String)) {
      return const SyncOperationResult.invalidPayload(
        message: 'Payload de atualização de hábito inválido.',
      );
    }

    if (competitiveCompletionId != null) {
      if (data.length != 2 ||
          competitiveCompletionId is! String ||
          !_uuidV4Pattern.hasMatch(competitiveCompletionId)) {
        return const SyncOperationResult.invalidPayload(
          message: 'Payload de conclusão competitiva inválido.',
        );
      }

      return _postToSyncBackend(expectedUid, {
        'operation': 'update_habit_completion',
        'habitId': item.docId,
        'completedDates': completedDates,
        'competitiveCompletionId': competitiveCompletionId,
      });
    }

    if (data.length != 1) {
      return const SyncOperationResult.invalidPayload(
        message: 'Payload de atualização de hábito inválido.',
      );
    }

    return _postToSyncBackend(expectedUid, {
      'operation': 'update_habit',
      'habitId': item.docId,
      'completedDates': completedDates,
    });
  }

  Future<SyncOperationResult> _deleteHabitServerSide({
    required String expectedUid,
    required SyncQueueTableData item,
  }) async {
    final data = _decodePayload(item.payloadJson);
    final deletes = data['deletes'];

    if (deletes is! List || deletes.isEmpty) {
      return const SyncOperationResult.invalidPayload(
        message: 'Payload de exclusão de hábito inválido.',
      );
    }

    final hasHabitDelete = deletes.any(
      (entry) =>
          entry is Map &&
          entry['collection'] == 'habits' &&
          entry['docId'] == item.docId,
    );

    if (!hasHabitDelete) {
      return const SyncOperationResult.invalidPayload(
        message: 'Payload não contém a exclusão do hábito esperado.',
      );
    }

    return _postToSyncBackend(expectedUid, {
      'operation': 'delete_habit',
      'habitId': item.docId,
    });
  }

  Future<SyncOperationResult> _postToSyncBackend(
    String expectedUid,
    Map<String, dynamic> payload,
  ) async {
    final token = await _getIdToken(
      expectedUid: expectedUid,
      forceRefresh: false,
    );

    if (token == null || token.trim().isEmpty) {
      return const SyncOperationResult.retryable(
        code: 'AUTHENTICATION_REQUIRED',
      );
    }

    String? rawAppCheckToken;
    try {
      rawAppCheckToken = await _appCheckTokenProvider();
    } catch (_) {
      return const SyncOperationResult.retryable(code: 'APP_CHECK_REQUIRED');
    }

    final appCheckToken = rawAppCheckToken?.trim();
    if (appCheckToken == null || appCheckToken.isEmpty) {
      return const SyncOperationResult.retryable(code: 'APP_CHECK_REQUIRED');
    }

    final client = _clientFactory();

    try {
      Future<http.Response> send(String idToken) {
        return client
            .post(
              Uri.parse(_backendSyncUrl),
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $idToken',
                'X-Firebase-AppCheck': appCheckToken,
              },
              body: jsonEncode(payload),
            )
            .timeout(_requestTimeout);
      }

      var response = await send(token);

      if (response.statusCode == 401) {
        final backendCode = _extractBackendCode(response.body);
        if (_isAppCheckCode(backendCode)) {
          return SyncOperationResult.retryable(code: backendCode);
        }

        final refreshedToken = await _getIdToken(
          expectedUid: expectedUid,
          forceRefresh: true,
        );

        if (refreshedToken == null || refreshedToken.trim().isEmpty) {
          return const SyncOperationResult.retryable(
            code: 'AUTHENTICATION_REQUIRED',
          );
        }

        response = await send(refreshedToken);
      }

      if (response.statusCode >= 200 && response.statusCode < 300) {
        return const SyncOperationResult.success();
      }

      if (response.statusCode == 401) {
        final backendCode = _extractBackendCode(response.body);
        if (_isAppCheckCode(backendCode)) {
          return SyncOperationResult.retryable(code: backendCode);
        }

        return const SyncOperationResult.retryable(
          code: 'AUTHENTICATION_REQUIRED',
        );
      }

      if (response.statusCode == 403) {
        final backendCode = _extractBackendCode(response.body);

        if (_isQuotaExceededCode(backendCode)) {
          return const SyncOperationResult.quotaExceeded();
        }

        return SyncOperationResult.permissionDenied();
      }

      if (response.statusCode == 400) {
        return SyncOperationResult.invalidPayload(
          message: _extractBackendMessage(response.body),
        );
      }

      if (response.statusCode == 404) {
        return SyncOperationResult.retryable(
          message: _extractBackendMessage(response.body),
          code: _extractBackendCode(response.body) ?? 'BACKEND_404',
        );
      }

      if (response.statusCode == 409) {
        final backendCode = _extractBackendCode(response.body);
        final backendMessage = _extractBackendMessage(response.body);

        return SyncOperationResult.invalidPayload(
          message: backendCode == null
              ? backendMessage
              : '$backendCode: $backendMessage',
        );
      }

      if (response.statusCode == 412) {
        final backendCode = _extractBackendCode(response.body);

        if (_isMigrationRequiredCode(backendCode)) {
          return SyncOperationResult.retryable(
            message: _extractBackendMessage(response.body),
            code: backendCode,
          );
        }

        return SyncOperationResult.invalidPayload(
          message: _extractBackendMessage(response.body),
        );
      }

      if (response.statusCode == 429 || response.statusCode >= 500) {
        return SyncOperationResult.retryable(
          message: _extractBackendMessage(response.body),
          code: 'BACKEND_${response.statusCode}',
        );
      }

      return SyncOperationResult.retryable(
        message: _extractBackendMessage(response.body),
        code: 'BACKEND_${response.statusCode}',
      );
    } on http.ClientException catch (error) {
      return SyncOperationResult.retryable(
        message: error.message,
        code: 'NETWORK_ERROR',
      );
    } on TimeoutException {
      return const SyncOperationResult.retryable(code: 'SYNC_TIMEOUT');
    } finally {
      client.close();
    }
  }

  Future<String?> _getIdToken({
    required String expectedUid,
    required bool forceRefresh,
  }) async {
    final user = _auth.currentUser;

    if (user == null || user.uid != expectedUid) {
      return null;
    }

    final provider = _idTokenProvider;

    if (provider != null) {
      return provider(user, forceRefresh);
    }

    return user.getIdToken(forceRefresh);
  }

  String _extractBackendMessage(String body) {
    try {
      final decoded = jsonDecode(body);

      if (decoded is Map && decoded['error'] is String) {
        return decoded['error'] as String;
      }
    } catch (_) {
      // Usa o fallback abaixo.
    }

    return 'Falha na sincronização server-side.';
  }

  String? _extractBackendCode(String body) {
    try {
      final decoded = jsonDecode(body);

      if (decoded is Map) {
        final code = decoded['code'];

        if (code is String && code.trim().isNotEmpty) {
          return code.trim();
        }
      }
    } catch (_) {
      // Usa o fallback abaixo.
    }

    return null;
  }

  bool _isAppCheckCode(String? code) {
    return code == 'APP_CHECK_REQUIRED' || code == 'APP_CHECK_INVALID';
  }

  bool _isQuotaExceededCode(String? code) {
    if (code == null) {
      return false;
    }

    return RegExp(r'^[A-Z][A-Z0-9_]*_QUOTA_EXCEEDED$').hasMatch(code);
  }

  bool _isMigrationRequiredCode(String? code) {
    if (code == null) {
      return false;
    }

    return RegExp(r'^[A-Z][A-Z0-9_]*_MIGRATION_REQUIRED$').hasMatch(code);
  }

  Map<String, dynamic> _decodePayload(String payloadJson) {
    final decoded = jsonDecode(payloadJson);

    if (decoded is! Map) {
      throw const FormatException(
        'Payload de sincronização deve ser um objeto JSON.',
      );
    }

    return Map<String, dynamic>.from(decoded);
  }

  Map<String, dynamic> _prepareHealthPayload(Map<String, dynamic> payload) {
    final data = Map<String, dynamic>.from(payload);
    final rawDate = data['date'];

    if (rawDate == null || rawDate is Timestamp) {
      return data;
    }

    if (rawDate is String) {
      final parsedDate = DateTime.tryParse(rawDate);

      if (parsedDate != null) {
        data['date'] = Timestamp.fromDate(parsedDate);
        return data;
      }
    }

    throw const FormatException('Data de saúde inválida.');
  }

  SyncOperationResult _mapFirebaseError(FirebaseException error) {
    switch (error.code) {
      case 'permission-denied':
        return const SyncOperationResult.permissionDenied();

      case 'unauthenticated':
        return const SyncOperationResult.retryable(
          code: 'AUTHENTICATION_REQUIRED',
        );

      case 'invalid-argument':
      case 'failed-precondition':
        return const SyncOperationResult.invalidPayload();

      case 'unavailable':
      case 'deadline-exceeded':
      case 'aborted':
      case 'internal':
        return SyncOperationResult.retryable(
          message: error.message,
          code: error.code.toUpperCase(),
        );

      default:
        return SyncOperationResult.retryable(
          message: error.message,
          code: error.code.toUpperCase(),
        );
    }
  }
}
