import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:drift/drift.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/local_mutation_gate.dart';
import 'package:life_os/core/utils/app_logger.dart';

class CheckInRepository {
  static const _defaultRemoteWriteTimeout = Duration(seconds: 10);
  static final _dailyIdPattern = RegExp(r'^[0-9]{4}-[0-9]{2}-[0-9]{2}$');

  // The ID is a local civil day; remote upload timestamps are only metadata.
  static DateTime? _checkInDateFromId(String id) {
    if (id.length != 10 || !_dailyIdPattern.hasMatch(id)) return null;
    final year = int.parse(id.substring(0, 4));
    final month = int.parse(id.substring(5, 7));
    final day = int.parse(id.substring(8, 10));
    if (year < 1) return null;

    final date = DateTime(year, month, day);
    // DateTime normalizes invalid dates, so reject any calendar rollover.
    if (date.year != year || date.month != month || date.day != day)
      return null;
    return date;
  }

  final AppDatabase _db;
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;
  final Duration _remoteWriteTimeout;
  Future<void> _uploadTail = Future<void>.value();

  bool _isCurrentUser(String uid) =>
      uid.trim().isNotEmpty && _auth.currentUser?.uid == uid;

  // ===========================================================================
  // INJEÇÃO DE DEPENDÊNCIA
  // ===========================================================================

  CheckInRepository(
    this._db,
    this._firestore,
    this._auth, {
    Duration? remoteWriteTimeout,
  }) : _remoteWriteTimeout = remoteWriteTimeout ?? _defaultRemoteWriteTimeout;

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

    if (user == null || user.uid.trim().isEmpty) {
      AppLogger.w('Tentativa de salvar check-in sem usuário autenticado.');
      return;
    }

    final admission = _db.localMutations.capture(expectedUid: user.uid);
    await _db.localMutations.run(
      () => _saveDailyMetrics(
        user.uid,
        energy: energy,
        focus: focus,
        motivation: motivation,
      ),
      ticket: admission,
    );
  }

  Future<void> _saveDailyMetrics(
    String userId, {
    required double energy,
    required double focus,
    required double motivation,
  }) async {
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

      if (_isCurrentUser(userId)) {
        unawaited(_syncWithFirebase(userId: userId, checkInId: todayId));
      }
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

  Future<Map<String, ({int rowId, CheckInEntry entry})>>
  _readLocalCheckInRevisions() async {
    final table = _db.checkInTable;
    final rows = await _db.select(table).addColumns([table.rowId]).get();
    return {
      for (final row in rows)
        row.readTable(table).id: (
          rowId: row.read(table.rowId)!,
          entry: row.readTable(table),
        ),
    };
  }

  Future<void> syncCheckinsFromFirebaseToLocal() async {
    final user = _auth.currentUser;

    if (user == null || user.uid.trim().isEmpty) {
      AppLogger.w('SYNC Check-ins ignorado: usuário não autenticado.');
      return;
    }
    final expectedUid = user.uid;
    final ticket = _db.localMutations.capture(expectedUid: expectedUid);

    try {
      AppLogger.i('SYNC Check-ins: iniciando download do Firebase...');

      // Domain saves use INSERT OR REPLACE, so rowid changes even for an
      // identical edit or an ABA edit within the same stored timestamp.
      // The full row also detects in-place changes (including upload ACKs).
      final baseline = await _db.transaction(
        _readLocalCheckInRevisions,
        admission: ticket,
        waitForReopen: false,
      );
      if (!_isCurrentUser(expectedUid)) return;
      final snapshot = await _firestore
          .collection('users')
          .doc(expectedUid)
          .collection('checkins')
          .get();

      if (!_isCurrentUser(expectedUid)) return;
      await _db.transaction(admission: ticket, waitForReopen: false, () async {
        final current = await _readLocalCheckInRevisions();
        for (final doc in snapshot.docs) {
          if (!_isCurrentUser(expectedUid)) {
            throw StateError('CHECKIN_SESSION_CHANGED');
          }
          final local = current[doc.id];
          if (local?.entry.isSynced == false || local != baseline[doc.id]) {
            continue;
          }

          final createdAt = _checkInDateFromId(doc.id);
          if (createdAt == null) {
            AppLogger.w(
              'SYNC Check-ins: documento com ID diário inválido ignorado.',
            );
            continue;
          }

          final data = doc.data();

          final energy = (data['energy'] as num?)?.toDouble() ?? 0.0;

          final focus = (data['focus'] as num?)?.toDouble() ?? 0.0;

          final motivation = (data['motivation'] as num?)?.toDouble() ?? 0.0;

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
          if (!_isCurrentUser(expectedUid)) {
            throw StateError('CHECKIN_SESSION_CHANGED');
          }
        }
      });

      AppLogger.i(
        'SYNC Check-ins: download concluído. '
        '${snapshot.docs.length} registros processados.',
      );
    } catch (_) {
      AppLogger.w('SYNC Check-ins: download não concluído.');
    }
  }

  // ===========================================================================
  // 4. UPLOAD DE UM CHECK-IN
  //
  // Drift -> Firebase
  // ===========================================================================

  Future<bool> _syncWithFirebase({
    required String userId,
    required String checkInId,
  }) {
    final admission = _db.localMutations.capture(expectedUid: userId);
    final result = _uploadTail.then(
      (_) => _uploadCurrentCheckIn(
        userId: userId,
        checkInId: checkInId,
        admission: admission,
      ),
    );
    _uploadTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<bool> _uploadCurrentCheckIn({
    required LocalMutationTicket admission,
    required String userId,
    required String checkInId,
  }) async {
    try {
      if (!_isCurrentUser(userId)) return false;
      final checkIn = await (_db.select(
        _db.checkInTable,
      )..where((table) => table.id.equals(checkInId))).getSingleOrNull();
      if (!_isCurrentUser(userId) || checkIn == null) return false;
      if (checkIn.isSynced) return true;

      await _firestore
          .collection('users')
          .doc(userId)
          .collection('checkins')
          .doc(checkInId)
          .set({
            'energy': checkIn.energy,
            'focus': checkIn.focus,
            'motivation': checkIn.motivation,
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true))
          .timeout(_remoteWriteTimeout);

      if (!_isCurrentUser(userId)) return false;
      final marked = await _db.localMutations.systemWrite(
        userId,
        () => _db.transaction(() async {
          if (!_isCurrentUser(userId)) return 0;
          final count =
              await (_db.update(_db.checkInTable)..where(
                    (table) =>
                        table.id.equals(checkInId) &
                        table.createdAt.equals(checkIn.createdAt) &
                        table.energy.equals(checkIn.energy) &
                        table.focus.equals(checkIn.focus) &
                        table.motivation.equals(checkIn.motivation) &
                        table.isSynced.equals(false),
                  ))
                  .write(const CheckInTableCompanion(isSynced: Value(true)));
          if (!_isCurrentUser(userId)) {
            throw StateError('CHECKIN_SESSION_CHANGED');
          }
          return count;
        }),
        admission: admission,
      );

      if (marked != 1 || !_isCurrentUser(userId)) return false;
      AppLogger.i('Check-in sincronizado com sucesso.');
      return true;
    } catch (_) {
      AppLogger.w('Check-in permanece pendente de sincronização.');
      return false;
    }
  }

  // ===========================================================================
  // 5. SINCRONIZAÇÃO DOS PENDENTES
  //
  // Envia registros que ficaram offline.
  // ===========================================================================

  Future<bool> syncPendingCheckIns() async {
    final user = _auth.currentUser;

    if (user == null || user.uid.trim().isEmpty) {
      AppLogger.w('SYNC pendentes ignorado: usuário não autenticado.');
      return false;
    }
    final expectedUid = user.uid;

    try {
      final pendingList = (await _db.getPendingCheckIns()).cast<CheckInEntry>();
      if (!_isCurrentUser(expectedUid)) return false;

      if (pendingList.isEmpty) {
        AppLogger.i('SYNC Check-ins: nenhum registro pendente.');
        return true;
      }

      AppLogger.i(
        'SYNC Check-ins: ${pendingList.length} registro(s) pendente(s).',
      );

      var allDelivered = true;
      for (final checkIn in pendingList) {
        if (!_isCurrentUser(expectedUid)) return false;
        if (!await _syncWithFirebase(
          userId: expectedUid,
          checkInId: checkIn.id,
        )) {
          allDelivered = false;
        }
      }

      if (!_isCurrentUser(expectedUid)) return false;
      final stillPending = await _db.getPendingCheckIns();
      return allDelivered &&
          stillPending.isEmpty &&
          _isCurrentUser(expectedUid);
    } catch (_) {
      AppLogger.w('SYNC Check-ins: pendências não concluídas.');
      return false;
    }
  }
}
