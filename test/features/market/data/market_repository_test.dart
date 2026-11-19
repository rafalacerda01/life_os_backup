import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/database_sync_policy.dart';
import 'package:life_os/core/database/local_database_identity.dart';
import 'package:life_os/features/finance/data/repositories/finance_repository.dart';
import 'package:life_os/features/market/data/market_repository.dart';
import 'package:life_os/features/premium/domain/services/quota_service.dart';

void main() {
  late AppDatabase database;
  late MarketRepository repository;

  setUp(() {
    database = AppDatabase.forUser(
      identity: LocalDatabaseIdentity(
        'local-v1-123e4567-e89b-42d3-a456-426614174000',
      ),
      executor: NativeDatabase.memory(
        setup: (db) => db.execute('PRAGMA foreign_keys = ON'),
      ),
      syncPolicy: DatabaseSyncPolicy.localOnly,
    );
    repository = MarketRepository(database);
    addTearDown(database.closeDatabase);
  });

  Future<int> checkItem(String name) async {
    await repository.addItem(name: name, quantity: 1);
    final item = (await repository.watchList().first).singleWhere(
      (item) => item.name == name,
    );
    await repository.setChecked(item.id, true);
    return item.id;
  }

  test('validates item quantities, amount and empty selection', () async {
    await expectLater(
      repository.addItem(name: ' ', quantity: 1),
      throwsArgumentError,
    );
    await expectLater(
      repository.addItem(name: 'Arroz', quantity: 0),
      throwsArgumentError,
    );
    expect(
      () => repository.checkout(totalCents: 0, recordExpense: false),
      throwsArgumentError,
    );
    await expectLater(
      repository.checkout(totalCents: 500, recordExpense: false),
      throwsStateError,
    );
    expect(await repository.watchList().first, isEmpty);
    expect(await repository.watchHistory().first, isEmpty);
  });

  test('edits active items and keeps archived items tied to expense', () async {
    final rice = await checkItem('Arroz');
    await repository.editItem(rice, name: 'Arroz integral', quantity: 2);
    await repository.addItem(name: 'Café', quantity: 3);
    await repository.addItem(name: 'Suco', quantity: 1);
    final juice = (await repository.watchList().first).singleWhere(
      (item) => item.name == 'Suco',
    );
    await repository.removeItem(juice.id);

    final purchase = await repository.checkout(
      totalCents: 4875,
      recordExpense: true,
    );
    final list = await repository.watchList().first;
    expect(list.single.name, 'Café');
    final receipt = (await repository.watchHistory().first).single;
    expect(receipt.purchase.id, purchase);
    expect(receipt.purchase.totalCents, 4875);
    expect(receipt.items.single.name, 'Arroz integral');
    expect(receipt.items.single.quantity, 2);
    final expense = (await database.select(database.transactions).get()).single;
    expect(receipt.purchase.financeTransactionId, expense.id);
    expect(expense.amount, 48.75);
    expect(expense.type, 'expense');
    expect(await database.select(database.syncQueueTable).get(), isEmpty);
    await expectLater(repository.setChecked(rice, false), throwsStateError);
    await expectLater(repository.removeItem(rice), throwsStateError);
    await FinanceRepository.local(database).deleteTransaction(expense.id);
    final retained = (await repository.watchHistory().first).single;
    expect(retained.purchase.financeTransactionId, isNull);
    expect(retained.items, receipt.items);
    expect(retained.purchase.totalCents, 4875);
  });

  test('two checkouts admit a single purchase for a selection', () async {
    await checkItem('Café');
    final first = repository.checkout(totalCents: 597, recordExpense: true);
    final second = repository.checkout(totalCents: 597, recordExpense: true);
    await expectLater(second, throwsStateError);
    await first;
    expect(await repository.watchHistory().first, hasLength(1));
    expect(await database.select(database.transactions).get(), hasLength(1));
  });

  test(
    'quota failure preserves the selection and allows purchase without expense',
    () async {
      final finance = FinanceRepository.local(database);
      for (var i = 0; i < 3; i++) {
        await finance.addLocalExpense(
          title: 'Sintético $i',
          amount: 1,
          category: 'Outros',
        );
      }
      final coffee = await checkItem('Café');
      await expectLater(
        repository.checkout(totalCents: 1279, recordExpense: true),
        throwsA(isA<PlanQuotaExceeded>()),
      );
      expect(await repository.watchHistory().first, isEmpty);
      final retained = (await repository.watchList().first).single;
      expect(retained.id, coffee);
      expect(retained.checked, true);

      await repository.checkout(totalCents: 1279, recordExpense: false);
      expect(
        (await repository.watchHistory().first)
            .single
            .purchase
            .financeTransactionId,
        isNull,
      );
      expect(await database.select(database.transactions).get(), hasLength(3));
      expect(await database.select(database.syncQueueTable).get(), isEmpty);
    },
  );

  test('late SQL error rolls back expense and receipt together', () async {
    await checkItem('Arroz');
    await database.customStatement('''
      CREATE TEMP TRIGGER fail_market_checkout
      BEFORE UPDATE OF purchase_id ON market_items
      BEGIN SELECT RAISE(ABORT, 'SYNTHETIC_MARKET_FAILURE'); END
    ''');
    await expectLater(
      repository.checkout(totalCents: 481, recordExpense: true),
      throwsA(
        predicate(
          (Object? error) =>
              error.toString().contains('SYNTHETIC_MARKET_FAILURE'),
        ),
      ),
    );
    expect(await repository.watchHistory().first, isEmpty);
    expect((await repository.watchList().first).single.checked, true);
    expect(await database.select(database.transactions).get(), isEmpty);
    expect(await database.select(database.syncQueueTable).get(), isEmpty);
  });
}
