import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'package:life_os/core/database/app_database.dart';

import 'sync_operation_result.dart';

abstract interface class SyncRemoteDataSource {
  Future<SyncOperationResult> process(String uid, SyncQueueTableData item);
}

class FirestoreSyncRemoteDataSource implements SyncRemoteDataSource {
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  const FirestoreSyncRemoteDataSource(this._firestore, this._auth);

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
        return _createHabitServerSide(item: item);
      }

      if (collection == 'tasks' && operationType == 'create') {
        return _createTaskServerSide(item: item);
      }

      if (collection == 'tasks' && operationType == 'delete') {
        return _deleteTaskServerSide(item: item);
      }

      // ----------------------------------------------------------------------
      // CREATE DE GOALS
      // Obrigatoriamente passa pelo backend para enforcement de quota.
      // ----------------------------------------------------------------------

      if (collection == 'goals' && operationType == 'create') {
        return _createGoalServerSide(item: item);
      }

      if (collection == 'goals' && operationType == 'delete') {
        return _deleteGoalServerSide(item: item);
      }

      // ----------------------------------------------------------------------
      // CREATE DE SUBJECTS
      // Obrigatoriamente passa pelo backend para enforcement de quota.
      // ----------------------------------------------------------------------

      if (collection == 'subjects' && operationType == 'create') {
        return _createSubjectServerSide(item: item);
      }

      if (collection == 'subjects' && operationType == 'delete') {
        return _deleteSubjectServerSide(item: item);
      }

      // ----------------------------------------------------------------------
      // CREATE DE MEDICATIONS
      // Obrigatoriamente passa pelo backend para enforcement de quota.
      // ----------------------------------------------------------------------

      if (collection == 'medications' && operationType == 'create') {
        return _createMedicationServerSide(item: item);
      }

      if (collection == 'medications' && operationType == 'delete') {
        return _deleteMedicationServerSide(item: item);
      }

      // ----------------------------------------------------------------------
      // CREATE DE TRANSACTIONS
      // Obrigatoriamente passa pelo backend para enforcement de quota.
      // ----------------------------------------------------------------------

      if (collection == 'transactions' && operationType == 'create') {
        return _createTransactionServerSide(item: item);
      }

      if (collection == 'transactions' && operationType == 'delete') {
        return _deleteTransactionServerSide(item: item);
      }
      // ----------------------------------------------------------------------
      // DELETE DE HÁBITO
      // A operação batch_delete do hábito também passa pelo backend,
      // pois precisa manter habitsCount consistente.
      // ----------------------------------------------------------------------
      if (collection == 'batch' && operationType == 'batch_delete') {
        return _deleteHabitServerSide(item: item);
      }

      // ----------------------------------------------------------------------
      // OPERAÇÕES FIRESTORE NORMAIS
      // UPDATE de hábito continua permitido pelas Rules.
      // ----------------------------------------------------------------------
      final documentRef = _firestore
          .collection('users')
          .doc(uid)
          .collection(collection)
          .doc(docId);

      switch (operationType) {
        case 'create':
          final data = _decodePayload(item.payloadJson);

          await documentRef.set(data);

          return const SyncOperationResult.success();

        case 'update':
          final data = _decodePayload(item.payloadJson);

          await documentRef.set(data, SetOptions(merge: true));

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

  Future<SyncOperationResult> _createTransactionServerSide({
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

    return _postToSyncBackend({
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
    required SyncQueueTableData item,
  }) async {
    return _postToSyncBackend({
      'operation': 'delete_transaction',
      'transactionId': item.docId,
    });
  }

  Future<SyncOperationResult> _createMedicationServerSide({
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

    return _postToSyncBackend({
      'operation': 'create_medication',
      'medicationId': item.docId,
      'name': name,
      'startDate': startDate,
      'durationDays': durationDays,
      'endDate': endDate,
    });
  }

  Future<SyncOperationResult> _deleteMedicationServerSide({
    required SyncQueueTableData item,
  }) async {
    return _postToSyncBackend({
      'operation': 'delete_medication',
      'medicationId': item.docId,
    });
  }

  Future<SyncOperationResult> _createSubjectServerSide({
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

    return _postToSyncBackend({
      'operation': 'create_subject',
      'subjectId': item.docId,
      'title': title,
      'hasExam': hasExam,
      'examDate': examDate,
    });
  }

  Future<SyncOperationResult> _deleteSubjectServerSide({
    required SyncQueueTableData item,
  }) async {
    return _postToSyncBackend({
      'operation': 'delete_subject',
      'subjectId': item.docId,
    });
  }

  Future<SyncOperationResult> _createGoalServerSide({
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

    return _postToSyncBackend({
      'operation': 'create_goal',
      'goalId': item.docId,
      'title': title,
      'period': period,
      'targetValue': targetValue,
      'createdAt': createdAt,
    });
  }

  Future<SyncOperationResult> _deleteGoalServerSide({
    required SyncQueueTableData item,
  }) async {
    return _postToSyncBackend({
      'operation': 'delete_goal',
      'goalId': item.docId,
    });
  }

  Future<SyncOperationResult> _createTaskServerSide({
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

    return _postToSyncBackend({
      'operation': 'create_task',
      'taskId': item.docId,
      'title': title,
      'priority': priority,
      'date': date,
    });
  }

  Future<SyncOperationResult> _deleteTaskServerSide({
    required SyncQueueTableData item,
  }) async {
    return _postToSyncBackend({
      'operation': 'delete_task',
      'taskId': item.docId,
    });
  }

  Future<SyncOperationResult> _createHabitServerSide({
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

    return _postToSyncBackend({
      'operation': 'create_habit',
      'habitId': item.docId,
      'title': title,
      'completedDates': completedDates,
    });
  }

  Future<SyncOperationResult> _deleteHabitServerSide({
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

    return _postToSyncBackend({
      'operation': 'delete_habit',
      'habitId': item.docId,
    });
  }

  Future<SyncOperationResult> _postToSyncBackend(
    Map<String, dynamic> payload,
  ) async {
    final user = _auth.currentUser;

    if (user == null) {
      return const SyncOperationResult.permissionDenied();
    }

    final token = await user.getIdToken();

    if (token == null || token.trim().isEmpty) {
      return const SyncOperationResult.permissionDenied();
    }

    final client = http.Client();

    try {
      final response = await client.post(
        Uri.parse(_backendSyncUrl),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode(payload),
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        return const SyncOperationResult.success();
      }

      if (response.statusCode == 401) {
        return const SyncOperationResult.permissionDenied();
      }

      if (response.statusCode == 403) {
        return SyncOperationResult.invalidPayload(
          message: _extractBackendMessage(response.body),
        );
      }

      if (response.statusCode == 400 || response.statusCode == 412) {
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
    } finally {
      client.close();
    }
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

  Map<String, dynamic> _decodePayload(String payloadJson) {
    final decoded = jsonDecode(payloadJson);

    if (decoded is! Map) {
      throw const FormatException(
        'Payload de sincronização deve ser um objeto JSON.',
      );
    }

    return Map<String, dynamic>.from(decoded);
  }

  SyncOperationResult _mapFirebaseError(FirebaseException error) {
    switch (error.code) {
      case 'permission-denied':
      case 'unauthenticated':
        return const SyncOperationResult.permissionDenied();

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
