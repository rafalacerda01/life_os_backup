import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:drift/drift.dart';
import 'package:life_os/features/tasks/data/models/task_model.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/database_provider.dart';

// 1. Repository Provider
final tasksRepositoryProvider = Provider((ref) {
  final db = ref.watch(databaseProvider);
  return TasksRepository(db, FirebaseFirestore.instance, FirebaseAuth.instance);
});

// 2. Stream Provider que alimenta a TasksScreen reativamente
final tasksStreamProvider = StreamProvider<List<TaskModel>>((ref) {
  final repository = ref.watch(tasksRepositoryProvider);
  return repository.getTasksStream();
});

class TasksRepository {
  final AppDatabase _db;
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  TasksRepository(this._db, this._firestore, this._auth);

  // STREAM: Escuta o banco local (Offline-First)
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

  // SYNC: Busca do Firebase e salva no Local (Hydration)
  Future<void> syncTasksFromFirebaseToLocal() async {
    final user = _auth.currentUser;
    if (user == null) return;

    try {
      final snapshot = await _firestore
          .collection('users')
          .doc(user.uid)
          .collection('tasks')
          .get();

      for (var doc in snapshot.docs) {
        final data = doc.data();
        await _db
            .into(_db.taskTable)
            .insertOnConflictUpdate(
              TaskTableCompanion.insert(
                id: doc.id,
                title: data['title'] ?? '',
                priority: data['priority'] ?? 'medium',
                isCompleted: Value(data['isCompleted'] ?? false),
                date: (data['date'] as Timestamp).toDate(),
              ),
            );
      }
    } catch (e) {
      debugPrint("Erro ao sincronizar tarefas: $e");
    }
  }

  // ADICIONAR TAREFA (Offline-First)
  Future<void> addTask(String title, String priority) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception("Usuário não autenticado");

    final id = DateTime.now().millisecondsSinceEpoch.toString();

    // 1. Salva no Banco Local
    await _db
        .into(_db.taskTable)
        .insert(
          TaskTableCompanion.insert(
            id: id,
            title: title,
            priority: priority,
            isCompleted: const Value(false),
            date: DateTime.now(),
          ),
        );

    // 2. Sync com Firebase
    _firestore
        .collection('users')
        .doc(user.uid)
        .collection('tasks')
        .doc(id)
        .set({
          'title': title,
          'priority': priority,
          'isCompleted': false,
          'date': Timestamp.now(),
        });
  }

  // ALTERNAR STATUS (Offline-First)
  Future<void> toggleTaskStatus(String taskId, bool currentStatus) async {
    final user = _auth.currentUser;
    if (user == null) return;

    // 1. Atualiza Local
    await (_db.update(_db.taskTable)..where((t) => t.id.equals(taskId))).write(
      TaskTableCompanion(isCompleted: Value(!currentStatus)),
    );

    // 2. Sync Firebase
    await _firestore
        .collection('users')
        .doc(user.uid)
        .collection('tasks')
        .doc(taskId)
        .update({'isCompleted': !currentStatus});
  }

  // EXCLUIR TAREFA (Offline-First)
  Future<void> deleteTask(String taskId) async {
    final user = _auth.currentUser;
    if (user == null) return;

    // 1. Deleta Local
    await (_db.delete(_db.taskTable)..where((t) => t.id.equals(taskId))).go();

    // 2. Deleta Firebase
    await _firestore
        .collection('users')
        .doc(user.uid)
        .collection('tasks')
        .doc(taskId)
        .delete();
  }
}
