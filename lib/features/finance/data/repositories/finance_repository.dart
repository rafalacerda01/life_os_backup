import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:life_os/core/database/app_database.dart' as local_db;
import 'package:life_os/core/utils/app_logger.dart'; // 🚀 Nosso Logger injetado
import 'package:life_os/core/security/input_sanitizer.dart';
import 'package:life_os/features/finance/data/models/transaction_model.dart';
import 'package:uuid/uuid.dart';
import 'package:drift/drift.dart';

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

      await _db
          .into(_db.transactions)
          .insert(
            local_db.TransactionsCompanion.insert(
              firestoreId: Value(firestoreId), // Ajustado para local_db.Value
              title: cleanTitle,
              amount: amount,
              type: transactionType.name,
              category: cleanCategory,
              date: createdAt,
            ),
          );

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
    } catch (error, stackTrace) {
      // 🚀 Substituído debugPrint por AppLogger
      AppLogger.e('Erro ao inserir transação localmente', error, stackTrace);
      rethrow;
    }
  }

  Future<void> deleteTransaction(int localId) async {
    try {
      final transaction = await (_db.select(
        _db.transactions,
      )..where((table) => table.id.equals(localId))).getSingleOrNull();

      if (transaction == null) return;

      await (_db.update(_db.transactions)
            ..where((table) => table.id.equals(localId)))
          .write(const local_db.TransactionsCompanion(isDeleted: Value(true)));

      final firestoreId = transaction.firestoreId;

      if (firestoreId == null ||
          firestoreId.isEmpty ||
          firestoreId == 'pending' ||
          firestoreId == 'synced') {
        await _deleteLocalTransaction(localId);
        return;
      }

      unawaited(
        _deleteTransactionFromFirestore(
          localId: localId,
          firestoreId: firestoreId,
        ),
      );
    } catch (error, stackTrace) {
      AppLogger.e('Erro ao excluir transação', error, stackTrace);
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
      AppLogger.i('Transação salva localmente: usuário não autenticado.');
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
      AppLogger.e('Envio da transação pendente (offline)', error, stackTrace);
    }
  }

  Future<void> _deleteTransactionFromFirestore({
    required int localId,
    required String firestoreId,
  }) async {
    final userId = _auth.currentUser?.uid;

    if (userId == null) {
      AppLogger.i('Exclusão local concluída; usuário não autenticado.');
      return;
    }

    try {
      await _firestore
          .collection('users')
          .doc(userId)
          .collection('transactions')
          .doc(firestoreId)
          .delete();

      await _deleteLocalTransaction(localId);
    } catch (error, stackTrace) {
      AppLogger.e(
        'Exclusão da transação pendente (offline)',
        error,
        stackTrace,
      );
    }
  }

  Future<void> _deleteLocalTransaction(int localId) async {
    await (_db.delete(
      _db.transactions,
    )..where((table) => table.id.equals(localId))).go();
  }
}
