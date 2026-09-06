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
    final user = _auth.currentUser;

    if (user == null) {
      return;
    }

    final id = _uuid.v4();
    final cleanTitle = InputSanitizer.sanitize(title);
    final now = DateTime.now();

    try {
      await _db.transactionWithSync(
        ownerUid: user.uid,
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
    final user = _auth.currentUser;

    if (user == null) {
      return;
    }

    try {
      final currentRow = await (_db.select(
        _db.goals,
      )..where((table) => table.id.equals(id))).getSingleOrNull();
      final now = DateTime.now();
      final cycleExpired =
          currentRow != null &&
          _isGoalCycleExpired(
            currentRow.period,
            DateTime.fromMillisecondsSinceEpoch(currentRow.lastReset),
            now,
          );
      final effectiveValue = cycleExpired
          ? _progressForNewCycle(
              requestedValue: newValue,
              currentValue: currentRow.currentValue,
              targetValue: currentRow.targetValue,
            )
          : newValue;

      await _db.transactionWithSync(
        ownerUid: user.uid,
        localOperation: () async {
          await (_db.update(
            _db.goals,
          )..where((table) => table.id.equals(id))).write(
            GoalsCompanion(
              currentValue: Value(effectiveValue),
              lastReset: cycleExpired
                  ? Value(now.millisecondsSinceEpoch)
                  : const Value.absent(),
            ),
          );
        },
        collection: 'goals',
        docId: id,
        operationType: 'update',
        payloadJson: jsonEncode({
          'currentValue': effectiveValue,
          if (cycleExpired) 'lastReset': now.toIso8601String(),
        }),
      );
    } catch (e, stack) {
      AppLogger.e('Erro ao atualizar progresso da Meta local', e, stack);
      rethrow;
    }
  }

  Future<void> resetGoalCycle(String id) async {
    final user = _auth.currentUser;

    if (user == null) {
      return;
    }

    final now = DateTime.now();

    try {
      await _db.transactionWithSync(
        ownerUid: user.uid,
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
    final user = _auth.currentUser;

    if (user == null) {
      return;
    }

    try {
      await _db.transactionWithSync(
        ownerUid: user.uid,
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
    final user = _auth.currentUser;
    if (user == null) return;

    final expectedUid = user.uid;

    try {
      AppLogger.i("SYNC Metas: Iniciando...");
      final pullStartedAt = DateTime.now().millisecondsSinceEpoch;
      final snapshot = await _firestore
          .collection('users')
          .doc(expectedUid)
          .collection('goals')
          .get();

      for (final doc in snapshot.docs) {
        if (_auth.currentUser?.uid != expectedUid) return;
        final data = doc.data();
        final createdAt = _parseFirestoreDate(data['createdAt']);
        if (createdAt == null) {
          AppLogger.w('SYNC Metas: data de criação inválida ignorada.');
          continue;
        }
        final lastReset = _parseFirestoreDate(data['lastReset']) ?? createdAt;

        final sessionValid = await _db.transaction(() async {
          if (_auth.currentUser?.uid != expectedUid) return false;

          final locallyAuthoritative =
              await (_db.select(_db.syncQueueTable)..where(
                    (item) =>
                        item.ownerUid.equals(expectedUid) &
                        item.collection.equals('goals') &
                        item.docId.equals(doc.id) &
                        (item.status.equals(
                              SyncQueuePersistenceStatus.pending,
                            ) |
                            (item.status.equals(
                                  SyncQueuePersistenceStatus.succeeded,
                                ) &
                                item.createdAt.isBiggerOrEqualValue(
                                  pullStartedAt,
                                ))),
                  ))
                  .get();

          if (_auth.currentUser?.uid != expectedUid) return false;
          if (locallyAuthoritative.isNotEmpty) return true;

          await _db
              .into(_db.goals)
              .insertOnConflictUpdate(
                GoalsCompanion(
                  id: Value(doc.id),
                  title: Value(data['title']),
                  period: Value(data['period']),
                  currentValue: Value(data['currentValue']),
                  targetValue: Value(data['targetValue']),
                  createdAt: Value(createdAt.millisecondsSinceEpoch),
                  lastReset: Value(lastReset.millisecondsSinceEpoch),
                ),
              );
          return _auth.currentUser?.uid == expectedUid;
        });

        if (!sessionValid) return;
      }
      AppLogger.i("SYNC Metas: Concluído.");
    } catch (e, stack) {
      AppLogger.e("SYNC Metas: ERRO CRÍTICO", e, stack);
    }
  }

  DateTime? _parseFirestoreDate(Object? value) {
    if (value is Timestamp) return value.toDate();
    if (value is String) return DateTime.tryParse(value);
    return null;
  }

  bool _isGoalCycleExpired(String period, DateTime lastReset, DateTime now) {
    if (period == 'DIÁRIA') {
      return lastReset.day != now.day ||
          lastReset.month != now.month ||
          lastReset.year != now.year;
    }

    if (period == 'MENSAL') {
      return lastReset.month != now.month || lastReset.year != now.year;
    }

    if (period == 'SEMANAL') {
      final lastResetMonday = lastReset.subtract(
        Duration(days: lastReset.weekday - 1),
      );
      final currentMonday = now.subtract(Duration(days: now.weekday - 1));

      return lastResetMonday.day != currentMonday.day ||
          lastResetMonday.month != currentMonday.month ||
          lastResetMonday.year != currentMonday.year;
    }

    return false;
  }

  int _progressForNewCycle({
    required int requestedValue,
    required int currentValue,
    required int targetValue,
  }) {
    final delta = requestedValue - currentValue;
    final nonNegativeDelta = delta < 0 ? 0 : delta;
    if (targetValue >= 0 && nonNegativeDelta > targetValue) {
      return targetValue;
    }
    return nonNegativeDelta;
  }
}
