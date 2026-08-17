import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import 'package:life_os/core/utils/app_logger.dart'; // 🚀 Nosso Logger
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/security/input_sanitizer.dart';
import 'package:life_os/features/goals/domain/entities/goal_entity.dart';

class GoalRepository {
  final AppDatabase _db;
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;
  final _uuid = const Uuid();

  GoalRepository(this._db, this._firestore, this._auth);

  // ===========================================================================
  // 1. LEITURA (STREAMS LOCAIS)
  // ===========================================================================

  Stream<List<GoalEntity>> getGoalsStream() {
    return _db
        .select(_db.goals)
        .watch()
        .map(
          (rows) => rows
              .map(
                (r) => GoalEntity(
                  id: r.id,
                  title: r.title,
                  period: r.period,
                  currentValue: r.currentValue,
                  targetValue: r.targetValue,
                  createdAt: DateTime.fromMillisecondsSinceEpoch(r.createdAt),
                  lastReset: DateTime.fromMillisecondsSinceEpoch(r.lastReset),
                ),
              )
              .toList(),
        );
  }

  // ===========================================================================
  // 2. ESCRITA (OFFLINE-FIRST)
  // ===========================================================================

  Future<void> createGoal(String title, String period, int targetValue) async {
    if (_auth.currentUser == null) {
      return;
    }

    final id = _uuid.v4();
    final cleanTitle = InputSanitizer.sanitize(title);
    final now = DateTime.now();

    try {
      await _db.transactionWithSync(
        localOperation: () async {
          await _db
              .into(_db.goals)
              .insert(
                GoalsCompanion.insert(
                  id: id,
                  title: cleanTitle,
                  period: period,
                  currentValue: 0,
                  targetValue: targetValue,
                  createdAt: now.millisecondsSinceEpoch,
                  lastReset: now.millisecondsSinceEpoch,
                ),
              );
        },
        collection: 'goals',
        docId: id,
        operationType: 'create',
        payloadJson: jsonEncode({
          'title': cleanTitle,
          'period': period,
          'currentValue': 0,
          'targetValue': targetValue,
          'createdAt': now.toIso8601String(),
          'lastReset': now.toIso8601String(),
        }),
      );
    } catch (e, stack) {
      AppLogger.e('Erro ao criar Meta localmente', e, stack);
      rethrow;
    }
  }

  Future<void> updateGoalProgress(String id, int newValue) async {
    if (_auth.currentUser == null) {
      return;
    }

    try {
      await _db.transactionWithSync(
        localOperation: () async {
          await (_db.update(_db.goals)..where((table) => table.id.equals(id)))
              .write(GoalsCompanion(currentValue: Value(newValue)));
        },
        collection: 'goals',
        docId: id,
        operationType: 'update',
        payloadJson: jsonEncode({'currentValue': newValue}),
      );
    } catch (e, stack) {
      AppLogger.e('Erro ao atualizar progresso da Meta local', e, stack);
      rethrow;
    }
  }

  Future<void> resetGoalCycle(String id) async {
    if (_auth.currentUser == null) {
      return;
    }

    final now = DateTime.now();

    try {
      await _db.transactionWithSync(
        localOperation: () async {
          await (_db.update(
            _db.goals,
          )..where((table) => table.id.equals(id))).write(
            GoalsCompanion(
              currentValue: const Value(0),
              lastReset: Value(now.millisecondsSinceEpoch),
            ),
          );
        },
        collection: 'goals',
        docId: id,
        operationType: 'update',
        payloadJson: jsonEncode({
          'currentValue': 0,
          'lastReset': now.toIso8601String(),
        }),
      );
    } catch (e, stack) {
      AppLogger.e('Erro ao resetar ciclo da Meta local', e, stack);
      rethrow;
    }
  }

  Future<void> removeGoal(String id) async {
    if (_auth.currentUser == null) {
      return;
    }

    try {
      await _db.transactionWithSync(
        localOperation: () async {
          await (_db.delete(
            _db.goals,
          )..where((table) => table.id.equals(id))).go();
        },
        collection: 'goals',
        docId: id,
        operationType: 'delete',
        payloadJson: jsonEncode({'goalId': id}),
      );
    } catch (e, stack) {
      AppLogger.e('Erro ao remover Meta localmente', e, stack);
      rethrow;
    }
  }

  // ===========================================================================
  // 3. SINCRONIZAÇÃO EM BACKGROUND (FIREBASE PULL & PUSH)
  // ===========================================================================

  Future<void> syncGoalsFromFirebaseToLocal() async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;

    try {
      AppLogger.i("SYNC Metas: Iniciando...");
      final snapshot = await _firestore
          .collection('users')
          .doc(uid)
          .collection('goals')
          .get();

      for (var doc in snapshot.docs) {
        final data = doc.data();
        await _db
            .into(_db.goals)
            .insertOnConflictUpdate(
              GoalsCompanion(
                id: Value(doc.id),
                title: Value(data['title']),
                period: Value(data['period']),
                currentValue: Value(data['currentValue']),
                targetValue: Value(data['targetValue']),
                createdAt: Value(
                  (data['createdAt'] as Timestamp).millisecondsSinceEpoch,
                ),
                lastReset: Value(
                  (data['lastReset'] as Timestamp).millisecondsSinceEpoch,
                ),
              ),
            );
      }
      AppLogger.i("SYNC Metas: Concluído.");
    } catch (e, stack) {
      AppLogger.e("SYNC Metas: ERRO CRÍTICO", e, stack);
    }
  }
}
