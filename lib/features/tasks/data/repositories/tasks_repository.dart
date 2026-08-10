import 'dart:async';
import 'package:drift/drift.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:uuid/uuid.dart';

import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/utils/app_logger.dart';
import 'package:life_os/features/tasks/domain/entities/task_entity.dart';

class TasksRepository {
  final AppDatabase _db;
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  TasksRepository(this._db, this._firestore, this._auth);

  // ===========================================================================
  // 1. LEITURA (STREAMS LOCAIS)
  // ===========================================================================

  Stream<List<TaskEntity>> getTasksStream() {
    return _db.select(_db.taskTable).watch().map((rows) {
      return rows
          .map(
            (row) => TaskEntity(
              id: row.id,
              title: row.title,
              priority: row.priority,
              isCompleted: row.isCompleted,
              description: '',
              subTasks: const [],
            ),
          )
          .toList();
    });
  }

  // ===========================================================================
  // 2. ESCRITA (OFFLINE-FIRST)
  // ===========================================================================

  Future<void> addTask(String title, String priority) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception("Usuário não autenticado");

    final id = const Uuid().v4();

    try {
      // 1. Salva Localmente Instantâneo
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

      // 2. Sync Firebase em background
      unawaited(_addTaskToFirestore(user.uid, id, title, priority));
    } catch (e, stack) {
      AppLogger.e("Erro ao salvar tarefa localmente", e, stack);
      rethrow;
    }
  }

  Future<void> toggleTaskStatus(String id, bool currentStatus) async {
    final user = _auth.currentUser;
    if (user == null) return;

    try {
      // 1. Atualiza Local de forma síncrona
      await (_db.update(_db.taskTable)..where((t) => t.id.equals(id))).write(
        TaskTableCompanion(isCompleted: Value(!currentStatus)),
      );

      // 2. Sync Firebase em background
      unawaited(_updateTaskStatusInFirestore(user.uid, id, !currentStatus));
    } catch (e, stack) {
      AppLogger.e("Erro ao alternar status localmente", e, stack);
      rethrow;
    }
  }

  Future<void> deleteTask(String id) async {
    final user = _auth.currentUser;
    if (user == null) return;

    try {
      // 1. Deletar Tarefa Localmente
      await (_db.delete(_db.taskTable)..where((t) => t.id.equals(id))).go();

      // 2. Limpeza local: Apaga a notificação atrelada a essa tarefa
      await (_db.delete(
        _db.notificationsTable,
      )..where((t) => t.id.equals(id) | t.id.equals('task_$id'))).go();

      // 3. Deletar Firebase (Tarefa + Notificações) em background
      unawaited(_deleteTaskAndNotifsInFirestore(user.uid, id));
    } catch (e, stack) {
      AppLogger.e("Erro ao deletar tarefa localmente", e, stack);
      rethrow;
    }
  }

  // ===========================================================================
  // 3. SINCRONIZAÇÃO FIREBASE -> DRIFT
  // ===========================================================================

  Future<void> syncTasksFromFirebaseToLocal() async {
    final user = _auth.currentUser;
    if (user == null) return;

    try {
      AppLogger.i('SYNC Tarefas: Iniciando...');
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
      AppLogger.i('SYNC Tarefas: Concluído com sucesso.');
    } catch (e, stack) {
      AppLogger.e("Erro ao sincronizar tarefas do Firebase", e, stack);
    }
  }

  // ===========================================================================
  // 4. FIREBASE - MÉTODOS PRIVADOS EM BACKGROUND
  // ===========================================================================

  Future<void> _addTaskToFirestore(
    String userId,
    String id,
    String title,
    String priority,
  ) async {
    try {
      await _firestore
          .collection('users')
          .doc(userId)
          .collection('tasks')
          .doc(id)
          .set({
            'title': title,
            'priority': priority,
            'isCompleted': false,
            'date': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
    } catch (e, stack) {
      AppLogger.e("Falha no sync com Firebase (addTask)", e, stack);
    }
  }

  Future<void> _updateTaskStatusInFirestore(
    String userId,
    String id,
    bool newStatus,
  ) async {
    try {
      await _firestore
          .collection('users')
          .doc(userId)
          .collection('tasks')
          .doc(id)
          .set({
            'isCompleted': newStatus,
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
    } catch (e, stack) {
      AppLogger.e("Erro no sync do Firebase ao alternar status", e, stack);
    }
  }

  // 🛡️ CRÍTICO: Método que garante a deleção da tarefa e da notificação na nuvem
  Future<void> _deleteTaskAndNotifsInFirestore(
    String userId,
    String taskId,
  ) async {
    try {
      final batch = _firestore.batch();

      // Deleta o documento da tarefa
      final taskDoc = _firestore
          .collection('users')
          .doc(userId)
          .collection('tasks')
          .doc(taskId);

      // Deleta possíveis variações do ID da notificação (abrangendo 'task_$id' e '$id')
      final notifDoc1 = _firestore
          .collection('users')
          .doc(userId)
          .collection('notifications')
          .doc(taskId);

      final notifDoc2 = _firestore
          .collection('users')
          .doc(userId)
          .collection('notifications')
          .doc('task_$taskId');

      batch.delete(taskDoc);
      batch.delete(notifDoc1);
      batch.delete(notifDoc2);

      await batch.commit();
      AppLogger.i('Tarefa $taskId e suas notificações removidas do Firebase.');
    } catch (e, stack) {
      AppLogger.e(
        "Falha no sync com Firebase (deleteTask e notificações)",
        e,
        stack,
      );
    }
  }
}
