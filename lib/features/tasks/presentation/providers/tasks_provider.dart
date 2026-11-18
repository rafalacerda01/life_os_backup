import 'package:life_os/core/database/local_account_session.dart';
import 'package:life_os/core/services/trusted_account_access.dart';
import 'package:uuid/uuid.dart';
import 'dart:async';
import 'package:life_os/core/services/firebase_auth_provider.dart';
import 'package:life_os/core/services/emulator_account_runtime.dart';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:drift/drift.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/database_provider.dart';
import 'package:life_os/core/database/database_sync_policy.dart';
import 'package:life_os/core/runtime/app_runtime_mode.dart';
import 'package:life_os/features/premium/domain/services/plan_limits.dart';
import 'package:life_os/features/premium/domain/services/quota_service.dart';
import 'package:life_os/core/utils/app_logger.dart';
import 'package:life_os/features/settings/presentation/providers/analytics_provider.dart';
import 'package:life_os/features/tasks/data/models/task_model.dart';

// ============================================================================
// REPOSITORY PROVIDER
// ============================================================================

final tasksRepositoryProvider = Provider((ref) {
  final db = ref.watch(databaseProvider);

  if (db.isLocalOnly) return TasksRepository.local(db);

  final session = ref.watch(localAccountSessionProvider);
  return TasksRepository(
    db,
    ref.watch(firebaseFirestoreProvider),
    ref.watch(firebaseAuthProvider),
    sessionLease:
        db.identity?.isBound == true && session.identity == db.identity
        ? ref.read(localAccountSessionProvider.notifier).capture()
        : null,
  );
});

typedef ManualTaskStatusToggle =
    Future<void> Function(String taskId, bool currentStatus);

final manualTaskStatusToggleProvider = Provider<ManualTaskStatusToggle>((ref) {
  final repository = ref.watch(tasksRepositoryProvider);
  if (ref.watch(appRuntimeModeProvider) == AppRuntimeMode.localFirst) {
    return repository.toggleTaskStatus;
  }
  if (ref.watch(emulatorAccountRuntimeProvider) != null) {
    return (taskId, currentStatus) =>
        repository.toggleTaskStatus(taskId, currentStatus);
  }
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

final tasksStreamProvider = StreamProvider.autoDispose<List<TaskModel>>((ref) {
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
  final FirebaseFirestore? _remoteFirestore;
  final FirebaseAuth? _remoteAuth;
  FirebaseFirestore get _firestore =>
      _remoteFirestore ?? (throw const LocalRemoteSyncDisabled());
  FirebaseAuth get _auth =>
      _remoteAuth ?? (throw const LocalRemoteSyncDisabled());
  String? get _ownerUid =>
      _db.isLocalOnly ? _db.identity?.uid : _remoteAuth?.currentUser?.uid;

  final LocalAccountLease? sessionLease;
  TasksRepository(
    this._db,
    FirebaseFirestore firestore,
    FirebaseAuth auth, {
    this.sessionLease,
  }) : _remoteFirestore = firestore,
       _remoteAuth = auth;

  TasksRepository.local(this._db)
    : _remoteFirestore = null,
      _remoteAuth = null,
      sessionLease = null {
    if (!_db.isLocalOnly)
      throw ArgumentError('LOCAL_PROFILE_SYNC_POLICY_REQUIRED');
  }

  Future<void> _enforceLocalFreeQuota() async {
    if (!_db.isLocalOnly) return;
    // Development local mode is Free until a verified hybrid entitlement
    // authority exists. No preference or boolean can grant Premium here.
    final limit = PlanLimits.free.tasks;
    final count = _db.taskTable.id.count();
    final value = await (_db.selectOnly(
      _db.taskTable,
    )..addColumns([count])).map((row) => row.read(count) ?? 0).getSingle();
    if (!const QuotaService().canCreate(limit: limit, currentCount: value)) {
      throw PlanQuotaExceeded(QuotaResource.tasks, limit.maximum);
    }
  }

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
    if (_db.isLocalOnly) return;
    final expectedUid = _auth.currentUser?.uid.trim();
    if (expectedUid == null || expectedUid.isEmpty) return;
    final ticket = _db.localMutations.capture(expectedUid: expectedUid);

    try {
      Future<void> verifyGeneration() async {
        if (_db.identity?.isBound != true) return;
        final lease = sessionLease;
        if (lease == null || lease.identity != _db.identity) {
          throw StateError('TASKS_READ_CUSTODY_REQUIRED');
        }
        lease.requireCurrent();
        final admitted = await TrustedAccountAccess.admittedIdentity(
          _auth,
          _firestore,
          expectedUid,
        );
        lease.requireCurrent();
        if (admitted != _db.identity) throw const _TaskSessionChanged();
      }

      await verifyGeneration();
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
      if (_db.identity?.isBound == true &&
          (snapshot.metadata.isFromCache || snapshot.metadata.hasPendingWrites))
        return;
      await verifyGeneration();
      final remoteDocIds = snapshot.docs.map((doc) => doc.id).toSet();

      await _db.transactionWithCommitGuard(
        admission: ticket,
        waitForReopen: false,
        validateBeforeCommit: () {
          sessionLease?.requireCurrent();
          if (_auth.currentUser?.uid != expectedUid)
            throw const _TaskSessionChanged();
        },
        () async {
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
        },
      );
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
    final ownerUid = _ownerUid;

    if (ownerUid == null) {
      throw Exception('Usuário não autenticado');
    }

    if (_db.isLocalOnly) {
      title = title.trim();
      if (title.isEmpty ||
          !const {'low', 'medium', 'high'}.contains(priority)) {
        throw ArgumentError('TASK_INPUT_INVALID');
      }
    }

    final id = const Uuid().v4();

    final createdAt = DateTime.now();

    try {
      await _db.transactionWithSync(
        ownerUid: ownerUid,
        localOperation: () async {
          await _enforceLocalFreeQuota();
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
    final ownerUid = _ownerUid;

    if (ownerUid == null) {
      return;
    }

    final newStatus = !currentStatus;

    try {
      await _db.transactionWithSync(
        ownerUid: ownerUid,
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
    final ownerUid = _ownerUid;

    if (ownerUid == null) {
      return;
    }

    try {
      await _db.transactionWithSync(
        ownerUid: ownerUid,
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
