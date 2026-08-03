import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:drift/drift.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/utils/app_logger.dart'; // 🚀 Nosso Logger de produção

class CheckInRepository {
  final AppDatabase _db;
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  // 💉 Injeção de dependência completa para testabilidade
  CheckInRepository(this._db, this._firestore, this._auth);

  // ===========================================================================
  // 1. LEITURA (UI CONSOME APENAS DO DRIFT)
  // ===========================================================================

  Stream<List<CheckInEntry>> watchCheckIns() {
    return _db.watchAllCheckIns();
  }

  // ===========================================================================
  // 2. ESCRITA (OFFLINE-FIRST)
  // ===========================================================================

  Future<void> saveDailyMetrics({
    required double energy,
    required double focus,
    required double motivation,
  }) async {
    // 🔒 Trava de segurança: exige usuário logado
    if (_auth.currentUser == null) return;

    try {
      final todayId = DateFormat('yyyy-MM-dd').format(DateTime.now());

      // PASSO A: Salva no banco local (Drift) instantaneamente
      await _db.insertCheckIn(
        CheckInTableCompanion(
          id: Value(todayId),
          energy: Value(energy),
          focus: Value(focus),
          motivation: Value(motivation),
          createdAt: Value(DateTime.now()),
          isSynced: const Value(false),
        ),
      );

      // PASSO B: Dispara a sincronização com o Firebase em background
      unawaited(
        _syncWithFirebase(
          userId: _auth.currentUser!.uid,
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
  // 3. SINCRONIZAÇÃO EM BACKGROUND (SYNC-DOWN / HIDRATAÇÃO)
  // ===========================================================================

  Future<void> syncCheckinsFromFirebaseToLocal() async {
    final userId = _auth.currentUser?.uid;
    if (userId == null) return;

    try {
      AppLogger.i('SYNC Check-ins: Iniciando...');
      final snapshot = await _firestore
          .collection('users')
          .doc(userId)
          .collection('checkins')
          .get();

      for (var doc in snapshot.docs) {
        final data = doc.data();

        // Verifica se a tabela se chama checkInTable.
        // Caso seu AppDatabase use um nome diferente para a tabela (ex: checkIns), ajuste abaixo!
        await _db
            .into(_db.checkInTable)
            .insertOnConflictUpdate(
              CheckInTableCompanion(
                id: Value(doc.id),
                energy: Value((data['energy'] as num?)?.toDouble() ?? 0.0),
                focus: Value((data['focus'] as num?)?.toDouble() ?? 0.0),
                motivation: Value(
                  (data['motivation'] as num?)?.toDouble() ?? 0.0,
                ),
                createdAt: Value(
                  (data['updatedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
                ),
                isSynced: const Value(
                  true,
                ), // Chegou da nuvem, então já tá sincronizado!
              ),
            );
      }
      AppLogger.i('SYNC Check-ins: Concluído com sucesso.');
    } catch (error, stackTrace) {
      AppLogger.e('SYNC Check-ins: ERRO CRÍTICO', error, stackTrace);
    }
  }

  // ===========================================================================
  // 4. SINCRONIZAÇÃO EM BACKGROUND (SYNC-UP PENDENTES)
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

      // PASSO C: Confirmação e atualização local
      await _db.markCheckInAsSynced(checkInId);
    } catch (error, stackTrace) {
      // O dado está seguro no Drift. Logamos o erro silencioso para análise.
      AppLogger.e('Erro de sincronização: enviar check-in', error, stackTrace);
    }
  }

  Future<void> syncPendingCheckIns() async {
    final user = _auth.currentUser;
    if (user == null) return;

    try {
      final pendingList = await _db.getPendingCheckIns();

      for (var checkIn in pendingList) {
        // Envia sequencialmente os pendentes
        await _syncWithFirebase(
          userId: user.uid,
          checkInId: checkIn.id,
          energy: checkIn.energy,
          focus: checkIn.focus,
          motivation: checkIn.motivation,
        );
      }
    } catch (error, stackTrace) {
      AppLogger.e(
        'Erro ao varrer ou sincronizar check-ins pendentes',
        error,
        stackTrace,
      );
    }
  }
}
