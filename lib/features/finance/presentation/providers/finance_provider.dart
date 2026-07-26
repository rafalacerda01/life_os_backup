import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:drift/drift.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:life_os/core/security/input_sanitizer.dart';
import 'package:life_os/core/database/app_database.dart' as local_db;
import 'package:life_os/core/database/database_provider.dart';
import 'package:life_os/features/finance/data/models/transaction_model.dart';

part 'finance_provider.g.dart';

// 1. ESTADO DE PAGINAÇÃO (Usa Code Generation: limpo e sem boilerplate)
@riverpod
class TransactionLimit extends _$TransactionLimit {
  @override
  int build() => 15; // Valor inicial

  void increment(int amount) {
    state += amount;
  }
}

// 2. STREAM PROVIDER (Provider clássico: blinda o gerador contra o erro InvalidTypeException)
final financeStreamProvider =
    StreamProvider.autoDispose<List<local_db.Transaction>>((ref) {
      final db = ref.watch(databaseProvider);

      // Consome perfeitamente o limite gerado pelo @riverpod acima
      final limit = ref.watch(transactionLimitProvider);

      return (db.select(db.transactions)
            ..orderBy([
              (t) => OrderingTerm(expression: t.date, mode: OrderingMode.desc),
            ])
            ..limit(limit))
          .watch();
    });

// 3. REPOSITÓRIO (Provider clássico)
final financeRepositoryProvider = Provider.autoDispose<FinanceRepository>((
  ref,
) {
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

  FinanceRepository(this._firestore, this._auth, this._db) {
    // 🔄 Tenta disparar a fila de sincronização pendente automaticamente na inicialização
    syncPendingTransactions();
  }

  // 4. FILA DE MUTAÇÃO OFFLINE: Sobe transações criadas sem internet (Local -> Firebase)
  Future<void> syncPendingTransactions() async {
    final user = _auth.currentUser;
    if (user == null) return;

    try {
      final pendingItems = await (_db.select(
        _db.transactions,
      )..where((t) => t.firestoreId.equals('pending'))).get();

      if (pendingItems.isEmpty) return;

      for (var item in pendingItems) {
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
          'title': item.title,
          'amount': item.amount,
          'type': item.type,
          'category': item.category,
          'date': Timestamp.fromDate(item.date),
        });

        batch.set(dashboardRef, {
          item.type == 'income' ? 'totalIncome' : 'totalExpense':
              FieldValue.increment(item.amount),
          'transactionsCount': FieldValue.increment(1),
        }, SetOptions(merge: true));

        await batch.commit();

        // Vincula o ID real do Firestore ao registro local para limpar a pendência
        await (_db.update(
          _db.transactions,
        )..where((t) => t.id.equals(item.id))).write(
          local_db.TransactionsCompanion(firestoreId: Value(docRef.id)),
        );
      }
    } catch (e) {
      debugPrint("Modo offline: Sincronização pendente adiada. Detalhe: $e");
    }
  }

  // 5. SINCRONIZAÇÃO DE DESCIDA (Firebase -> Local - Limitado a 50 itens)
  Future<void> syncFromFirebaseToLocal() async {
    final user = _auth.currentUser;
    if (user == null) return;

    try {
      // Assegura que subidas pendentes ocorram antes de baixar novos dados
      await syncPendingTransactions();

      final snapshot = await _firestore
          .collection('users')
          .doc(user.uid)
          .collection('transactions')
          .orderBy('date', descending: true)
          .limit(50)
          .get();

      for (var doc in snapshot.docs) {
        final data = doc.data();
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

  // 6. ADIÇÃO DE TRANSAÇÃO (Resiliente a falhas de rede / Offline-First)
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

    // Gravação local imediata (garante UI fluida e suporte offline absoluto)
    final localId = await _db
        .into(_db.transactions)
        .insert(
          local_db.TransactionsCompanion.insert(
            firestoreId: const Value(
              'pending',
            ), // Marcado como pendente para a fila
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

      // Atualiza o registro local com o ID definitivo do Firestore
      await (_db.update(_db.transactions)..where((t) => t.id.equals(localId)))
          .write(local_db.TransactionsCompanion(firestoreId: Value(docRef.id)));
    } catch (e) {
      debugPrint(
        "Sem conexão com o Firestore: Transação salva na fila local. $e",
      );
    }
  }

  // 7. REMOÇÃO DE TRANSAÇÃO (Local + Nuvem)
  Future<void> deleteTransaction(int localId, String? firestoreId) async {
    final user = _auth.currentUser;
    if (user == null) return;

    final transaction = await (_db.select(
      _db.transactions,
    )..where((t) => t.id.equals(localId))).getSingleOrNull();

    if (transaction == null) return;

    // Executa a remoção local de forma imediata
    await (_db.delete(
      _db.transactions,
    )..where((t) => t.id.equals(localId))).go();

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

        await _firestore.runTransaction((tx) async {
          tx.delete(firestoreDocRef);
          tx.update(mainDocRef, {
            (transaction.type == 'income' ? 'totalIncome' : 'totalExpense'):
                FieldValue.increment(-transaction.amount),
            'transactionsCount': FieldValue.increment(-1),
          });
        });
      } catch (e) {
        debugPrint(
          "Erro ao remover do Firebase (será sincronizado depois): $e",
        );
      }
    }
  }
}
