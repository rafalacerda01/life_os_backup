import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:drift/drift.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/utils/app_logger.dart';

class CheckInRepository {
  final AppDatabase _db;
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  // ===========================================================================
  // INJEÇÃO DE DEPENDÊNCIA
  // ===========================================================================

  CheckInRepository(this._db, this._firestore, this._auth);

  // ===========================================================================
  // 1. LEITURA
  //
  // A UI consome exclusivamente o Drift.
  // O Firebase não é consultado diretamente pela interface.
  // ===========================================================================

  Stream<List<CheckInEntry>> watchCheckIns() {
    return _db.watchAllCheckIns().map((items) => items.cast<CheckInEntry>());
  }

  // ===========================================================================
  // 2. ESCRITA OFFLINE-FIRST
  // ===========================================================================

  Future<void> saveDailyMetrics({
    required double energy,
    required double focus,
    required double motivation,
  }) async {
    final user = _auth.currentUser;

    if (user == null) {
      AppLogger.w('Tentativa de salvar check-in sem usuário autenticado.');
      return;
    }

    try {
      final now = DateTime.now();

      // Um check-in por dia.
      final todayId = DateFormat('yyyy-MM-dd').format(now);

      // -----------------------------------------------------------------------
      // PASSO A
      // Salva imediatamente no Drift.
      // -----------------------------------------------------------------------

      await _db.insertCheckIn(
        CheckInTableCompanion(
          id: Value(todayId),
          energy: Value(energy),
          focus: Value(focus),
          motivation: Value(motivation),
          createdAt: Value(now),
          isSynced: const Value(false),
        ),
      );

      AppLogger.i('Check-in salvo localmente: $todayId');

      // -----------------------------------------------------------------------
      // PASSO B
      // Tenta sincronizar em background.
      // -----------------------------------------------------------------------

      unawaited(
        _syncWithFirebase(
          userId: user.uid,
          checkInId: todayId,
          energy: energy,
          focus: focus,
          motivation: motivation,
        ),
      );
    } catch (error, stackTrace) {
      AppLogger.e('Erro ao salvar check-in localmente', error, stackTrace);

      rethrow;
    }
  }

  // ===========================================================================
  // 3. DOWNLOAD / HIDRATAÇÃO
  //
  // Firebase -> Drift
  // ===========================================================================

  Future<void> syncCheckinsFromFirebaseToLocal() async {
    final user = _auth.currentUser;

    if (user == null) {
      AppLogger.w('SYNC Check-ins ignorado: usuário não autenticado.');
      return;
    }

    try {
      AppLogger.i('SYNC Check-ins: iniciando download do Firebase...');

      final snapshot = await _firestore
          .collection('users')
          .doc(user.uid)
          .collection('checkins')
          .get();

      for (final doc in snapshot.docs) {
        final data = doc.data();

        final energy = (data['energy'] as num?)?.toDouble() ?? 0.0;

        final focus = (data['focus'] as num?)?.toDouble() ?? 0.0;

        final motivation = (data['motivation'] as num?)?.toDouble() ?? 0.0;

        final updatedAt = data['updatedAt'];

        final createdAt = updatedAt is Timestamp
            ? updatedAt.toDate()
            : DateTime.now();

        await _db
            .into(_db.checkInTable)
            .insertOnConflictUpdate(
              CheckInTableCompanion(
                id: Value(doc.id),
                energy: Value(energy),
                focus: Value(focus),
                motivation: Value(motivation),
                createdAt: Value(createdAt),
                isSynced: const Value(true),
              ),
            );
      }

      AppLogger.i(
        'SYNC Check-ins: download concluído. '
        '${snapshot.docs.length} registros processados.',
      );
    } catch (error, stackTrace) {
      AppLogger.e('SYNC Check-ins: erro durante download', error, stackTrace);
    }
  }

  // ===========================================================================
  // 4. UPLOAD DE UM CHECK-IN
  //
  // Drift -> Firebase
  // ===========================================================================

  Future<void> _syncWithFirebase({
    required String userId,
    required String checkInId,
    required double energy,
    required double focus,
    required double motivation,
  }) async {
    try {
      await _firestore
          .collection('users')
          .doc(userId)
          .collection('checkins')
          .doc(checkInId)
          .set({
            'energy': energy,
            'focus': focus,
            'motivation': motivation,
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));

      // Só marca como sincronizado depois da confirmação
      // do Firebase.
      await _db.markCheckInAsSynced(checkInId);

      AppLogger.i('Check-in sincronizado com sucesso: $checkInId');
    } catch (error, stackTrace) {
      // Não marca como sincronizado.
      //
      // O registro continua no Drift com isSynced = false
      // e poderá ser enviado posteriormente.
      AppLogger.e(
        'Erro ao sincronizar check-in.',
        error,
        stackTrace,
      );
    }
  }

  // ===========================================================================
  // 5. SINCRONIZAÇÃO DOS PENDENTES
  //
  // Envia registros que ficaram offline.
  // ===========================================================================

  Future<void> syncPendingCheckIns() async {
    final user = _auth.currentUser;

    if (user == null) {
      AppLogger.w('SYNC pendentes ignorado: usuário não autenticado.');
      return;
    }

    try {
      final pendingList = await _db.getPendingCheckIns();

      if (pendingList.isEmpty) {
        AppLogger.i('SYNC Check-ins: nenhum registro pendente.');
        return;
      }

      AppLogger.i(
        'SYNC Check-ins: ${pendingList.length} registro(s) pendente(s).',
      );

      for (final checkIn in pendingList) {
        await _syncWithFirebase(
          userId: user.uid,
          checkInId: checkIn.id,
          energy: checkIn.energy,
          focus: checkIn.focus,
          motivation: checkIn.motivation,
        );
      }

      AppLogger.i('SYNC Check-ins: processamento dos pendentes concluído.');
    } catch (error, stackTrace) {
      AppLogger.e('Erro ao processar check-ins pendentes', error, stackTrace);
    }
  }
}
