import 'package:life_os/core/services/generational_read_policy.dart';
import 'dart:async';
import 'package:life_os/core/database/local_account_session.dart';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import 'package:life_os/core/utils/app_logger.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/services/sync_manager.dart';
import 'package:life_os/core/database/database_sync_policy.dart';
import 'package:life_os/core/database/local_mutation_gate.dart';
import 'package:life_os/features/study/data/study_repository.dart';

class FocusRepository {
  final AppDatabase _db;
  final FirebaseFirestore? _remoteFirestore;
  final FirebaseAuth? _remoteAuth;
  final SyncManager? _remoteSyncManager;
  FirebaseFirestore get _firestore =>
      _remoteFirestore ?? (throw const LocalRemoteSyncDisabled());
  FirebaseAuth get _auth =>
      _remoteAuth ?? (throw const LocalRemoteSyncDisabled());
  SyncManager get _syncManager =>
      _remoteSyncManager ?? (throw const LocalRemoteSyncDisabled());
  final _uuid = const Uuid();

  final LocalAccountLease? sessionLease;
  FocusRepository(
    this._db,
    FirebaseFirestore firestore,
    FirebaseAuth auth,
    SyncManager syncManager, {
    this.sessionLease,
  }) : _remoteFirestore = firestore,
       _remoteAuth = auth,
       _remoteSyncManager = syncManager;

  FocusRepository.local(this._db)
    : _remoteFirestore = null,
      _remoteAuth = null,
      _remoteSyncManager = null,
      sessionLease = null {
    if (!_db.isLocalOnly)
      throw ArgumentError('LOCAL_PROFILE_SYNC_POLICY_REQUIRED');
  }

  /// A completed local cycle commits its log and target effect together.
  Future<void> completeLocalFocusSession({
    required String targetId,
    required String targetType,
    required int durationSeconds,
    required LocalMutationTicket admission,
  }) async {
    if (!_db.isLocalOnly)
      throw StateError('LOCAL_PROFILE_SYNC_POLICY_REQUIRED');
    if (targetId.trim().isEmpty ||
        durationSeconds <= 0 ||
        !const {'TASK', 'SUBJECT'}.contains(targetType)) {
      throw ArgumentError('INVALID_LOCAL_FOCUS_SESSION');
    }
    final owner = _db.identity!.uid;
    await _db.transactionWithCommitGuard(
      admission: admission,
      validateBeforeCommit: () =>
          _db.localMutations.capture(expectedUid: owner),
      () async {
        await _db
            .into(_db.focusLogs)
            .insert(
              FocusLogsCompanion.insert(
                targetId: targetId,
                targetType: targetType,
                durationSeconds: durationSeconds,
                timestamp: DateTime.now().millisecondsSinceEpoch,
              ),
            );
        if (targetType == 'TASK') {
          final changed =
              await (_db.update(_db.taskTable)
                    ..where((table) => table.id.equals(targetId)))
                  .write(const TaskTableCompanion(isCompleted: Value(true)));
          if (changed != 1) throw StateError('LOCAL_FOCUS_TARGET_UNAVAILABLE');
        } else {
          await StudyRepository.local(
            _db,
          ).addStudyTime(targetId, durationSeconds);
        }
      },
    );
  }

  // ===========================================================================
  // 1. ESCRITA (OFFLINE-FIRST)
  // ===========================================================================

  Future<void> saveFocusSession(
    String targetId,
    String targetType,
    int durationSeconds,
  ) async {
    if (_db.isLocalOnly) {
      return completeLocalFocusSession(
        targetId: targetId,
        targetType: targetType,
        durationSeconds: durationSeconds,
        admission: _db.localMutations.capture(expectedUid: _db.identity!.uid),
      );
    }
    final now = DateTime.now();
    final firebaseDocId = _uuid.v4();
    final ownerUid = _auth.currentUser?.uid;

    Future<void> insertLocal() async {
      await _db
          .into(_db.focusLogs)
          .insert(
            FocusLogsCompanion.insert(
              targetId: targetId,
              targetType: targetType,
              durationSeconds: durationSeconds,
              timestamp: now.millisecondsSinceEpoch,
            ),
          );
    }

    try {
      if (ownerUid == null) {
        await insertLocal();
      } else {
        await _db.transactionWithSync(
          localOperation: insertLocal,
          ownerUid: ownerUid,
          collection: 'focus_logs',
          docId: firebaseDocId,
          operationType: 'create',
          payloadJson: jsonEncode({
            'targetId': targetId,
            'targetType': targetType,
            'durationSeconds': durationSeconds,
            'timestamp': now.toUtc().toIso8601String(),
          }),
        );
        _schedulePendingFocusSync();
      }
    } catch (_) {
      AppLogger.w('Não foi possível salvar o log de foco localmente.');
      rethrow;
    }
  }

  // ===========================================================================
  // 2. SINCRONIZAÇÃO EM BACKGROUND (SYNC-DOWN / HIDRATAÇÃO)
  // ===========================================================================

  Future<void> syncFocusFromFirebaseToLocal() async {
    if (_db.isLocalOnly) return;
    final user = _auth.currentUser;
    if (user == null) return;
    final admission = _db.localMutations.capture(expectedUid: user.uid);

    try {
      AppLogger.i("SYNC Focus: Iniciando...");
      await GenerationalReadPolicy.verify(
        identity: _db.identity,
        lease: sessionLease,
        auth: _auth,
        store: _firestore,
        expectedUid: user.uid,
      );
      final snapshot = await _firestore
          .collection('users')
          .doc(user.uid)
          .collection('focus_logs')
          .get(GenerationalReadPolicy.options(_db.identity, _firestore));
      if (_db.identity?.generation != null &&
          !GenerationalReadPolicy.accepts(
            _db.identity,
            fromCache: snapshot.metadata.isFromCache,
            pendingWrites: snapshot.metadata.hasPendingWrites,
          )) {
        throw StateError('GENERATIONAL_SNAPSHOT_UNCONFIRMED');
      }

      await GenerationalReadPolicy.verify(
        identity: _db.identity,
        lease: sessionLease,
        auth: _auth,
        store: _firestore,
        expectedUid: user.uid,
      );
      await _db.transactionWithCommitGuard(
        admission: admission,
        waitForReopen: false,
        validateBeforeCommit: () => GenerationalReadPolicy.requireCurrent(
          identity: _db.identity,
          lease: sessionLease,
          auth: _auth,
          expectedUid: user.uid,
        ),
        () async {
          for (var doc in snapshot.docs) {
            final data = doc.data();

            final timestampStr = data['timestamp'];
            if (timestampStr == null) continue;

            final timestamp = (timestampStr as Timestamp)
                .toDate()
                .millisecondsSinceEpoch;
            final targetId = data['targetId'] as String? ?? '';

            // Prevenção de duplicatas: Verifica se esse exato log já existe localmente
            final existing =
                await (_db.select(_db.focusLogs)
                      ..where((t) => t.timestamp.equals(timestamp))
                      ..where((t) => t.targetId.equals(targetId)))
                    .get();

            if (existing.isEmpty) {
              await _db.localMutations.run(
                () => _db
                    .into(_db.focusLogs)
                    .insert(
                      FocusLogsCompanion.insert(
                        targetId: targetId,
                        targetType: data['targetType'] as String? ?? 'unknown',
                        durationSeconds: data['durationSeconds'] as int? ?? 0,
                        timestamp: timestamp,
                      ),
                    ),
                ticket: admission,
                waitForReopen: false,
              );
            }
          }
        },
      );
      AppLogger.i("SYNC Focus: Concluído com sucesso.");
    } catch (e, stack) {
      AppLogger.e("SYNC Focus: ERRO CRÍTICO", e, stack);
    }
  }

  void _schedulePendingFocusSync() {
    unawaited(
      _syncManager.processPendingItems().catchError((Object _, StackTrace _) {
        AppLogger.w('Não foi possível enviar logs de foco pendentes agora.');
        return false;
      }),
    );
  }
}
