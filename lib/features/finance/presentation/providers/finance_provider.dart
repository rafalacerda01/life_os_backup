import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:life_os/core/database/app_database.dart' as local_db;
import 'package:life_os/core/database/database_provider.dart';
import 'package:drift/drift.dart';
import 'package:life_os/features/finance/data/repositories/finance_repository.dart';

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
