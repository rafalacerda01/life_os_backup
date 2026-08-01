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
  // 2. SINCRONIZAÇÃO EM BACKGROUND
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
