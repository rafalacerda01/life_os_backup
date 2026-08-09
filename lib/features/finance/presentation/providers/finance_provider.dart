import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:life_os/core/database/app_database.dart' as local_db;
import 'package:life_os/core/database/database_provider.dart';
import 'package:drift/drift.dart';
import 'package:life_os/features/finance/data/repositories/finance_repository.dart';

part 'finance_provider.g.dart';

// ============================================================================
// CONTROLE DE PAGINAÇÃO
// ============================================================================

@riverpod
class TransactionLimit extends _$TransactionLimit {
  @override
  int build() => 15;

  void increment(int amount) {
    state += amount;
  }
}

// ============================================================================
// STREAM PRINCIPAL DE TRANSAÇÕES
// ============================================================================
//
// IMPORTANTE:
// Este provider NÃO depende do transactionLimitProvider.
//
// Isso mantém o stream do Drift estável durante a paginação.
// O banco continua observando as alterações normalmente,
// inclusive alterações offline e sincronização posterior.
//
// ============================================================================

final financeStreamProvider =
    StreamProvider.autoDispose<List<local_db.Transaction>>((ref) {
      final db = ref.watch(databaseProvider);

      return (db.select(db.transactions)
            ..where((transaction) => transaction.isDeleted.equals(false))
            ..orderBy([
              (transaction) => OrderingTerm(
                expression: transaction.date,
                mode: OrderingMode.desc,
              ),
            ]))
          .watch();
    });

// ============================================================================
// TRANSAÇÕES VISÍVEIS NA TELA
// ============================================================================
//
// Este provider controla apenas quantos registros serão exibidos.
//
// O stream do Drift continua intacto.
// Alterar 15 → 30 → 45 não recria a consulta do banco.
//
// ============================================================================

final financeVisibleTransactionsProvider =
    Provider.autoDispose<AsyncValue<List<local_db.Transaction>>>((ref) {
      final transactionsAsync = ref.watch(financeStreamProvider);
      final limit = ref.watch(transactionLimitProvider);

      return transactionsAsync.when(
        data: (transactions) {
          final visibleTransactions = transactions.take(limit).toList();

          return AsyncValue.data(visibleTransactions);
        },
        loading: () {
          return const AsyncValue.loading();
        },
        error: (error, stackTrace) {
          return AsyncValue.error(error, stackTrace);
        },
      );
    });

// ============================================================================
// REPOSITORY
// ============================================================================

final financeRepositoryProvider = Provider.autoDispose((ref) {
  return FinanceRepository(
    ref.watch(databaseProvider),
    FirebaseFirestore.instance,
    FirebaseAuth.instance,
  );
});
