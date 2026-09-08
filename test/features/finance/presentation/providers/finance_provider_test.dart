import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/features/finance/presentation/providers/finance_provider.dart';

Transaction _transaction({
  required int id,
  required String type,
  required String category,
  double amount = 10,
}) {
  return Transaction(
    id: id,
    firestoreId: 'remote-$id',
    title: 'Transação $id',
    amount: amount,
    type: type,
    category: category,
    date: DateTime(2026, 9, 7).subtract(Duration(days: id)),
    isDeleted: false,
  );
}

void main() {
  test('resumo usa 20 transações enquanto lista inicial mostra 15', () {
    final transactions = List.generate(
      20,
      (index) => _transaction(
        id: index,
        type: index.isEven ? 'income' : 'expense',
        category: 'Moradia',
        amount: index.isEven ? 10 : 5,
      ),
    );

    final summary = calculateFinanceSummary(transactions);
    final visible = visibleFinanceTransactions(
      transactions: transactions,
      filters: const FinanceFilters(),
      limit: 15,
    );

    expect(visible, hasLength(15));
    expect(summary.income, 100);
    expect(summary.expense, 50);
    expect(summary.balance, 50);
  });

  test('aumentar paginação muda lista sem alterar resumo', () {
    final transactions = List.generate(
      20,
      (index) => _transaction(
        id: index,
        type: index.isEven ? 'income' : 'expense',
        category: 'Contas',
      ),
    );
    final summaryBefore = calculateFinanceSummary(transactions);

    final firstPage = visibleFinanceTransactions(
      transactions: transactions,
      filters: const FinanceFilters(),
      limit: 15,
    );
    final secondPage = visibleFinanceTransactions(
      transactions: transactions,
      filters: const FinanceFilters(),
      limit: 30,
    );
    final summaryAfter = calculateFinanceSummary(transactions);

    expect(firstPage, hasLength(15));
    expect(secondPage, hasLength(20));
    expect(summaryAfter.income, summaryBefore.income);
    expect(summaryAfter.expense, summaryBefore.expense);
    expect(summaryAfter.balance, summaryBefore.balance);
  });

  test('filtros de tipo e Alimentação combinam corretamente', () {
    final transactions = [
      _transaction(id: 1, type: 'income', category: 'Alimentação'),
      _transaction(id: 2, type: 'expense', category: 'Alimentação'),
      _transaction(id: 3, type: 'expense', category: 'Moradia'),
    ];

    final allFood = filterFinanceTransactions(
      transactions,
      const FinanceFilters(category: 'Alimentação'),
    );
    final incomeFood = filterFinanceTransactions(
      transactions,
      const FinanceFilters(
        type: FinanceTypeFilter.income,
        category: 'Alimentação',
      ),
    );
    final expenseFood = filterFinanceTransactions(
      transactions,
      const FinanceFilters(
        type: FinanceTypeFilter.expense,
        category: 'Alimentação',
      ),
    );

    expect(allFood, hasLength(2));
    expect(incomeFood, hasLength(1));
    expect(incomeFood.single.type, 'income');
    expect(expenseFood, hasLength(1));
    expect(expenseFood.single.type, 'expense');
  });

  test('filtro Outros inclui categoria personalizada e literal legada', () {
    final transactions = [
      _transaction(id: 1, type: 'expense', category: 'Pet'),
      _transaction(id: 2, type: 'expense', category: 'Outros'),
      _transaction(id: 3, type: 'expense', category: 'Moradia'),
    ];

    final filtered = filterFinanceTransactions(
      transactions,
      const FinanceFilters(category: 'Outros'),
    );

    expect(filtered.map((item) => item.category), ['Pet', 'Outros']);
  });

  test('filtro ocorre antes do limite de paginação', () {
    final transactions = [
      ...List.generate(
        16,
        (index) =>
            _transaction(id: index, type: 'expense', category: 'Moradia'),
      ),
      _transaction(id: 17, type: 'expense', category: 'Alimentação'),
    ];

    final visible = visibleFinanceTransactions(
      transactions: transactions,
      filters: const FinanceFilters(category: 'Alimentação'),
      limit: 15,
    );

    expect(visible, hasLength(1));
    expect(visible.single.id, 17);
  });

  test('tipo legado desconhecido não entra no resumo nem nos filtros', () {
    final transactions = [
      _transaction(id: 1, type: 'income', category: 'Trabalho', amount: 100),
      _transaction(id: 2, type: 'expense', category: 'Moradia', amount: 40),
      _transaction(id: 3, type: 'unknown', category: 'Moradia', amount: 500),
    ];

    final summary = calculateFinanceSummary(transactions);
    final all = filterFinanceTransactions(transactions, const FinanceFilters());
    final expenses = filterFinanceTransactions(
      transactions,
      const FinanceFilters(type: FinanceTypeFilter.expense),
    );

    expect(summary.income, 100);
    expect(summary.expense, 40);
    expect(summary.balance, 60);
    expect(all.map((item) => item.id), [1, 2]);
    expect(expenses.map((item) => item.id), [2]);
    expect(all.any((item) => item.type == 'unknown'), isFalse);
    expect(expenses.any((item) => item.type == 'unknown'), isFalse);
  });

  test('TransactionLimit reset volta para 15', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final notifier = container.read(transactionLimitProvider.notifier);
    notifier.increment(15);
    expect(container.read(transactionLimitProvider), 30);

    notifier.reset();
    expect(container.read(transactionLimitProvider), 15);
  });
}
