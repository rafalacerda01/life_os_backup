import 'package:drift/drift.dart';

import 'package:life_os/features/finance/data/local/transaction_table.dart';

class MarketPurchases extends Table {
  IntColumn get id => integer().autoIncrement()();
  DateTimeColumn get purchasedAt => dateTime()();
  IntColumn get totalCents => integer()();
  IntColumn get financeTransactionId => integer().nullable().references(
    Transactions,
    #id,
    onDelete: KeyAction.setNull,
  )();
}

class MarketItems extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text().withLength(min: 1, max: 120)();
  IntColumn get quantity => integer()();
  BoolColumn get checked => boolean().withDefault(const Constant(false))();
  IntColumn get purchaseId =>
      integer().nullable().references(MarketPurchases, #id)();
}
