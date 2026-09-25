import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:drift/drift.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/database_provider.dart';
import 'package:life_os/core/utils/app_logger.dart';
import 'package:life_os/features/settings/presentation/providers/analytics_provider.dart';
import 'package:life_os/features/tasks/data/models/task_model.dart';

// ============================================================================
// REPOSITORY PROVIDER
// ============================================================================

final tasksRepositoryProvider = Provider((ref) {
  final db = ref.watch(databaseProvider);

  return TasksRepository(db, FirebaseFirestore.instance, FirebaseAuth.instance);
});

typedef ManualTaskStatusToggle =
    Future<void> Function(String taskId, bool currentStatus);

final manualTaskStatusToggleProvider = Provider<ManualTaskStatusToggle>((ref) {
  final repository = ref.watch(tasksRepositoryProvider);
  final analytics = ref.watch(analyticsServiceProvider);
  final isSessionActive = ref.watch(analyticsSessionActiveProvider);
  return (taskId, currentStatus) async {
    final sessionActive = isSessionActive();
    await repository.toggleTaskStatus(taskId, currentStatus);
    if (sessionActive && !currentStatus) {
      unawaited(analytics.logTaskCompleted());
    }
  };
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

class _TaskSessionChanged implements Exception {
  const _TaskSessionChanged();
}

class TasksRepository {
  final AppDatabase _db;
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  TasksRepository(this._db, this._firestore, this._auth);

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
    final expectedUid = _auth.currentUser?.uid.trim();
    if (expectedUid == null || expectedUid.isEmpty) return;

    try {
      final pullStartedAt = DateTime.now().millisecondsSinceEpoch;
      final pendingAtPullStart =
          await (_db.select(_db.syncQueueTable)..where(
                (item) =>
                    item.ownerUid.equals(expectedUid) &
                    item.collection.equals('tasks') &
                    item.status.equals(SyncQueuePersistenceStatus.pending),
              ))
              .get();
      if (_auth.currentUser?.uid != expectedUid) return;
      final pendingOperationIds = pendingAtPullStart
          .map((item) => item.id)
          .toList();
      final snapshot = await _firestore
          .collection('users')
          .doc(expectedUid)
          .collection('tasks')
          .get(const GetOptions(source: Source.server));
      if (_auth.currentUser?.uid != expectedUid) return;
      final remoteDocIds = snapshot.docs.map((doc) => doc.id).toSet();

      await _db.transaction(() async {
        void requireCurrentUser() {
          if (_auth.currentUser?.uid != expectedUid) {
            throw const _TaskSessionChanged();
          }
        }

        requireCurrentUser();
        final authoritativeItems =
            await (_db.select(_db.syncQueueTable)..where(
                  (item) =>
                      item.ownerUid.equals(expectedUid) &
                      item.collection.equals('tasks') &
                      (item.status.equals(SyncQueuePersistenceStatus.pending) |
                          (item.status.equals(
                                SyncQueuePersistenceStatus.succeeded,
                              ) &
                              (item.createdAt.isBiggerOrEqualValue(
                                    pullStartedAt,
                                  ) |
                                  item.id.isIn(pendingOperationIds)))),
                ))
                .get();
        final protectedDocIds = authoritativeItems
            .map((item) => item.docId)
            .toSet();
        requireCurrentUser();

        for (final doc in snapshot.docs) {
          requireCurrentUser();
          if (protectedDocIds.contains(doc.id)) continue;
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
          requireCurrentUser();
        }

        final localTasks = await _db.select(_db.taskTable).get();
        requireCurrentUser();
        for (final task in localTasks) {
          requireCurrentUser();
          final id = task.id.trim();
          if (id.isEmpty ||
              id == 'pending' ||
              id == 'synced' ||
              remoteDocIds.contains(task.id) ||
              protectedDocIds.contains(task.id)) {
            continue;
          }
          await (_db.delete(
            _db.taskTable,
          )..where((t) => t.id.equals(task.id))).go();
          requireCurrentUser();
        }
      });
    } on _TaskSessionChanged {
      return;
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
    } catch (e, stack) {
      AppLogger.e('Erro ao atualizar tarefa localmente', e, stack);

      rethrow;
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
