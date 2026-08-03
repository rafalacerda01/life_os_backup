import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import 'package:life_os/core/utils/app_logger.dart';
import 'package:life_os/core/database/app_database.dart';

class FocusRepository {
  final AppDatabase _db;
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;
  final _uuid = const Uuid();

  FocusRepository(this._db, this._firestore, this._auth);

  // ===========================================================================
  // 1. ESCRITA (OFFLINE-FIRST)
  // ===========================================================================

  Future<void> saveFocusSession(
    String targetId,
    String targetType,
    int durationSeconds,
  ) async {
    final now = DateTime.now();
    // Como não sabemos se sua tabela local tem coluna de ID string,
    // deixamos o Drift gerenciar o ID local e usamos UUID para o Firebase
    final firebaseDocId = _uuid.v4();

    try {
      // 1. Salva Localmente
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

      // 2. Envia para o Firebase em Background
      if (_auth.currentUser != null) {
        unawaited(
          _saveFocusSessionToFirestore(
            firebaseDocId,
            targetId,
            targetType,
            durationSeconds,
            now,
          ),
        );
      }
    } catch (e, stack) {
      AppLogger.e('Erro ao salvar log de foco localmente', e, stack);
      rethrow;
    }
  }

  // ===========================================================================
  // 2. SINCRONIZAÇÃO EM BACKGROUND (SYNC-DOWN / HIDRATAÇÃO)
  // ===========================================================================

  Future<void> syncFocusFromFirebaseToLocal() async {
    final user = _auth.currentUser;
    if (user == null) return;

    try {
      AppLogger.i("SYNC Focus: Iniciando...");
      final snapshot = await _firestore
          .collection('users')
          .doc(user.uid)
          .collection('focus_logs')
          .get();

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
          await _db
              .into(_db.focusLogs)
              .insert(
                FocusLogsCompanion.insert(
                  targetId: targetId,
                  targetType: data['targetType'] as String? ?? 'unknown',
                  durationSeconds: data['durationSeconds'] as int? ?? 0,
                  timestamp: timestamp,
                ),
              );
        }
      }
      AppLogger.i("SYNC Focus: Concluído com sucesso.");
    } catch (e, stack) {
      AppLogger.e("SYNC Focus: ERRO CRÍTICO", e, stack);
    }
  }

  // ===========================================================================
  // 3. SINCRONIZAÇÃO EM BACKGROUND (SYNC-UP)
  // ===========================================================================

  Future<void> _saveFocusSessionToFirestore(
    String docId,
    String targetId,
    String targetType,
    int durationSeconds,
    DateTime timestamp,
  ) async {
    try {
      await _firestore
          .collection('users')
          .doc(_auth.currentUser!.uid)
          .collection('focus_logs')
          .doc(docId)
          .set({
            'targetId': targetId,
            'targetType': targetType,
            'durationSeconds': durationSeconds,
            'timestamp': Timestamp.fromDate(timestamp),
          }, SetOptions(merge: true));
    } catch (e, stack) {
      AppLogger.e('Sync Error: Salvar log de foco no Firebase', e, stack);
    }
  }
}
