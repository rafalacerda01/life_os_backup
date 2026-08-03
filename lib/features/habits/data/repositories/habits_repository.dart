import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:drift/drift.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/utils/app_logger.dart'; // 🚀 Nosso Logger de produção
import 'package:life_os/features/habits/data/models/habit_model.dart';
import 'package:uuid/uuid.dart';

class HabitsRepository {
  final AppDatabase _db;
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;
  final _uuid = const Uuid();

  HabitsRepository(this._db, this._firestore, this._auth);

  Stream<List<HabitModel>> getHabitsStream() {
    return _db.select(_db.habits).watch().map((rows) {
      return rows.map((row) {
        return HabitModel(
          id: row.id,
          title: row.title,
          completedDates: List<String>.from(jsonDecode(row.completedDates)),
        );
      }).toList();
    });
  }

  Future<void> addHabit(String title) async {
    // 🔒 Trava de segurança: exige usuário logado
    if (_auth.currentUser == null) return;

    try {
      final id = _uuid.v4();
      final dates = <String>[];

      // 1. Salva localmente primeiro (Resposta instantânea na UI)
      await _db
          .into(_db.habits)
          .insert(
            HabitsCompanion.insert(
              id: id,
              title: title,
              completedDates: jsonEncode(dates),
            ),
          );

      // 2. Dispara pro Firestore em background (Não bloqueia o app se estiver sem rede)
      unawaited(_saveHabitToFirestore(id, title, dates));
    } catch (error, stackTrace) {
      AppLogger.e('Erro ao criar hábito localmente', error, stackTrace);
      rethrow;
    }
  }

  Future<void> toggleHabitToday(
    String habitId,
    List<String> currentDates,
  ) async {
    // 🔒 Trava de segurança: exige usuário logado
    if (_auth.currentUser == null) return;

    try {
      final todayStr = DateTime.now().toIso8601String().split('T')[0];
      List<String> updatedDates = List.from(currentDates);

      if (updatedDates.contains(todayStr)) {
        updatedDates.remove(todayStr);
      } else {
        updatedDates.add(todayStr);
      }

      // 1. Atualiza localmente primeiro
      await (_db.update(_db.habits)..where((t) => t.id.equals(habitId))).write(
        HabitsCompanion(completedDates: Value(jsonEncode(updatedDates))),
      );

      // 2. Dispara pro Firestore em background
      unawaited(_updateHabitInFirestore(habitId, updatedDates));
    } catch (error, stackTrace) {
      AppLogger.e(
        'Erro ao alternar status do hábito localmente',
        error,
        stackTrace,
      );
      rethrow;
    }
  }

  Future<void> deleteHabit(String habitId) async {
    // 🔒 Trava de segurança: exige usuário logado
    if (_auth.currentUser == null) return;

    try {
      // 1. Deleta localmente primeiro
      await (_db.delete(_db.habits)..where((t) => t.id.equals(habitId))).go();

      // 2. Deleta no Firestore em background
      unawaited(_deleteHabitFromFirestore(habitId));
    } catch (error, stackTrace) {
      AppLogger.e('Erro ao deletar hábito localmente', error, stackTrace);
      rethrow;
    }
  }

  // ===========================================================================
  // 🚀 SINCRONIZAÇÃO EM BACKGROUND (SYNC-DOWN / HIDRATAÇÃO)
  // ===========================================================================

  Future<void> syncHabitsFromFirebaseToLocal() async {
    final userId = _auth.currentUser?.uid;
    if (userId == null) return;

    try {
      AppLogger.i('SYNC Hábitos: Iniciando...');
      final snapshot = await _firestore
          .collection('users')
          .doc(userId)
          .collection('habits')
          .get();

      for (var doc in snapshot.docs) {
        final data = doc.data();

        // Converte a lista dinâmica que vem do Firestore de volta para List<String>
        final rawDates = data['completedDates'] as List<dynamic>? ?? [];
        final dates = rawDates.map((e) => e.toString()).toList();

        await _db
            .into(_db.habits)
            .insertOnConflictUpdate(
              HabitsCompanion.insert(
                id: doc.id,
                title: data['title'] ?? 'Sem título',
                completedDates: jsonEncode(dates),
              ),
            );
      }
      AppLogger.i('SYNC Hábitos: Concluído com sucesso.');
    } catch (error, stackTrace) {
      AppLogger.e('SYNC Hábitos: ERRO CRÍTICO', error, stackTrace);
    }
  }

  // --- Métodos Privados para Sincronização com o Firestore ---

  Future<void> _saveHabitToFirestore(
    String id,
    String title,
    List<String> dates,
  ) async {
    final userId = _auth.currentUser?.uid;
    if (userId == null) return;

    try {
      await _firestore
          .collection('users')
          .doc(userId)
          .collection('habits')
          .doc(id)
          .set({
            'title': title,
            'completedDates': dates,
          }, SetOptions(merge: true));
    } catch (error, stackTrace) {
      // Em falta de internet, o Firebase enfileira. Logamos caso falhe de vez.
      AppLogger.e(
        'Erro de sincronização: criar hábito no Firestore',
        error,
        stackTrace,
      );
    }
  }

  Future<void> _updateHabitInFirestore(
    String habitId,
    List<String> updatedDates,
  ) async {
    final userId = _auth.currentUser?.uid;
    if (userId == null) return;

    try {
      await _firestore
          .collection('users')
          .doc(userId)
          .collection('habits')
          .doc(habitId)
          .update({'completedDates': updatedDates});
    } catch (error, stackTrace) {
      AppLogger.e(
        'Erro de sincronização: atualizar hábito no Firestore',
        error,
        stackTrace,
      );
    }
  }

  Future<void> _deleteHabitFromFirestore(String habitId) async {
    final userId = _auth.currentUser?.uid;
    if (userId == null) return;

    try {
      await _firestore
          .collection('users')
          .doc(userId)
          .collection('habits')
          .doc(habitId)
          .delete();
    } catch (error, stackTrace) {
      AppLogger.e(
        'Erro de sincronização: deletar hábito no Firestore',
        error,
        stackTrace,
      );
    }
  }
}
