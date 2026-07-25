import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:drift/drift.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/database_provider.dart';
import '../domain/entities/goal_entity.dart';
import 'package:life_os/core/security/input_sanitizer.dart';
import 'package:uuid/uuid.dart';

final goalsActionProvider = Provider(
  (ref) => GoalsActions(
    ref.watch(databaseProvider),
    FirebaseFirestore.instance,
    FirebaseAuth.instance,
  ),
);

final goalsStreamProvider = StreamProvider.autoDispose<List<GoalEntity>>((ref) {
  return ref.watch(goalsActionProvider).getGoalsStream();
});

class GoalsActions {
  final AppDatabase _db;
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;
  final _uuid = const Uuid();

  GoalsActions(this._db, this._firestore, this._auth);

  Stream<List<GoalEntity>> getGoalsStream() {
    return _db
        .select(_db.goals)
        .watch()
        .map(
          (rows) => rows
              .map(
                (r) => GoalEntity(
                  id: r.id,
                  title: r.title,
                  period: r.period,
                  currentValue: r.currentValue,
                  targetValue: r.targetValue,
                  createdAt: DateTime.fromMillisecondsSinceEpoch(r.createdAt),
                  lastReset: DateTime.fromMillisecondsSinceEpoch(r.lastReset),
                ),
              )
              .toList(),
        );
  }

  Future<void> syncGoalsFromFirebaseToLocal() async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;

    final snapshot = await _firestore
        .collection('users')
        .doc(uid)
        .collection('goals')
        .get();
    for (var doc in snapshot.docs) {
      final data = doc.data();
      await _db
          .into(_db.goals)
          .insertOnConflictUpdate(
            GoalsCompanion(
              id: Value(doc.id),
              title: Value(data['title']),
              period: Value(data['period']),
              currentValue: Value(data['currentValue']),
              targetValue: Value(data['targetValue']),
              createdAt: Value(
                (data['createdAt'] as Timestamp).millisecondsSinceEpoch,
              ),
              lastReset: Value(
                (data['lastReset'] as Timestamp).millisecondsSinceEpoch,
              ),
            ),
          );
    }
  }

  Future<void> createGoal(String title, String period, int targetValue) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;
    final id = _uuid.v4();
    final cleanTitle = InputSanitizer.sanitize(title);
    final now = DateTime.now();

    // Local
    await _db
        .into(_db.goals)
        .insert(
          GoalsCompanion.insert(
            id: id,
            title: cleanTitle,
            period: period,
            currentValue: 0,
            targetValue: targetValue,
            createdAt: now.millisecondsSinceEpoch,
            lastReset: now.millisecondsSinceEpoch,
          ),
        );

    // Firebase
    await _firestore
        .collection('users')
        .doc(uid)
        .collection('goals')
        .doc(id)
        .set({
          'title': cleanTitle,
          'period': period,
          'currentValue': 0,
          'targetValue': targetValue,
          'createdAt': FieldValue.serverTimestamp(),
          'lastReset': FieldValue.serverTimestamp(),
        });
  }

  Future<void> updateGoalProgress(String id, int newValue) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;

    await (_db.update(_db.goals)..where((t) => t.id.equals(id))).write(
      GoalsCompanion(currentValue: Value(newValue)),
    );
    await _firestore
        .collection('users')
        .doc(uid)
        .collection('goals')
        .doc(id)
        .update({'currentValue': newValue});
  }

  Future<void> resetGoalCycle(String id) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;
    final now = DateTime.now();

    await (_db.update(_db.goals)..where((t) => t.id.equals(id))).write(
      GoalsCompanion(
        currentValue: const Value(0),
        lastReset: Value(now.millisecondsSinceEpoch),
      ),
    );
    await _firestore
        .collection('users')
        .doc(uid)
        .collection('goals')
        .doc(id)
        .update({'currentValue': 0, 'lastReset': FieldValue.serverTimestamp()});
  }

  Future<void> removeGoal(String id) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;

    await (_db.delete(_db.goals)..where((t) => t.id.equals(id))).go();
    await _firestore
        .collection('users')
        .doc(uid)
        .collection('goals')
        .doc(id)
        .delete();
  }
}
