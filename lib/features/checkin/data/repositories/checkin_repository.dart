import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:drift/drift.dart';

// 🚀 IMPORTANTE: Ajuste este import para o caminho correto do seu AppDatabase
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/database_provider.dart';

// 1. Precisamos garantir que o Provider do Repositório receba o banco de dados.
// Assumindo que você tenha um `appDatabaseProvider` global.
// Se não tiver, crie um: final appDatabaseProvider = Provider((ref) => AppDatabase());
final checkInRepositoryProvider = Provider<CheckInRepository>((ref) {
  final db = ref.watch(databaseProvider);
  return CheckInRepository(db);
});

class CheckInRepository {
  final AppDatabase _db;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  // Injeção de dependência do banco local
  CheckInRepository(this._db);

  // ===========================================================================
  // 1. LEITURA (UI CONSOME APENAS DO DRIFT)
  // ===========================================================================

  /// Retorna um fluxo em tempo real do histórico de check-ins local
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
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception("Usuário não autenticado.");
    }

    // Geração do ID fixo baseado na data atual (YYYY-MM-DD)
    final todayId = DateFormat('yyyy-MM-dd').format(DateTime.now());

    // PASSO A: Salva no banco local (Drift) instantaneamente
    // O usuário já pode seguir utilizando o app sem travar a tela
    await _db.insertCheckIn(
      CheckInTableCompanion(
        id: Value(todayId),
        energy: Value(energy),
        focus: Value(focus),
        motivation: Value(motivation),
        createdAt: Value(DateTime.now()),
        isSynced: const Value(false), // 👈 Fica como false inicialmente
      ),
    );

    // PASSO B: Dispara a sincronização com o Firebase em background (Fire-and-Forget)
    // Note que não usamos 'await' aqui. Se falhar por falta de rede, não afeta a UI.
    _syncWithFirebase(
      userId: user.uid,
      checkInId: todayId,
      energy: energy,
      focus: focus,
      motivation: motivation,
    );
  }

  // ===========================================================================
  // 3. SINCRONIZAÇÃO EM BACKGROUND
  // ===========================================================================

  /// Método privado para tentar enviar o dado para a nuvem
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

      // PASSO C: Se o Firebase confirmou o salvamento, atualizamos a flag no Drift
      await _db.markCheckInAsSynced(checkInId);
    } catch (e) {
      // Se não houver internet, cai aqui. Silenciamos o erro intencionalmente.
      // O dado está seguro no Drift e será sincronizado posteriormente.
    }
  }

  /// Método para ser chamado ao abrir o app ou no "Pull-to-refresh"
  /// Varre o banco local atrás de check-ins órfãos e os envia para a nuvem.
  Future<void> syncPendingCheckIns() async {
    final user = _auth.currentUser;
    if (user == null) return;

    final pendingList = await _db.getPendingCheckIns();

    for (var checkIn in pendingList) {
      await _syncWithFirebase(
        userId: user.uid,
        checkInId: checkIn.id,
        energy: checkIn.energy,
        focus: checkIn.focus,
        motivation: checkIn.motivation,
      );
    }
  }
}
