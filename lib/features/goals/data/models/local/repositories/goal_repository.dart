import 'package:life_os/core/database/local_account_session.dart';
import 'package:life_os/core/services/generational_read_policy.dart';
import 'dart:convert';
import 'package:life_os/core/database/database_sync_policy.dart';
import 'package:life_os/features/premium/domain/services/plan_limits.dart';
import 'package:life_os/features/premium/domain/services/quota_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import 'package:life_os/core/utils/app_logger.dart'; // 🚀 Nosso Logger
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/security/input_sanitizer.dart';
import 'package:life_os/features/goals/domain/entities/goal_entity.dart';

class _GoalSessionChanged implements Exception {
  const _GoalSessionChanged();
}

class GoalRepository {
  final LocalAccountLease? sessionLease;
  Future<void> _verifyRemoteRead(String uid) => GenerationalReadPolicy.verify(
    identity: _db.identity,
    lease: sessionLease,
    auth: _auth,
    store: _firestore,
    expectedUid: uid,
  );
  void _requireReadSession(String uid) => GenerationalReadPolicy.requireCurrent(
    identity: _db.identity,
    lease: sessionLease,
    auth: _auth,
    expectedUid: uid,
  );

  final AppDatabase _db;
  final FirebaseFirestore? _remoteFirestore;
  final FirebaseAuth? _remoteAuth;
  FirebaseFirestore get _firestore =>
      _remoteFirestore ?? (throw const LocalRemoteSyncDisabled());
  FirebaseAuth get _auth =>
      _remoteAuth ?? (throw const LocalRemoteSyncDisabled());
  String? get _ownerUid =>
      _db.isLocalOnly ? _db.identity?.uid : _remoteAuth?.currentUser?.uid;
  final _uuid = const Uuid();

  GoalRepository(
    this._db,
    FirebaseFirestore firestore,
    FirebaseAuth auth, {
    this.sessionLease,
  }) : _remoteFirestore = firestore,
       _remoteAuth = auth;

  GoalRepository.local(this._db)
    : _remoteFirestore = null,
      _remoteAuth = null,
      sessionLease = null {
    if (!_db.isLocalOnly)
      throw ArgumentError('LOCAL_PROFILE_SYNC_POLICY_REQUIRED');
  }

  Future<void> _enforceLocalFreeQuota() async {
    if (!_db.isLocalOnly) return;
    final limit = PlanLimits.free.goals;
    final count = _db.goals.id.count();
    final current = await (_db.selectOnly(
      _db.goals,
    )..addColumns([count])).map((row) => row.read(count) ?? 0).getSingle();
    if (!const QuotaService().canCreate(limit: limit, currentCount: current)) {
      throw PlanQuotaExceeded(QuotaResource.goals, limit.maximum);
    }
  }

  /// UI increments in local storage are based on the admitted row, not its snapshot.
  Future<void> changeLocalGoalProgress(String id, int delta) async {
    if (!_db.isLocalOnly)
      throw StateError('LOCAL_PROFILE_SYNC_POLICY_REQUIRED');
    if (delta != -1 && delta != 1) throw ArgumentError('INVALID_GOAL_DELTA');
    final owner = _ownerUid;
    if (owner == null) throw StateError('LOCAL_PROFILE_REQUIRED');
    await _db.transactionWithSync(
      ownerUid: owner,
      localOperation: () async {
        final row = await (_db.select(
          _db.goals,
        )..where((t) => t.id.equals(id))).getSingleOrNull();
        if (row == null) return;
        if (row.targetValue <= 0) throw StateError('GOAL_TARGET_INVALID');
        final now = DateTime.now();
        final expired = _isGoalCycleExpired(
          row.period,
          DateTime.fromMillisecondsSinceEpoch(row.lastReset),
          now,
        );
        final next = ((expired ? 0 : row.currentValue) + delta).clamp(
          0,
          row.targetValue,
        );
        await (_db.update(_db.goals)..where((t) => t.id.equals(id))).write(
          GoalsCompanion(
            currentValue: Value(next),
            lastReset: expired
                ? Value(now.millisecondsSinceEpoch)
                : const Value.absent(),
          ),
        );
      },
      collection: 'goals',
      docId: id,
      operationType: 'update',
      payloadJson: '{}',
    );
  }

  /// Re-check expiry in the transaction so delayed UI callbacks cannot reset a new cycle.
  Future<void> resetExpiredGoalCycle(String id) async {
    if (!_db.isLocalOnly) return resetGoalCycle(id);
    final owner = _ownerUid;
    if (owner == null) throw StateError('LOCAL_PROFILE_REQUIRED');
    await _db.transactionWithSync(
      ownerUid: owner,
      localOperation: () async {
        final row = await (_db.select(
          _db.goals,
        )..where((t) => t.id.equals(id))).getSingleOrNull();
        if (row == null) return;
        final now = DateTime.now();
        if (!_isGoalCycleExpired(
          row.period,
          DateTime.fromMillisecondsSinceEpoch(row.lastReset),
          now,
        ))
          return;
        await (_db.update(_db.goals)..where((t) => t.id.equals(id))).write(
          GoalsCompanion(
            currentValue: const Value(0),
            lastReset: Value(now.millisecondsSinceEpoch),
          ),
        );
      },
      collection: 'goals',
      docId: id,
      operationType: 'update',
      payloadJson: '{}',
    );
  }

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
    final ownerUid = _ownerUid;

    if (ownerUid == null) {
      return;
    }

    final cleanTitle = InputSanitizer.sanitize(title);
    if (cleanTitle.isEmpty || cleanTitle.length > 200) {
      throw ArgumentError('Título da meta inválido.');
    }
    if (targetValue <= 0) {
      throw ArgumentError('Objetivo numérico da meta inválido.');
    }
    if (!const {'DIÁRIA', 'SEMANAL', 'MENSAL'}.contains(period)) {
      throw ArgumentError('Período da meta inválido.');
    }

    final id = _uuid.v4();
    final now = DateTime.now();

    try {
      await _db.transactionWithSync(
        ownerUid: ownerUid,
        localOperation: () async {
          await _enforceLocalFreeQuota();
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
    final ownerUid = _ownerUid;

    if (ownerUid == null) {
      return;
    }

    try {
      final admission = _db.localMutations.capture(expectedUid: ownerUid);
      final currentRow = await (_db.select(
        _db.goals,
      )..where((table) => table.id.equals(id))).getSingleOrNull();
      if (currentRow == null) return;
      if (newValue < 0 || newValue > 9007199254740991)
        throw ArgumentError('Progresso da meta inválido.');
      final now = DateTime.now();
      final cycleExpired = _isGoalCycleExpired(
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

      if (effectiveValue < 0 || effectiveValue > currentRow.targetValue)
        throw ArgumentError('Progresso da meta inválido.');
      await _db.transactionWithSync(
        admission: admission,
        ownerUid: ownerUid,
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
    final ownerUid = _ownerUid;

    if (ownerUid == null) {
      return;
    }

    final now = DateTime.now();

    try {
      await _db.transactionWithSync(
        ownerUid: ownerUid,
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
    final ownerUid = _ownerUid;

    if (ownerUid == null) {
      return;
    }

    try {
      await _db.transactionWithSync(
        ownerUid: ownerUid,
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
    if (_db.isLocalOnly) return;
    final expectedUid = _auth.currentUser?.uid.trim();
    if (expectedUid == null || expectedUid.isEmpty) return;

    try {
      AppLogger.i("SYNC Metas: Iniciando...");
      final ticket = _db.localMutations.capture(expectedUid: expectedUid);
      await _verifyRemoteRead(expectedUid);
      final pullStartedAt = DateTime.now().millisecondsSinceEpoch;
      final pendingAtPullStart =
          await (_db.select(_db.syncQueueTable)..where(
                (item) =>
                    item.ownerUid.equals(expectedUid) &
                    item.collection.equals('goals') &
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
          .collection('goals')
          .get(const GetOptions(source: Source.server));
      if (_auth.currentUser?.uid != expectedUid) return;
      await _verifyRemoteRead(expectedUid);
      if (_db.identity?.generation != null &&
          !GenerationalReadPolicy.accepts(
            _db.identity,
            fromCache: snapshot.metadata.isFromCache,
            pendingWrites: snapshot.metadata.hasPendingWrites,
          ))
        throw StateError('GENERATIONAL_SNAPSHOT_UNCONFIRMED');
      final remoteDocIds = snapshot.docs.map((doc) => doc.id).toSet();

      await _db.transactionWithCommitGuard(
        admission: ticket,
        waitForReopen: false,
        validateBeforeCommit: () => _requireReadSession(expectedUid),
        () async {
          void requireCurrentUser() {
            if (_auth.currentUser?.uid != expectedUid) {
              throw const _GoalSessionChanged();
            }
          }

          requireCurrentUser();
          final authoritativeItems =
              await (_db.select(_db.syncQueueTable)..where(
                    (item) =>
                        item.ownerUid.equals(expectedUid) &
                        item.collection.equals('goals') &
                        (item.status.equals(
                              SyncQueuePersistenceStatus.pending,
                            ) |
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
            final createdAt = _parseFirestoreDate(data['createdAt']);
            if (createdAt == null) {
              AppLogger.w('SYNC Metas: data de criação inválida ignorada.');
              continue;
            }
            final lastReset =
                _parseFirestoreDate(data['lastReset']) ?? createdAt;
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
            requireCurrentUser();
          }

          final localGoals = await _db.select(_db.goals).get();
          requireCurrentUser();
          for (final goal in localGoals) {
            requireCurrentUser();
            final id = goal.id.trim();
            if (id.isEmpty ||
                id == 'pending' ||
                id == 'synced' ||
                remoteDocIds.contains(goal.id) ||
                protectedDocIds.contains(goal.id)) {
              continue;
            }
            await (_db.delete(
              _db.goals,
            )..where((t) => t.id.equals(goal.id))).go();
            requireCurrentUser();
          }
        },
      );
      AppLogger.i("SYNC Metas: Concluído.");
    } on _GoalSessionChanged {
      return;
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
