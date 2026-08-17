import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:life_os/core/database/app_database.dart' as local_db;
import 'package:life_os/core/utils/app_logger.dart'; // 🚀 Nosso Logger injetado
import 'package:life_os/core/security/input_sanitizer.dart';
import 'package:life_os/features/finance/data/models/transaction_model.dart';
import 'package:uuid/uuid.dart';
import 'package:drift/drift.dart';
import 'dart:convert';

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

      await _db.transactionWithSync(
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
    } catch (error, stackTrace) {
      AppLogger.e('Erro ao inserir transação localmente', error, stackTrace);
      rethrow;
    }
  }

  Future<void> deleteTransaction(int localId) async {
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
        localOperation: () async {
          await _deleteLocalTransaction(localId);
        },
        collection: 'transactions',
        docId: firestoreId,
        operationType: 'delete',
        payloadJson: jsonEncode({'transactionId': firestoreId}),
      );
    } catch (error, stackTrace) {
      AppLogger.e('Erro ao excluir transação', error, stackTrace);
      rethrow;
    }
  }

  // 🚀 NOVO: Puxa os dados da nuvem (Firebase) e reconstrói o banco local (SQLite)
  Future<void> syncTransactionsFromFirestore() async {
    final userId = _auth.currentUser?.uid;

    if (userId == null) {
      AppLogger.i('Sincronização abortada: usuário não autenticado.');
      return;
    }

    try {
      AppLogger.i('Iniciando Sync-Down das transações do Firebase...');

      // 1. Busca todos os documentos do usuário na nuvem
      final snapshot = await _firestore
          .collection('users')
          .doc(userId)
          .collection('transactions')
          .get();

      // 2. Percorre cada transação da nuvem
      for (var doc in snapshot.docs) {
        final data = doc.data();
        final firestoreId = doc.id;

        // 3. Verifica se a transação já existe no SQLite local
        final existingTransaction =
            await (_db.select(_db.transactions)
                  ..where((table) => table.firestoreId.equals(firestoreId)))
                .getSingleOrNull();

        // 4. Se não existir localmente, nós a inserimos no Drift!
        if (existingTransaction == null) {
          await _db
              .into(_db.transactions)
              .insert(
                local_db.TransactionsCompanion.insert(
                  firestoreId: Value(firestoreId),
                  title: data['title'] as String? ?? 'Sem título',
                  amount: (data['amount'] as num?)?.toDouble() ?? 0.0,
                  type: data['type'] as String? ?? TransactionType.expense.name,
                  category: data['category'] as String? ?? 'Outros',
                  date:
                      (data['date'] as Timestamp?)?.toDate() ?? DateTime.now(),
                ),
              );
        }
      }

      AppLogger.i('Sync-Down concluído! SQLite reconstruído com sucesso.');
    } catch (error, stackTrace) {
      AppLogger.e(
        'Erro ao sincronizar transações do Firebase',
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
