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

class FocusRepository {
  final AppDatabase _db;
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;
  final SyncManager _syncManager;
  final _uuid = const Uuid();

  final LocalAccountLease? sessionLease;
  FocusRepository(this._db, this._firestore, this._auth, this._syncManager,{this.sessionLease});

  // ===========================================================================
  // 1. ESCRITA (OFFLINE-FIRST)
  // ===========================================================================

  Future<void> saveFocusSession(
    String targetId,
    String targetType,
    int durationSeconds,
  ) async {
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
    final user = _auth.currentUser;
    if (user == null) return;
    final admission = _db.localMutations.capture(expectedUid: user.uid);

    try {
      AppLogger.i("SYNC Focus: Iniciando...");
      await GenerationalReadPolicy.verify(identity:_db.identity,lease:sessionLease,auth:_auth,store:_firestore,expectedUid:user.uid);
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

      await GenerationalReadPolicy.verify(identity:_db.identity,lease:sessionLease,auth:_auth,store:_firestore,expectedUid:user.uid);
      await _db.transactionWithCommitGuard(admission:admission,waitForReopen:false,validateBeforeCommit:()=>GenerationalReadPolicy.requireCurrent(identity:_db.identity,lease:sessionLease,auth:_auth,expectedUid:user.uid),()async{
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
      });
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
