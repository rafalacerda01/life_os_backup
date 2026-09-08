import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:drift/drift.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:life_os/core/database/app_database.dart' as local_db;
import 'package:life_os/core/security/input_sanitizer.dart';
import 'package:life_os/core/services/sync_manager.dart';
import 'package:life_os/core/utils/app_logger.dart'; // 🚀 Nosso Logger injetado
import 'package:life_os/features/finance/data/models/transaction_model.dart';
import 'package:uuid/uuid.dart';

class _FinanceSessionChanged implements Exception {
  const _FinanceSessionChanged();
}

class _RemoteFinanceTransaction {
  final String title;
  final double amount;
  final String type;
  final String category;
  final DateTime date;

  const _RemoteFinanceTransaction({
    required this.title,
    required this.amount,
    required this.type,
    required this.category,
    required this.date,
  });
}

class FinanceRepository {
  static const double _maximumAmount = 1000000000;

  final local_db.AppDatabase _db;
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;
  final SyncManager _syncManager;

  FinanceRepository(this._db, this._firestore, this._auth, this._syncManager);

  Future<void> addTransaction({
    required String title,
    required double amount,
    required String type,
    required String category,
  }) async {
    final cleanTitle = InputSanitizer.sanitize(title);
    final cleanCategory = InputSanitizer.sanitize(category);
    final cleanType = InputSanitizer.sanitize(type);

    _validateTransaction(
      title: cleanTitle,
      amount: amount,
      type: cleanType,
      category: cleanCategory,
    );

    final user = _auth.currentUser;

    if (user == null) {
      return;
    }

    try {
      final transactionType = TransactionType.values.byName(cleanType);

      final firestoreId = const Uuid().v4();

      final createdAt = DateTime.now();

      await _db.transactionWithSync(
        ownerUid: user.uid,
        localOperation: () async {
          await _db
              .into(_db.transactions)
              .insert(
                local_db.TransactionsCompanion.insert(
                  firestoreId: Value(firestoreId),
                  title: cleanTitle,
                  amount: amount,
                  type: transactionType.name,
                  category: cleanCategory,
                  date: createdAt,
                ),
              );
        },
        collection: 'transactions',
        docId: firestoreId,
        operationType: 'create',
        payloadJson: jsonEncode({
          'title': cleanTitle,
          'amount': amount,
          'type': transactionType.name,
          'category': cleanCategory,
          'date': createdAt.toIso8601String(),
        }),
      );

      _schedulePendingFinanceSync();
    } catch (error, stackTrace) {
      AppLogger.e('Erro ao inserir transação localmente', error, stackTrace);
      rethrow;
    }
  }

  Future<void> deleteTransaction(int localId) async {
    final user = _auth.currentUser;

    if (user == null) {
      return;
    }

    try {
      final transaction = await (_db.select(
        _db.transactions,
      )..where((table) => table.id.equals(localId))).getSingleOrNull();

      if (transaction == null) {
        return;
      }

      final firestoreId = transaction.firestoreId;

      if (firestoreId == null ||
          firestoreId.isEmpty ||
          firestoreId == 'pending' ||
          firestoreId == 'synced') {
        await _db.transaction(() async {
          await _deleteLocalTransaction(localId);
        });

        return;
      }

      await _db.transactionWithSync(
        ownerUid: user.uid,
        localOperation: () async {
          await _deleteLocalTransaction(localId);
        },
        collection: 'transactions',
        docId: firestoreId,
        operationType: 'delete',
        payloadJson: jsonEncode({'transactionId': firestoreId}),
      );

      _schedulePendingFinanceSync();
    } catch (error, stackTrace) {
      AppLogger.e('Erro ao excluir transação', error, stackTrace);
      rethrow;
    }
  }

  Future<void> syncTransactionsFromFirestore() async {
    final expectedUid = _auth.currentUser?.uid.trim();

    if (expectedUid == null || expectedUid.isEmpty) return;

    try {
      final pullStartedAt = DateTime.now().millisecondsSinceEpoch;
      final queueDrained = await _syncManager.processPendingItems();
      if (!queueDrained || !_isCurrentUser(expectedUid)) return;

      final snapshot = await _firestore
          .collection('users')
          .doc(expectedUid)
          .collection('transactions')
          .get(const GetOptions(source: Source.server));
      _requireCurrentUser(expectedUid);

      final remoteDocIds = snapshot.docs.map((doc) => doc.id).toSet();

      await _db.transaction(() async {
        _requireCurrentUser(expectedUid);

        final authoritativeItems =
            await (_db.select(_db.syncQueueTable)..where(
                  (item) =>
                      item.ownerUid.equals(expectedUid) &
                      item.collection.equals('transactions') &
                      (item.status.equals(
                            local_db.SyncQueuePersistenceStatus.pending,
                          ) |
                          (item.status.equals(
                                local_db.SyncQueuePersistenceStatus.succeeded,
                              ) &
                              item.createdAt.isBiggerOrEqualValue(
                                pullStartedAt,
                              ))),
                ))
                .get();
        final protectedDocIds = authoritativeItems
            .map((item) => item.docId)
            .toSet();

        _requireCurrentUser(expectedUid);

        for (final doc in snapshot.docs) {
          _requireCurrentUser(expectedUid);
          if (protectedDocIds.contains(doc.id)) continue;

          final remote = _parseRemoteTransaction(doc.data());
          if (remote == null) {
            AppLogger.w('SYNC Finanças: documento remoto inválido ignorado.');
            continue;
          }

          final existing =
              await (_db.select(_db.transactions)
                    ..where((table) => table.firestoreId.equals(doc.id)))
                  .getSingleOrNull();

          _requireCurrentUser(expectedUid);

          if (existing == null) {
            await _db
                .into(_db.transactions)
                .insert(
                  local_db.TransactionsCompanion.insert(
                    firestoreId: Value(doc.id),
                    title: remote.title,
                    amount: remote.amount,
                    type: remote.type,
                    category: remote.category,
                    date: remote.date,
                  ),
                );
          } else {
            await (_db.update(
              _db.transactions,
            )..where((table) => table.id.equals(existing.id))).write(
              local_db.TransactionsCompanion(
                firestoreId: Value(doc.id),
                title: Value(remote.title),
                amount: Value(remote.amount),
                type: Value(remote.type),
                category: Value(remote.category),
                date: Value(remote.date),
                isDeleted: const Value(false),
              ),
            );
          }
        }

        _requireCurrentUser(expectedUid);
        final localTransactions = await _db.select(_db.transactions).get();

        for (final transaction in localTransactions) {
          _requireCurrentUser(expectedUid);
          final firestoreId = transaction.firestoreId;
          if (!_isRemoteFirestoreId(firestoreId) ||
              remoteDocIds.contains(firestoreId) ||
              protectedDocIds.contains(firestoreId)) {
            continue;
          }

          await (_db.delete(
            _db.transactions,
          )..where((table) => table.id.equals(transaction.id))).go();
        }

        _requireCurrentUser(expectedUid);
      });
    } on _FinanceSessionChanged {
      return;
    } catch (_) {
      AppLogger.w('Não foi possível sincronizar as transações neste momento.');
    }
  }

  bool _isCurrentUser(String expectedUid) =>
      _auth.currentUser?.uid == expectedUid;

  void _requireCurrentUser(String expectedUid) {
    if (!_isCurrentUser(expectedUid)) {
      throw const _FinanceSessionChanged();
    }
  }

  bool _isRemoteFirestoreId(String? firestoreId) {
    final value = firestoreId?.trim();
    return value != null &&
        value.isNotEmpty &&
        value != 'pending' &&
        value != 'synced';
  }

  _RemoteFinanceTransaction? _parseRemoteTransaction(
    Map<String, dynamic> data,
  ) {
    final rawTitle = data['title'];
    final rawAmount = data['amount'];
    final rawType = data['type'];
    final rawCategory = data['category'];
    final rawDate = data['date'];

    if (rawTitle is! String ||
        rawAmount is! num ||
        rawType is! String ||
        rawCategory is! String) {
      return null;
    }

    final title = InputSanitizer.sanitize(rawTitle);
    final category = InputSanitizer.sanitize(rawCategory);
    final amount = rawAmount.toDouble();
    final date = switch (rawDate) {
      Timestamp value => value.toDate(),
      DateTime value => value,
      String value => DateTime.tryParse(value),
      _ => null,
    };

    if (date == null ||
        rawType != TransactionType.income.name &&
            rawType != TransactionType.expense.name) {
      return null;
    }

    try {
      _validateTransaction(
        title: title,
        amount: amount,
        type: rawType,
        category: category,
      );
    } on ArgumentError {
      return null;
    }

    return _RemoteFinanceTransaction(
      title: title,
      amount: amount,
      type: rawType,
      category: category,
      date: date,
    );
  }

  Future<void> _deleteLocalTransaction(int localId) async {
    await (_db.delete(
      _db.transactions,
    )..where((table) => table.id.equals(localId))).go();
  }

  void _validateTransaction({
    required String title,
    required double amount,
    required String type,
    required String category,
  }) {
    if (title.isEmpty || title.length > 200) {
      throw ArgumentError.value(title, 'title', 'Título inválido.');
    }

    if (category.isEmpty || category.length > 100) {
      throw ArgumentError.value(category, 'category', 'Categoria inválida.');
    }

    if (!amount.isFinite || amount <= 0 || amount > _maximumAmount) {
      throw ArgumentError.value(amount, 'amount', 'Valor inválido.');
    }

    if (type != TransactionType.income.name &&
        type != TransactionType.expense.name) {
      throw ArgumentError.value(type, 'type', 'Tipo inválido.');
    }
  }

  void _schedulePendingFinanceSync() {
    unawaited(
      _syncManager.processPendingItems().catchError((error, stackTrace) {
        AppLogger.e(
          'Erro ao processar fila de sincronização financeira.',
          error,
          stackTrace,
        );
        return false;
      }),
    );
  }
}
