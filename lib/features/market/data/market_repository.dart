import 'package:drift/drift.dart';

import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/security/input_sanitizer.dart';
import 'package:life_os/features/finance/data/repositories/finance_repository.dart';

typedef MarketReceipt = ({MarketPurchase purchase, List<MarketItem> items});

class MarketRepository {
  MarketRepository(this._db) : _finance = FinanceRepository.local(_db);

  final AppDatabase _db;
  final FinanceRepository _finance;
  static const maxTotalCents = 100000000000;

  Stream<List<MarketItem>> watchList() =>
      (_db.select(_db.marketItems)
            ..where((item) => item.purchaseId.isNull())
            ..orderBy([
              (item) => OrderingTerm.asc(item.checked),
              (item) => OrderingTerm.asc(item.id),
            ]))
          .watch();

  Stream<List<MarketReceipt>> watchHistory() {
    final purchases = _db.marketPurchases;
    final items = _db.marketItems;
    final query = _db.select(purchases).join([
      leftOuterJoin(items, items.purchaseId.equalsExp(purchases.id)),
    ])..orderBy([OrderingTerm.desc(purchases.id), OrderingTerm.asc(items.id)]);
    return query.watch().map((rows) {
      final history = <MarketPurchase, List<MarketItem>>{};
      for (final row in rows) {
        final purchase = row.readTable(purchases);
        final purchasedItems = history.putIfAbsent(purchase, () => []);
        final item = row.readTableOrNull(items);
        if (item != null) purchasedItems.add(item);
      }
      return [
        for (final entry in history.entries)
          (purchase: entry.key, items: List.unmodifiable(entry.value)),
      ];
    });
  }

  Future<void> addItem({required String name, required int quantity}) async {
    final input = _itemData(name, quantity);
    await _db.into(_db.marketItems).insert(input);
  }

  Future<void> editItem(
    int id, {
    required String name,
    required int quantity,
  }) => _updateActiveItem(id, _itemData(name, quantity));

  Future<void> setChecked(int id, bool checked) =>
      _updateActiveItem(id, MarketItemsCompanion(checked: Value(checked)));

  Future<void> removeItem(int id) async {
    final removed = await (_db.delete(
      _db.marketItems,
    )..where((item) => item.id.equals(id) & item.purchaseId.isNull())).go();
    if (removed != 1) throw StateError('MARKET_ITEM_UNAVAILABLE');
  }

  Future<void> _updateActiveItem(int id, MarketItemsCompanion values) async {
    final changed =
        await (_db.update(_db.marketItems)
              ..where((item) => item.id.equals(id) & item.purchaseId.isNull()))
            .write(values);
    if (changed != 1) throw StateError('MARKET_ITEM_UNAVAILABLE');
  }

  MarketItemsCompanion _itemData(String name, int quantity) {
    final cleanName = InputSanitizer.sanitize(name);
    if (cleanName.isEmpty ||
        cleanName.length > 120 ||
        quantity < 1 ||
        quantity > 999) {
      throw ArgumentError('Item ou quantidade inválida.');
    }
    return MarketItemsCompanion.insert(name: cleanName, quantity: quantity);
  }

  Future<int> checkout({required int totalCents, required bool recordExpense}) {
    if (totalCents < 1 || totalCents > maxTotalCents) {
      throw ArgumentError('Total da compra inválido.');
    }
    final admission = _db.localMutations.capture(
      expectedUid: _db.identity!.uid,
    );
    return _db.transaction(
      () async {
        final activeChecked =
            _db.marketItems.purchaseId.isNull() &
            _db.marketItems.checked.equals(true);
        final count = _db.marketItems.id.count();
        final selected =
            (await (_db.selectOnly(_db.marketItems)
                      ..addColumns([count])
                      ..where(activeChecked))
                    .getSingle())
                .read(count)!;
        if (selected == 0) throw StateError('MARKET_CHECKOUT_EMPTY');

        final expenseId = recordExpense
            ? await _finance.addLocalExpense(
                title: 'Compra de mercado',
                amount: totalCents / 100,
                category: 'Alimentação',
              )
            : null;
        final purchaseId = await _db
            .into(_db.marketPurchases)
            .insert(
              MarketPurchasesCompanion.insert(
                purchasedAt: DateTime.now(),
                totalCents: totalCents,
                financeTransactionId: Value(expenseId),
              ),
            );
        final archived =
            await (_db.update(_db.marketItems)..where((_) => activeChecked))
                .write(MarketItemsCompanion(purchaseId: Value(purchaseId)));
        if (archived != selected) throw StateError('MARKET_CHECKOUT_CHANGED');
        return purchaseId;
      },
      admission: admission,
      waitForReopen: false,
    );
  }
}
