import 'package:drift/drift.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart'; // ✅ Import adicionado para geração segura de IDs

import 'package:life_os/core/database/app_database.dart';
// ✅ Import da Entidade em vez do Model para manter a Clean Architecture
import 'package:life_os/features/tasks/domain/entities/task_entity.dart';

class TasksRepository {
  final AppDatabase _db;
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  TasksRepository(this._db, this._firestore, this._auth);

  // 1. Stream que escuta o banco LOCAL (Offline-First)
  // ✅ Retorna TaskEntity para a UI/Provider não conhecer detalhes do Banco
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

  // 2. Sincronização (Busca do Firebase e salva no Local)
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

  // 3. Adicionar Tarefa
  Future<void> addTask(String title, String priority) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception("Usuário não autenticado");

    final id = const Uuid().v4();

    // A. Salva Localmente Instantâneo
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

    // B. Sync com Firebase
    // ✅ Protegido com try/catch para não quebrar se o app estiver offline
    try {
      await _firestore
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
    } catch (e) {
      debugPrint(
        "Tarefa salva localmente. Falha no sync com Firebase (addTask): $e",
      );
    }
  }

  // 4. Toggle Status
  Future<void> toggleTaskStatus(String id, bool currentStatus) async {
    final user = _auth.currentUser;
    if (user == null) return;

    // 1. Atualiza Local de forma síncrona/aguardada
    await (_db.update(_db.taskTable)..where((t) => t.id.equals(id))).write(
      TaskTableCompanion(isCompleted: Value(!currentStatus)),
    );

    // 2. Sync Firebase em segundo plano
    try {
      await _firestore
          .collection('users')
          .doc(user.uid)
          .collection('tasks')
          .doc(id)
          .update({'isCompleted': !currentStatus});
    } catch (e) {
      debugPrint("Erro no sync do Firebase ao alternar status: $e");
    }
  }

  // 5. Deletar
  Future<void> deleteTask(String id) async {
    final user = _auth.currentUser;
    if (user == null) return;

    // A. Deletar Local
    await (_db.delete(_db.taskTable)..where((t) => t.id.equals(id))).go();

    // B. Deletar Firebase
    // ✅ Protegido com try/catch
    try {
      await _firestore
          .collection('users')
          .doc(user.uid)
          .collection('tasks')
          .doc(id)
          .delete();
    } catch (e) {
      debugPrint(
        "Tarefa deletada localmente. Falha no sync com Firebase (deleteTask): $e",
      );
    }
  }
}
