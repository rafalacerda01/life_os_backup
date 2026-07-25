import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:drift/drift.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/database_provider.dart'; // Certifique-se que este arquivo existe
import 'package:life_os/features/habits/data/models/habit_model.dart';
import 'package:uuid/uuid.dart';

// 1. PROVIDER DO REPOSITÓRIO
final habitsRepositoryProvider = Provider((ref) {
  return HabitsRepository(
    ref.watch(databaseProvider),
    FirebaseFirestore.instance,
    FirebaseAuth.instance,
  );
});

// 2. STREAM PROVIDER: Agora escuta o banco LOCAL (Drift)
final habitsStreamProvider = StreamProvider<List<HabitModel>>((ref) {
  return ref.watch(habitsRepositoryProvider).getHabitsStream();
});

// 3. REPOSITÓRIO
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
    final user = _auth.currentUser;
    if (user == null) return;

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

    await _firestore
        .collection('users')
        .doc(user.uid)
        .collection('habits')
        .doc(id)
        .set({'title': title, 'completedDates': dates});
  }

  Future<void> toggleHabitToday(
    String habitId,
    List<String> currentDates,
  ) async {
    final user = _auth.currentUser;
    if (user == null) return;

    // Lógica local para toggle
    // (Importante: 'yyyy-MM-dd' precisa coincidir com o formato que você salva no Firestore)
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

    await _firestore
        .collection('users')
        .doc(user.uid)
        .collection('habits')
        .doc(habitId)
        .update({'completedDates': updatedDates});
  }

  Future<void> deleteHabit(String habitId) async {
    final user = _auth.currentUser;
    if (user == null) return;

    await (_db.delete(_db.habits)..where((t) => t.id.equals(habitId))).go();
    await _firestore
        .collection('users')
        .doc(user.uid)
        .collection('habits')
        .doc(habitId)
        .delete();
  }
}
