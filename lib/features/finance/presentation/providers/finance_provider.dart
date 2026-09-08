import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:life_os/core/database/app_database.dart' as local_db;
import 'package:life_os/core/database/database_provider.dart';
import 'package:drift/drift.dart';
import 'package:life_os/core/services/sync_manager_provider.dart';
import 'package:life_os/features/finance/data/repositories/finance_repository.dart';

part 'finance_provider.g.dart';

const financeOfficialCategories = <String>[
  'Alimentação',
  'Moradia',
  'Transporte',
  'Saúde',
  'Educação',
  'Lazer',
  'Assinaturas',
  'Compras',
  'Contas',
  'Investimentos',
  'Trabalho',
  'Outros',
];

const _financeSpecificCategories = <String>{
  'Alimentação',
  'Moradia',
  'Transporte',
  'Saúde',
  'Educação',
  'Lazer',
  'Assinaturas',
  'Compras',
  'Contas',
  'Investimentos',
  'Trabalho',
};

enum FinanceTypeFilter { all, income, expense }

class FinanceFilters {
  final FinanceTypeFilter type;
  final String? category;

  const FinanceFilters({this.type = FinanceTypeFilter.all, this.category});

  @override
  bool operator ==(Object other) {
    return other is FinanceFilters &&
        other.type == type &&
        other.category == category;
  }

  @override
  int get hashCode => Object.hash(type, category);
}

class FinanceSummary {
  final double income;
  final double expense;

  const FinanceSummary({required this.income, required this.expense});

  double get balance => income - expense;
}

FinanceSummary calculateFinanceSummary(
  Iterable<local_db.Transaction> transactions,
) {
  var income = 0.0;
  var expense = 0.0;

  for (final transaction in transactions) {
    if (transaction.type == 'income') {
      income += transaction.amount;
    } else if (transaction.type == 'expense') {
      expense += transaction.amount;
    }
  }

  return FinanceSummary(income: income, expense: expense);
}

List<local_db.Transaction> filterFinanceTransactions(
  Iterable<local_db.Transaction> transactions,
  FinanceFilters filters,
) {
  return transactions.where((transaction) {
    if (transaction.type != 'income' && transaction.type != 'expense') {
      return false;
    }

    final matchesType = switch (filters.type) {
      FinanceTypeFilter.all => true,
      FinanceTypeFilter.income => transaction.type == 'income',
      FinanceTypeFilter.expense => transaction.type == 'expense',
    };

    if (!matchesType) return false;

    final category = filters.category;
    if (category == null) return true;

    if (category == 'Outros') {
      return transaction.category == 'Outros' ||
          !_financeSpecificCategories.contains(transaction.category);
    }

    return transaction.category == category;
  }).toList();
}

List<local_db.Transaction> visibleFinanceTransactions({
  required Iterable<local_db.Transaction> transactions,
  required FinanceFilters filters,
  required int limit,
}) {
  return filterFinanceTransactions(transactions, filters).take(limit).toList();
}

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

  void reset() {
    state = 15;
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

final financeVisibleTransactionsProvider = Provider.autoDispose
    .family<AsyncValue<List<local_db.Transaction>>, FinanceFilters>((
      ref,
      filters,
    ) {
      final transactionsAsync = ref.watch(financeStreamProvider);
      final limit = ref.watch(transactionLimitProvider);

      return transactionsAsync.when(
        data: (transactions) {
          final visibleTransactions = visibleFinanceTransactions(
            transactions: transactions,
            filters: filters,
            limit: limit,
          );

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
    ref.watch(syncManagerProvider),
  );
});
