import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:drift/drift.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/utils/app_logger.dart';
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
    if (_auth.currentUser == null) return;

    try {
      final id = _uuid.v4();
      final dates = <String>[];

      await _db
          .into(_db.habits)
          .insert(
            HabitsCompanion.insert(
              id: id,
              title: title,
              completedDates: jsonEncode(dates),
            ),
          );

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
    if (_auth.currentUser == null) return;

    try {
      final todayStr = DateTime.now().toIso8601String().split('T')[0];
      List<String> updatedDates = List.from(currentDates);

      if (updatedDates.contains(todayStr)) {
        updatedDates.remove(todayStr);
      } else {
        updatedDates.add(todayStr);
      }

      await (_db.update(_db.habits)..where((t) => t.id.equals(habitId))).write(
        HabitsCompanion(completedDates: Value(jsonEncode(updatedDates))),
      );

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

  // 🚀 NOVO MÉTODO: Permite atualizar e alternar qualquer dia da semana na matriz interativa
  Future<void> updateHabitDates(String habitId, List<String> newDates) async {
    if (_auth.currentUser == null) return;

    try {
      // 1. Atualiza localmente primeiro (Drift)
      await (_db.update(_db.habits)..where((t) => t.id.equals(habitId))).write(
        HabitsCompanion(completedDates: Value(jsonEncode(newDates))),
      );

      // 2. Dispara pro Firestore em background
      unawaited(_updateHabitInFirestore(habitId, newDates));
    } catch (error, stackTrace) {
      AppLogger.e(
        'Erro ao atualizar datas do hábito localmente',
        error,
        stackTrace,
      );
      rethrow;
    }
  }

  Future<void> deleteHabit(String habitId, String habitTitle) async {
    // 🔒 Trava de segurança: exige usuário logado
    if (_auth.currentUser == null) return;

    try {
      // 1. Deleta o hábito localmente no Drift pelo ID
      await (_db.delete(_db.habits)..where((t) => t.id.equals(habitId))).go();

      // 2. Limpeza profunda no Drift: Apaga qualquer notificação relacionada ao ID ou ao Título do Hábito
      await (_db.delete(_db.notificationsTable)..where(
            (t) =>
                t.id.equals(habitId) |
                t.id.equals('habit_$habitId') |
                t.title.like('%$habitTitle%'),
          ))
          .go();

      // 3. Deleta no Firestore (Hábito e Notificações) e aguarda
      try {
        final userId = _auth.currentUser!.uid;
        final batch = _firestore.batch();

        final habitDoc = _firestore
            .collection('users')
            .doc(userId)
            .collection('habits')
            .doc(habitId);
        final notifDoc1 = _firestore
            .collection('users')
            .doc(userId)
            .collection('notifications')
            .doc(habitId);
        final notifDoc2 = _firestore
            .collection('users')
            .doc(userId)
            .collection('notifications')
            .doc('habit_$habitId');

        batch.delete(habitDoc);
        batch.delete(notifDoc1);
        batch.delete(notifDoc2);

        await batch.commit().timeout(const Duration(seconds: 5));
      } catch (e) {
        AppLogger.e(
          'Aviso: Falha ao apagar na nuvem, mas foi limpo localmente',
          e,
        );
      }
    } catch (error, stackTrace) {
      AppLogger.e('Erro ao deletar hábito completamente', error, stackTrace);
      rethrow;
    }
  }

  // 🚀 Método auxiliar para limpar a notificação do hábito no Firestore
  Future<void> _deleteNotificationFromFirestore(String habitId) async {
    final userId = _auth.currentUser?.uid;
    if (userId == null) return;

    try {
      final batch = _firestore.batch();

      final notifDoc1 = _firestore
          .collection('users')
          .doc(userId)
          .collection('notifications')
          .doc(habitId);
      final notifDoc2 = _firestore
          .collection('users')
          .doc(userId)
          .collection('notifications')
          .doc('habit_$habitId');

      batch.delete(notifDoc1);
      batch.delete(notifDoc2);

      await batch.commit();
    } catch (error, stackTrace) {
      AppLogger.e(
        'Erro ao deletar notificação do hábito no Firestore',
        error,
        stackTrace,
      );
    }
  }

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
