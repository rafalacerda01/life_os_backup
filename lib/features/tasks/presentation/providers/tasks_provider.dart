import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:drift/drift.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/database_provider.dart';
import 'package:life_os/core/network/activity_remote_data_source.dart';
import 'package:life_os/core/utils/app_logger.dart';
import 'package:life_os/features/tasks/data/models/task_model.dart';

// ============================================================================
// REPOSITORY PROVIDER
// ============================================================================

final tasksRepositoryProvider = Provider((ref) {
  final db = ref.watch(databaseProvider);
  final activityRemote = ref.watch(activityRemoteDataSourceProvider);

  return TasksRepository(
    db,
    FirebaseFirestore.instance,
    FirebaseAuth.instance,
    activityRemote,
  );
});

// ============================================================================
// STREAM PROVIDER
// ============================================================================

final tasksStreamProvider = StreamProvider<List<TaskModel>>((ref) {
  final repository = ref.watch(tasksRepositoryProvider);

  return repository.getTasksStream();
});

// ============================================================================
// REPOSITORY
// ============================================================================

class TasksRepository {
  final AppDatabase _db;
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;
  final ActivityRemoteDataSource _activityRemote;

  TasksRepository(this._db, this._firestore, this._auth, this._activityRemote);

  // ==========================================================================
  // LEITURA LOCAL
  // ==========================================================================

  Stream<List<TaskModel>> getTasksStream() {
    return _db.select(_db.taskTable).watch().map((rows) {
      return rows
          .map(
            (row) => TaskModel(
              id: row.id,
              title: row.title,
              priority: row.priority,
              isCompleted: row.isCompleted,
              date: row.date,
            ),
          )
          .toList();
    });
  }

  // ==========================================================================
  // SYNC-DOWN FIREBASE -> LOCAL
  // ==========================================================================

  Future<void> syncTasksFromFirebaseToLocal() async {
    final user = _auth.currentUser;

    if (user == null) {
      return;
    }

    try {
      final snapshot = await _firestore
          .collection('users')
          .doc(user.uid)
          .collection('tasks')
          .get();

      for (final doc in snapshot.docs) {
        final data = doc.data();

        await _db
            .into(_db.taskTable)
            .insertOnConflictUpdate(
              TaskTableCompanion.insert(
                id: doc.id,
                title: data['title'] ?? '',
                priority: data['priority'] ?? 'medium',
                isCompleted: Value(data['isCompleted'] ?? false),
                date: data['date'] != null
                    ? (data['date'] as Timestamp).toDate()
                    : DateTime.now(),
              ),
            );
      }
    } catch (e, stack) {
      AppLogger.e('Erro ao sincronizar tarefas', e, stack);
    }
  }

  // ==========================================================================
  // CRIAR TAREFA
  // ==========================================================================

  Future<void> addTask(String title, String priority) async {
    final user = _auth.currentUser;

    if (user == null) {
      throw Exception('Usuário não autenticado');
    }

    final id = DateTime.now().millisecondsSinceEpoch.toString();

    final createdAt = DateTime.now();

    try {
      await _db.transactionWithSync(
        ownerUid: user.uid,
        localOperation: () async {
          await _db
              .into(_db.taskTable)
              .insert(
                TaskTableCompanion.insert(
                  id: id,
                  title: title,
                  priority: priority,
                  isCompleted: const Value(false),
                  date: createdAt,
                ),
              );
        },
        collection: 'tasks',
        docId: id,
        operationType: 'create',
        payloadJson: jsonEncode({
          'title': title,
          'priority': priority,
          'isCompleted': false,
          'date': createdAt.toIso8601String(),
        }),
      );
    } catch (e, stack) {
      AppLogger.e('Erro ao criar tarefa localmente', e, stack);

      rethrow;
    }
  }

  // ==========================================================================
  // ALTERAR STATUS
  // ==========================================================================

  Future<void> toggleTaskStatus(String taskId, bool currentStatus) async {
    final user = _auth.currentUser;

    if (user == null) {
      return;
    }

    final newStatus = !currentStatus;

    try {
      await _db.transactionWithSync(
        ownerUid: user.uid,
        localOperation: () async {
          await (_db.update(_db.taskTable)
                ..where((table) => table.id.equals(taskId)))
              .write(TaskTableCompanion(isCompleted: Value(newStatus)));
        },
        collection: 'tasks',
        docId: taskId,
        operationType: 'update',
        payloadJson: jsonEncode({'isCompleted': newStatus}),
      );

      if (newStatus) {
        unawaited(_reportCompetitiveCompletion(taskId));
      }
    } catch (e, stack) {
      AppLogger.e('Erro ao atualizar tarefa localmente', e, stack);

      rethrow;
    }
  }

  Future<void> _reportCompetitiveCompletion(String taskId) async {
    try {
      await _activityRemote.completeTask(taskId: taskId);
    } on ActivityRemoteException catch (error) {
      AppLogger.w(
        'Atividade competitiva de tarefa nao registrada '
        '(status: ${error.statusCode ?? 'network'}, code: ${error.code}).',
      );
    } catch (_) {
      AppLogger.w('Atividade competitiva de tarefa nao registrada.');
    }
  }

  // ==========================================================================
  // EXCLUIR TAREFA
  // ==========================================================================

  Future<void> deleteTask(String taskId) async {
    final user = _auth.currentUser;

    if (user == null) {
      return;
    }

    try {
      await _db.transactionWithSync(
        ownerUid: user.uid,
        localOperation: () async {
          await (_db.delete(
            _db.taskTable,
          )..where((table) => table.id.equals(taskId))).go();
        },
        collection: 'tasks',
        docId: taskId,
        operationType: 'delete',
        payloadJson: jsonEncode({'taskId': taskId}),
      );
    } catch (e, stack) {
      AppLogger.e('Erro ao excluir tarefa localmente', e, stack);

      rethrow;
    }
  }
}
