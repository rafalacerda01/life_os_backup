import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:drift/drift.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/core/database/app_database.dart' as local_db;
import 'package:life_os/core/database/database_provider.dart';
import 'package:life_os/core/security/input_sanitizer.dart';
import 'package:life_os/features/finance/data/models/transaction_model.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:uuid/uuid.dart';

part 'finance_provider.g.dart';

@riverpod
class TransactionLimit extends _$TransactionLimit {
  @override
  int build() => 15;

  void increment(int amount) {
    state += amount;
  }
}

final financeStreamProvider =
    StreamProvider.autoDispose<List<local_db.Transaction>>((ref) {
      final db = ref.watch(databaseProvider);
      final limit = ref.watch(transactionLimitProvider);

      return (db.select(db.transactions)
            ..where((transaction) => transaction.isDeleted.equals(false))
            ..orderBy([
              (transaction) => OrderingTerm(
                expression: transaction.date,
                mode: OrderingMode.desc,
              ),
            ])
            ..limit(limit))
          .watch();
    });

final financeRepositoryProvider = Provider.autoDispose<FinanceRepository>((
  ref,
) {
  return FinanceRepository(
    ref.watch(databaseProvider),
    FirebaseFirestore.instance,
    FirebaseAuth.instance,
  );
});

class FinanceRepository {
  final local_db.AppDatabase _db;
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  FinanceRepository(this._db, this._firestore, this._auth);

  Future<void> addTransaction({
    required String title,
    required double amount,
    required String type,
    required String category,
  }) async {
    try {
      final cleanTitle = InputSanitizer.sanitize(title);
      final cleanCategory = InputSanitizer.sanitize(category);
      final cleanType = InputSanitizer.sanitize(type);

      final transactionType = TransactionType.values.firstWhere(
        (item) => item.name.toLowerCase() == cleanType.toLowerCase().trim(),
        orElse: () => TransactionType.expense,
      );

      final firestoreId = const Uuid().v4();
      final createdAt = DateTime.now();

      // 1. Salva imediatamente no Drift.
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

      // 2. O Firestore mantém a escrita na fila se estiver offline.
      unawaited(
        _saveTransactionToFirestore(
          firestoreId: firestoreId,
          title: cleanTitle,
          amount: amount,
          type: transactionType.name,
          category: cleanCategory,
          createdAt: createdAt,
        ),
      );
    } catch (error) {
      debugPrint('Erro ao inserir transação localmente: $error');
      rethrow;
    }
  }

  Future<void> deleteTransaction(int localId) async {
    try {
      final transaction = await (_db.select(
        _db.transactions,
      )..where((table) => table.id.equals(localId))).getSingleOrNull();

      if (transaction == null) return;

      // Oculta a transação localmente imediatamente.
      await (_db.update(_db.transactions)
            ..where((table) => table.id.equals(localId)))
          .write(const local_db.TransactionsCompanion(isDeleted: Value(true)));

      final firestoreId = transaction.firestoreId;

      // Registros antigos que ainda não possuem documento próprio no Firestore.
      if (firestoreId == null ||
          firestoreId.isEmpty ||
          firestoreId == 'pending' ||
          firestoreId == 'synced') {
        await _deleteLocalTransaction(localId);
        return;
      }

      // O delete também é colocado na fila offline pelo Firestore.
      unawaited(
        _deleteTransactionFromFirestore(
          localId: localId,
          firestoreId: firestoreId,
        ),
      );
    } catch (error) {
      debugPrint('Erro ao excluir transação: $error');
      rethrow;
    }
  }

  Future<void> _saveTransactionToFirestore({
    required String firestoreId,
    required String title,
    required double amount,
    required String type,
    required String category,
    required DateTime createdAt,
  }) async {
    final userId = _auth.currentUser?.uid;

    if (userId == null) {
      debugPrint('Transação salva localmente: usuário não autenticado.');
      return;
    }

    try {
      await _firestore
          .collection('users')
          .doc(userId)
          .collection('transactions')
          .doc(firestoreId)
          .set({
            'id': firestoreId,
            'title': title,
            'amount': amount,
            'type': type,
            'category': category,
            'date': Timestamp.fromDate(createdAt),
            'createdAt': Timestamp.fromDate(createdAt),
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
    } catch (error, stackTrace) {
      // Em falta de internet, o SDK mantém a operação pendente e a reenvia.
      debugPrint('Envio da transação pendente: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<void> _deleteTransactionFromFirestore({
    required int localId,
    required String firestoreId,
  }) async {
    final userId = _auth.currentUser?.uid;

    if (userId == null) {
      debugPrint('Exclusão local concluída; usuário não autenticado.');
      return;
    }

    try {
      await _firestore
          .collection('users')
          .doc(userId)
          .collection('transactions')
          .doc(firestoreId)
          .delete();

      // Só remove definitivamente do Drift quando o Firestore confirmar.
      await _deleteLocalTransaction(localId);
    } catch (error, stackTrace) {
      // O soft delete continua no Drift e o Firestore tenta novamente ao reconectar.
      debugPrint('Exclusão da transação pendente: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<void> _deleteLocalTransaction(int localId) async {
    await (_db.delete(
      _db.transactions,
    )..where((table) => table.id.equals(localId))).go();
  }
}
