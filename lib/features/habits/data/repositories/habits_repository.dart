import 'package:life_os/core/database/local_account_session.dart';
import 'package:life_os/core/services/generational_read_policy.dart';
import 'dart:async';
import 'package:life_os/core/database/database_sync_policy.dart';
import 'package:life_os/core/security/input_sanitizer.dart';
import 'package:life_os/features/premium/domain/services/plan_limits.dart';
import 'package:life_os/features/premium/domain/services/quota_service.dart';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:drift/drift.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/utils/app_logger.dart';
import 'package:life_os/features/habits/data/models/habit_model.dart';
import 'package:uuid/uuid.dart';

class _HabitSessionChanged implements Exception {
  const _HabitSessionChanged();
}

class HabitsRepository {
  final LocalAccountLease? sessionLease;
  Future<void> _verifyRemoteRead(String uid) => GenerationalReadPolicy.verify(
    identity: _db.identity,
    lease: sessionLease,
    auth: _auth,
    store: _firestore,
    expectedUid: uid,
  );
  void _requireReadSession(String uid) => GenerationalReadPolicy.requireCurrent(
    identity: _db.identity,
    lease: sessionLease,
    auth: _auth,
    expectedUid: uid,
  );

  final AppDatabase _db;
  final FirebaseFirestore? _remoteFirestore;
  final FirebaseAuth? _remoteAuth;
  FirebaseFirestore get _firestore =>
      _remoteFirestore ?? (throw const LocalRemoteSyncDisabled());
  FirebaseAuth get _auth =>
      _remoteAuth ?? (throw const LocalRemoteSyncDisabled());
  String? get _ownerUid =>
      _db.isLocalOnly ? _db.identity?.uid : _remoteAuth?.currentUser?.uid;
  final _uuid = const Uuid();

  HabitsRepository(
    this._db,
    FirebaseFirestore firestore,
    FirebaseAuth auth, {
    this.sessionLease,
  }) : _remoteFirestore = firestore,
       _remoteAuth = auth;

  HabitsRepository.local(this._db)
    : _remoteFirestore = null,
      _remoteAuth = null,
      sessionLease = null {
    if (!_db.isLocalOnly)
      throw ArgumentError('LOCAL_PROFILE_SYNC_POLICY_REQUIRED');
  }

  Future<void> _enforceLocalFreeQuota() async {
    if (!_db.isLocalOnly) return;
    final limit = PlanLimits.free.habits;
    final count = _db.habits.id.count();
    final current = await (_db.selectOnly(
      _db.habits,
    )..addColumns([count])).map((row) => row.read(count) ?? 0).getSingle();
    if (!const QuotaService().canCreate(limit: limit, currentCount: current)) {
      throw PlanQuotaExceeded(QuotaResource.habits, limit.maximum);
    }
  }

  List<String> _validatedLocalDates(List<String> dates) {
    for (final date in dates) {
      final parsed = DateTime.tryParse(date);
      if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date) ||
          parsed == null ||
          parsed.toIso8601String().split('T').first != date) {
        throw ArgumentError('INVALID_HABIT_DATE');
      }
    }
    return dates.toSet().toList()..sort();
  }

  Future<void> _toggleLocalDate(String habitId, String date) async {
    final ownerUid = _ownerUid;
    if (ownerUid == null) throw StateError('LOCAL_PROFILE_REQUIRED');
    await _db.transactionWithSync(
      ownerUid: ownerUid,
      localOperation: () async {
        final row = await (_db.select(
          _db.habits,
        )..where((t) => t.id.equals(habitId))).getSingleOrNull();
        if (row == null) return;
        // Derive from the admitted transaction, never a stale UI snapshot.
        final dates = _validatedLocalDates(
          List<String>.from(jsonDecode(row.completedDates)),
        );
        if (!dates.remove(date)) dates.add(date);
        dates.sort();
        await (_db.update(_db.habits)..where((t) => t.id.equals(habitId)))
            .write(HabitsCompanion(completedDates: Value(jsonEncode(dates))));
      },
      collection: 'habits',
      docId: habitId,
      operationType: 'update',
      payloadJson: '{}',
    );
  }

  // ===========================================================================
  // 1. LEITURA (STREAMS LOCAIS)
  // ===========================================================================

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

  // ===========================================================================
  // 2. ESCRITA (OFFLINE-FIRST)
  // ===========================================================================

  Future<void> addHabit(String title) async {
    if (_db.isLocalOnly) {
      title = InputSanitizer.sanitize(title);
      if (title.isEmpty) throw ArgumentError('HABIT_TITLE_REQUIRED');
    }
    final ownerUid = _ownerUid;

    if (ownerUid == null) return;

    try {
      final id = _uuid.v4();
      final dates = <String>[];

      await _db.transactionWithSync(
        ownerUid: ownerUid,
        localOperation: () async {
          await _enforceLocalFreeQuota();
          await _db
              .into(_db.habits)
              .insert(
                HabitsCompanion.insert(
                  id: id,
                  title: title,
                  completedDates: jsonEncode(dates),
                ),
              );
        },
        collection: 'habits',
        docId: id,
        operationType: 'create',
        payloadJson: jsonEncode({'title': title, 'completedDates': dates}),
      );
    } catch (error, stackTrace) {
      AppLogger.e('Erro ao criar hábito localmente', error, stackTrace);
      rethrow;
    }
  }

  Future<void> toggleHabitToday(
    String habitId,
    List<String> currentDates,
  ) async {
    if (_db.isLocalOnly)
      return _toggleLocalDate(
        habitId,
        DateTime.now().toIso8601String().split('T').first,
      );
    final ownerUid = _ownerUid;

    if (ownerUid == null) return;

    try {
      final todayStr = DateTime.now().toIso8601String().split('T')[0];
      final wasCompletedToday = currentDates.contains(todayStr);
      List<String> updatedDates = List.from(currentDates);

      if (wasCompletedToday) {
        updatedDates.remove(todayStr);
      } else {
        updatedDates.add(todayStr);
      }

      final syncPayload = <String, dynamic>{
        'completedDates': updatedDates,
        if (!wasCompletedToday) 'competitiveCompletionId': _uuid.v4(),
      };

      await _db.transactionWithSync(
        ownerUid: ownerUid,
        localOperation: () async {
          await (_db.update(
            _db.habits,
          )..where((t) => t.id.equals(habitId))).write(
            HabitsCompanion(completedDates: Value(jsonEncode(updatedDates))),
          );
        },
        collection: 'habits',
        docId: habitId,
        operationType: 'update',
        payloadJson: jsonEncode(syncPayload),
      );
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
  Future<void> toggleHabitDate(
    String habitId,
    String date,
    List<String> currentDates,
  ) async {
    if (_db.isLocalOnly) {
      _validatedLocalDates([date]);
      return _toggleLocalDate(habitId, date);
    }
    final dates = List<String>.from(currentDates);
    if (!dates.remove(date)) dates.add(date);
    await updateHabitDates(habitId, dates);
  }

  Future<void> updateHabitDates(String habitId, List<String> newDates) async {
    if (_db.isLocalOnly) newDates = _validatedLocalDates(newDates);
    final ownerUid = _ownerUid;

    if (ownerUid == null) return;

    try {
      await _db.transactionWithSync(
        ownerUid: ownerUid,
        localOperation: () async {
          await (_db.update(
            _db.habits,
          )..where((t) => t.id.equals(habitId))).write(
            HabitsCompanion(completedDates: Value(jsonEncode(newDates))),
          );
        },
        collection: 'habits',
        docId: habitId,
        operationType: 'update',
        payloadJson: jsonEncode({'completedDates': newDates}),
      );
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
    final ownerUid = _ownerUid;

    if (ownerUid == null) return;

    try {
      await _db.transactionWithSync(
        ownerUid: ownerUid,
        localOperation: () async {
          // 1. Exclui o hábito localmente.
          await (_db.delete(
            _db.habits,
          )..where((t) => t.id.equals(habitId))).go();

          // 2. IDs exatos: formato atual e compatibilidade sem prefixo.
          await (_db.delete(_db.notificationsTable)..where(
                (t) => t.id.equals(habitId) | t.id.equals('habit_$habitId'),
              ))
              .go();
        },
        collection: 'batch',
        docId: habitId,
        operationType: 'batch_delete',
        payloadJson: jsonEncode({
          'deletes': [
            {'collection': 'habits', 'docId': habitId},
            {'collection': 'notifications', 'docId': habitId},
            {'collection': 'notifications', 'docId': 'habit_$habitId'},
          ],
        }),
      );
    } catch (error, stackTrace) {
      AppLogger.e('Erro ao deletar hábito localmente', error, stackTrace);
      rethrow;
    }
  }

  // ===========================================================================
  // 3. SINCRONIZAÇÃO FIREBASE <-> DRIFT
  // ===========================================================================

  Future<void> syncHabitsFromFirebaseToLocal() async {
    if (_db.isLocalOnly) return;
    final expectedUid = _auth.currentUser?.uid.trim();
    if (expectedUid == null || expectedUid.isEmpty) return;
    final ticket = _db.localMutations.capture(expectedUid: expectedUid);
    await _verifyRemoteRead(expectedUid);

    try {
      AppLogger.i('SYNC Hábitos: Iniciando...');
      final pullStartedAt = DateTime.now().millisecondsSinceEpoch;
      final pendingAtPullStart =
          await (_db.select(_db.syncQueueTable)..where(
                (item) =>
                    item.ownerUid.equals(expectedUid) &
                    (item.collection.equals('habits') |
                        (item.collection.equals('batch') &
                            item.operationType.equals('batch_delete'))) &
                    item.status.equals(SyncQueuePersistenceStatus.pending),
              ))
              .get();
      if (_auth.currentUser?.uid != expectedUid) return;
      final pendingOperationIds = pendingAtPullStart
          .map((item) => item.id)
          .toList();
      final snapshot = await _firestore
          .collection('users')
          .doc(expectedUid)
          .collection('habits')
          .get(const GetOptions(source: Source.server));
      if (_auth.currentUser?.uid != expectedUid) return;
      await _verifyRemoteRead(expectedUid);
      if (_db.identity?.generation != null &&
          !GenerationalReadPolicy.accepts(
            _db.identity,
            fromCache: snapshot.metadata.isFromCache,
            pendingWrites: snapshot.metadata.hasPendingWrites,
          ))
        throw StateError('GENERATIONAL_SNAPSHOT_UNCONFIRMED');
      final remoteDocIds = snapshot.docs.map((doc) => doc.id).toSet();

      await _db.transactionWithCommitGuard(
        admission: ticket,
        waitForReopen: false,
        validateBeforeCommit: () => _requireReadSession(expectedUid),
        () async {
          void requireCurrentUser() {
            if (_auth.currentUser?.uid != expectedUid) {
              throw const _HabitSessionChanged();
            }
          }

          requireCurrentUser();
          final authoritativeItems =
              await (_db.select(_db.syncQueueTable)..where(
                    (item) =>
                        item.ownerUid.equals(expectedUid) &
                        (item.collection.equals('habits') |
                            (item.collection.equals('batch') &
                                item.operationType.equals('batch_delete'))) &
                        (item.status.equals(
                              SyncQueuePersistenceStatus.pending,
                            ) |
                            (item.status.equals(
                                  SyncQueuePersistenceStatus.succeeded,
                                ) &
                                (item.createdAt.isBiggerOrEqualValue(
                                      pullStartedAt,
                                    ) |
                                    item.id.isIn(pendingOperationIds)))),
                  ))
                  .get();
          // deleteHabit stores the affected habit ID as the batch docId.
          final protectedDocIds = authoritativeItems
              .map((item) => item.docId)
              .toSet();
          requireCurrentUser();

          for (final doc in snapshot.docs) {
            requireCurrentUser();
            if (protectedDocIds.contains(doc.id)) continue;
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
            requireCurrentUser();
          }

          final localHabits = await _db.select(_db.habits).get();
          requireCurrentUser();
          for (final habit in localHabits) {
            requireCurrentUser();
            final id = habit.id.trim();
            if (id.isEmpty ||
                id == 'pending' ||
                id == 'synced' ||
                remoteDocIds.contains(habit.id) ||
                protectedDocIds.contains(habit.id)) {
              continue;
            }
            await (_db.delete(
              _db.habits,
            )..where((t) => t.id.equals(habit.id))).go();
            requireCurrentUser();
          }
        },
      );
      AppLogger.i('SYNC Hábitos: Concluído com sucesso.');
    } on _HabitSessionChanged {
      return;
    } catch (error, stackTrace) {
      AppLogger.e('SYNC Hábitos: ERRO CRÍTICO', error, stackTrace);
    }
  }

  // ===========================================================================
  // 4. FIREBASE - MÉTODOS PRIVADOS EM BACKGROUND
  // ===========================================================================
}
