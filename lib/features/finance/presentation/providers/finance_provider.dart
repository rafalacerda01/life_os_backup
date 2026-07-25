import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:drift/drift.dart';
import 'package:life_os/core/security/input_sanitizer.dart';
import 'package:life_os/core/database/app_database.dart' as local_db;
import 'package:life_os/core/database/database_provider.dart';
import 'package:life_os/features/finance/data/models/transaction_model.dart';

// 1. STREAM PROVIDER
final financeStreamProvider =
    StreamProvider.autoDispose<List<local_db.Transaction>>((ref) {
      final db = ref.watch(databaseProvider);
      return (db.select(db.transactions)..orderBy([
            (t) => OrderingTerm(expression: t.date, mode: OrderingMode.desc),
          ]))
          .watch();
    });

// 2. REPOSITÓRIO
final financeRepositoryProvider = Provider((ref) {
  return FinanceRepository(
    FirebaseFirestore.instance,
    FirebaseAuth.instance,
    ref.watch(databaseProvider),
  );
});

class FinanceRepository {
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;
  final local_db.AppDatabase _db;

  FinanceRepository(this._firestore, this._auth, this._db);

  // NOVO MÉTODO DE SINCRONIZAÇÃO (ADICIONADO)
  Future<void> syncFromFirebaseToLocal() async {
    final user = _auth.currentUser;
    if (user == null) return;

    try {
      final snapshot = await _firestore
          .collection('users')
          .doc(user.uid)
          .collection('transactions')
          .get();

      for (var doc in snapshot.docs) {
        final data = doc.data();

        // Verifica se essa transação já existe no Drift para não duplicar
        final existing = await (_db.select(
          _db.transactions,
        )..where((t) => t.firestoreId.equals(doc.id))).get();

        if (existing.isEmpty) {
          await _db
              .into(_db.transactions)
              .insert(
                local_db.TransactionsCompanion.insert(
                  firestoreId: Value(doc.id),
                  title: data['title'] as String? ?? 'Sem título',
                  amount: (data['amount'] as num).toDouble(),
                  type: data['type'] as String? ?? 'expense',
                  category: data['category'] as String? ?? 'Geral',
                  date: (data['date'] as Timestamp).toDate(),
                ),
              );
        }
      }
    } catch (e) {
      debugPrint("Erro ao sincronizar do Firebase para o Drift: $e");
    }
  }

  Future<void> addTransaction({
    required String title,
    required double amount,
    required String type,
    required String category,
  }) async {
    final user = _auth.currentUser;
    if (user == null) return;

    final cleanTitle = InputSanitizer.sanitize(title);
    final cleanCategory = InputSanitizer.sanitize(category);
    final cleanType = InputSanitizer.sanitize(type);

    final transactionType = TransactionType.values.firstWhere(
      (e) => e.name.toLowerCase() == cleanType.toLowerCase().trim(),
      orElse: () => TransactionType.expense,
    );

    final localId = await _db
        .into(_db.transactions)
        .insert(
          local_db.TransactionsCompanion.insert(
            firestoreId: const Value('pending'),
            title: cleanTitle,
            amount: amount,
            type: transactionType.name,
            category: cleanCategory,
            date: DateTime.now(),
          ),
        );

    try {
      final docRef = _firestore
          .collection('users')
          .doc(user.uid)
          .collection('transactions')
          .doc();
      final dashboardRef = _firestore
          .collection('users')
          .doc(user.uid)
          .collection('finance')
          .doc('main');

      final batch = _firestore.batch();

      batch.set(docRef, {
        'title': cleanTitle,
        'amount': amount,
        'type': transactionType.name,
        'category': cleanCategory,
        'date': Timestamp.now(),
      });

      batch.set(dashboardRef, {
        transactionType == TransactionType.income
            ? 'totalIncome'
            : 'totalExpense': FieldValue.increment(
          amount,
        ),
        'transactionsCount': FieldValue.increment(1),
      }, SetOptions(merge: true));

      await batch.commit().timeout(const Duration(seconds: 3));

      await (_db.update(_db.transactions)..where((t) => t.id.equals(localId)))
          .write(local_db.TransactionsCompanion(firestoreId: Value(docRef.id)));
    } catch (e) {
      debugPrint("Erro ao sincronizar com Firebase: $e");
    }
  }

  Future<void> deleteTransaction(int localId, String? firestoreId) async {
    final user = _auth.currentUser;
    if (user == null) return;

    // 1. Buscamos a transação no Drift ANTES de deletar para saber o valor e o tipo
    final transaction = await (_db.select(
      _db.transactions,
    )..where((t) => t.id.equals(localId))).getSingleOrNull();

    if (transaction == null) return;

    // 2. Apagamos do banco local (Drift)
    await (_db.delete(
      _db.transactions,
    )..where((t) => t.id.equals(localId))).go();

    // 3. Se estiver no Firebase, removemos a transação E atualizamos o resumo (Main)
    if (firestoreId != null && firestoreId != 'pending') {
      try {
        final mainDocRef = _firestore
            .collection('users')
            .doc(user.uid)
            .collection('finance')
            .doc('main');
        final firestoreDocRef = _firestore
            .collection('users')
            .doc(user.uid)
            .collection('transactions')
            .doc(firestoreId);

        // Usamos uma Transação para garantir que as duas operações ocorram juntas
        await _firestore.runTransaction((tx) async {
          // Apaga o documento da transação
          tx.delete(firestoreDocRef);

          // Subtrai do total (usamos o negativo do amount para decrementar)
          tx.update(mainDocRef, {
            (transaction.type == 'income' ? 'totalIncome' : 'totalExpense'):
                FieldValue.increment(-transaction.amount),
            'transactionsCount': FieldValue.increment(-1),
          });
        });
      } catch (e) {
        debugPrint("Erro ao remover do Firebase: $e");
      }
    }
  }
}
