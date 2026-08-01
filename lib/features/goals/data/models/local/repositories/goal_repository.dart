import 'dart:async';
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
    if (_auth.currentUser == null) return;

    final id = _uuid.v4();
    final cleanTitle = InputSanitizer.sanitize(title);
    final now = DateTime.now();

    try {
      // 1. Salva Localmente
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

      // 2. Envia para o Firebase em Background
      unawaited(
        _createGoalInFirestore(id, cleanTitle, period, targetValue, now),
      );
    } catch (e, stack) {
      AppLogger.e('Erro ao criar Meta localmente', e, stack);
      rethrow;
    }
  }

  Future<void> updateGoalProgress(String id, int newValue) async {
    if (_auth.currentUser == null) return;

    try {
      // 1. Atualiza Localmente
      await (_db.update(_db.goals)..where((t) => t.id.equals(id))).write(
        GoalsCompanion(currentValue: Value(newValue)),
      );

      // 2. Atualiza no Firebase em Background
      unawaited(_updateGoalProgressInFirestore(id, newValue));
    } catch (e, stack) {
      AppLogger.e('Erro ao atualizar progresso da Meta local', e, stack);
      rethrow;
    }
  }

  Future<void> resetGoalCycle(String id) async {
    if (_auth.currentUser == null) return;
    final now = DateTime.now();

    try {
      // 1. Reseta Localmente
      await (_db.update(_db.goals)..where((t) => t.id.equals(id))).write(
        GoalsCompanion(
          currentValue: const Value(0),
          lastReset: Value(now.millisecondsSinceEpoch),
        ),
      );

      // 2. Reseta no Firebase em Background
      unawaited(_resetGoalCycleInFirestore(id, now));
    } catch (e, stack) {
      AppLogger.e('Erro ao resetar ciclo da Meta local', e, stack);
      rethrow;
    }
  }

  Future<void> removeGoal(String id) async {
    if (_auth.currentUser == null) return;

    try {
      // 1. Deleta Localmente
      await (_db.delete(_db.goals)..where((t) => t.id.equals(id))).go();

      // 2. Deleta no Firebase em Background
      unawaited(_removeGoalFromFirestore(id));
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

  // --- Métodos Privados Fire-and-Forget ---

  Future<void> _createGoalInFirestore(
    String id,
    String title,
    String period,
    int targetValue,
    DateTime now,
  ) async {
    try {
      await _firestore
          .collection('users')
          .doc(_auth.currentUser!.uid)
          .collection('goals')
          .doc(id)
          .set({
            'title': title,
            'period': period,
            'currentValue': 0,
            'targetValue': targetValue,
            // Usando a mesma data local garante sincronia 100% perfeita entre Drift e Firestore
            'createdAt': Timestamp.fromDate(now),
            'lastReset': Timestamp.fromDate(now),
          }, SetOptions(merge: true));
    } catch (e, stack) {
      AppLogger.e('Sync Error: Criar Meta', e, stack);
    }
  }

  Future<void> _updateGoalProgressInFirestore(String id, int newValue) async {
    try {
      // Usando set com merge: true para evitar erro NOT_FOUND
      await _firestore
          .collection('users')
          .doc(_auth.currentUser!.uid)
          .collection('goals')
          .doc(id)
          .set({'currentValue': newValue}, SetOptions(merge: true));
    } catch (e, stack) {
      AppLogger.e('Sync Error: Progresso da Meta', e, stack);
    }
  }

  Future<void> _resetGoalCycleInFirestore(String id, DateTime now) async {
    try {
      // Usando set com merge: true para evitar erro NOT_FOUND
      await _firestore
          .collection('users')
          .doc(_auth.currentUser!.uid)
          .collection('goals')
          .doc(id)
          .set({
            'currentValue': 0,
            'lastReset': Timestamp.fromDate(now),
          }, SetOptions(merge: true));
    } catch (e, stack) {
      AppLogger.e('Sync Error: Reset da Meta', e, stack);
    }
  }

  Future<void> _removeGoalFromFirestore(String id) async {
    try {
      await _firestore
          .collection('users')
          .doc(_auth.currentUser!.uid)
          .collection('goals')
          .doc(id)
          .delete();
    } catch (e, stack) {
      AppLogger.e('Sync Error: Remover Meta', e, stack);
    }
  }
}
