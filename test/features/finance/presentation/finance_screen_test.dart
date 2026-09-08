import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/features/finance/data/repositories/finance_repository.dart';
import 'package:life_os/features/finance/presentation/finance_screen.dart';
import 'package:life_os/features/finance/presentation/providers/finance_provider.dart';
import 'package:life_os/features/premium/domain/services/plan_limits.dart';
import 'package:life_os/features/premium/presentation/plan_limits_provider.dart';

class _RecordingFinanceRepository extends Fake implements FinanceRepository {
  final Completer<void>? completer;
  int addCalls = 0;
  int syncCalls = 0;

  _RecordingFinanceRepository([this.completer]);

  @override
  Future<void> addTransaction({
    required String title,
    required double amount,
    required String type,
    required String category,
  }) {
    addCalls += 1;
    return completer?.future ?? Future.value();
  }

  @override
  Future<void> syncTransactionsFromFirestore() async {
    syncCalls += 1;
  }
}

void main() {
  testWidgets('dois submits rápidos criam somente uma transação', (
    tester,
  ) async {
    final completer = Completer<void>();
    final repository = _RecordingFinanceRepository(completer);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          financeStreamProvider.overrideWith(
            (ref) => Stream.value(const <Transaction>[]),
          ),
          financeRepositoryProvider.overrideWithValue(repository),
          planLimitsProvider.overrideWithValue(PlanLimits.premium),
        ],
        child: const MaterialApp(home: FinanceScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), 'Mercado');
    await tester.enterText(find.byType(TextField).at(1), '10,50');

    final category = find.byKey(const ValueKey('create-category-Alimentação'));
    await tester.ensureVisible(category);
    await tester.tap(category);
    await tester.pump();

    final confirm = find.text('Confirmar lançamento');
    await tester.ensureVisible(confirm);
    await tester.tap(confirm);
    await tester.tap(confirm);
    await tester.pump();

    expect(repository.addCalls, 1);
    final button = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, 'Confirmar lançamento'),
    );
    expect(button.onPressed, isNull);

    completer.complete();
    await tester.pumpAndSettle();

    expect(find.text('Nova transação'), findsNothing);
  });

  testWidgets('erro do stream usa mensagem genérica sem detalhe interno', (
    tester,
  ) async {
    final repository = _RecordingFinanceRepository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          financeStreamProvider.overrideWith(
            (ref) => Stream<List<Transaction>>.error(
              StateError('detalhe privado do banco'),
            ),
          ),
          financeRepositoryProvider.overrideWithValue(repository),
        ],
        child: const MaterialApp(home: FinanceScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Não foi possível carregar suas transações.'),
      findsOneWidget,
    );
    expect(find.text('Tente novamente em instantes.'), findsOneWidget);
    expect(find.textContaining('detalhe privado'), findsNothing);
  });

  testWidgets('card mostra a categoria real da transação', (tester) async {
    final repository = _RecordingFinanceRepository();
    final transaction = Transaction(
      id: 1,
      firestoreId: 'remote-1',
      title: 'Consulta veterinária',
      amount: 80,
      type: 'expense',
      category: 'Pet',
      date: DateTime(2026, 9, 7),
      isDeleted: false,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          financeStreamProvider.overrideWith(
            (ref) => Stream.value([transaction]),
          ),
          financeRepositoryProvider.overrideWithValue(repository),
        ],
        child: const MaterialApp(home: FinanceScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Consulta veterinária'), findsOneWidget);
    expect(find.textContaining('Pet ·'), findsOneWidget);
  });

  testWidgets('resumo usa todas as transações mesmo com lista filtrada', (
    tester,
  ) async {
    final repository = _RecordingFinanceRepository();
    final transactions = [
      Transaction(
        id: 1,
        firestoreId: 'income-1',
        title: 'Salário',
        amount: 1000,
        type: 'income',
        category: 'Salário',
        date: DateTime(2026, 9, 7),
        isDeleted: false,
      ),
      Transaction(
        id: 2,
        firestoreId: 'expense-1',
        title: 'Mercado',
        amount: 250,
        type: 'expense',
        category: 'Alimentação',
        date: DateTime(2026, 9, 7),
        isDeleted: false,
      ),
    ];
    final currency = NumberFormat.currency(locale: 'pt_BR', symbol: 'R\$');

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          financeStreamProvider.overrideWith(
            (ref) => Stream.value(transactions),
          ),
          financeRepositoryProvider.overrideWithValue(repository),
        ],
        child: const MaterialApp(home: FinanceScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(currency.format(750)), findsOneWidget);
    expect(find.text(currency.format(1000)), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('finance-type-filter-expense')));
    await tester.pumpAndSettle();

    expect(find.text('Salário'), findsNothing);
    expect(find.text('Mercado'), findsOneWidget);
    expect(find.text(currency.format(750)), findsOneWidget);
    expect(find.text(currency.format(1000)), findsOneWidget);
  });

  testWidgets('mudar filtros de tipo e categoria reseta paginação', (
    tester,
  ) async {
    final repository = _RecordingFinanceRepository();
    final container = ProviderContainer(
      overrides: [
        financeStreamProvider.overrideWith(
          (ref) => Stream.value(const <Transaction>[]),
        ),
        financeRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: FinanceScreen()),
      ),
    );
    await tester.pumpAndSettle();

    container.read(transactionLimitProvider.notifier).increment(15);
    expect(container.read(transactionLimitProvider), 30);

    final expenseFilter = find.byKey(
      const ValueKey('finance-type-filter-expense'),
    );
    await tester.ensureVisible(expenseFilter);
    await tester.tap(expenseFilter);
    await tester.pumpAndSettle();

    expect(container.read(transactionLimitProvider), 15);

    container.read(transactionLimitProvider.notifier).increment(15);
    expect(container.read(transactionLimitProvider), 30);

    final categoryFilter = find.byKey(
      const ValueKey('finance-category-filter'),
    );
    await tester.ensureVisible(categoryFilter);
    final dropdown = tester.widget<DropdownButton<String>>(categoryFilter);
    dropdown.onChanged?.call('Alimentação');
    await tester.pump();

    expect(container.read(transactionLimitProvider), 15);
  });

  testWidgets('filtros aparecem e criação inicia sem categoria selecionada', (
    tester,
  ) async {
    final repository = _RecordingFinanceRepository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          financeStreamProvider.overrideWith(
            (ref) => Stream.value(const <Transaction>[]),
          ),
          financeRepositoryProvider.overrideWithValue(repository),
        ],
        child: const MaterialApp(home: FinanceScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Todas'), findsOneWidget);
    expect(find.text('Entradas'), findsWidgets);
    expect(find.text('Saídas'), findsWidgets);
    expect(find.text('Todas as categorias'), findsOneWidget);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    for (final category in financeOfficialCategories) {
      final finder = find.byKey(ValueKey('create-category-$category'));
      expect(finder, findsOneWidget);
      expect(tester.widget<ChoiceChip>(finder).selected, isFalse);
    }

    await tester.enterText(find.byType(TextField).at(0), 'Mercado');
    await tester.enterText(find.byType(TextField).at(1), '10,50');
    final confirmButton = find.text('Confirmar lançamento');
    await tester.ensureVisible(confirmButton);
    await tester.tap(confirmButton);
    await tester.pump();

    expect(find.text('Selecione uma categoria.'), findsOneWidget);
    expect(find.text('Nova transação'), findsOneWidget);

    final otherChip = find.byKey(const ValueKey('create-category-Outros'));
    await tester.ensureVisible(otherChip);
    await tester.tap(otherChip);
    await tester.pumpAndSettle();

    expect(find.text('Categoria personalizada'), findsOneWidget);
    expect(find.byKey(const ValueKey('custom-category-field')), findsOneWidget);
    expect(find.text('Ex.: Pet'), findsOneWidget);
  });

  testWidgets('montagem hidrata uma vez e rebuild normal não repete', (
    tester,
  ) async {
    final repository = _RecordingFinanceRepository();
    late StateSetter rebuildHost;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          financeStreamProvider.overrideWith(
            (ref) => Stream.value(const <Transaction>[]),
          ),
          financeRepositoryProvider.overrideWithValue(repository),
        ],
        child: MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              rebuildHost = setState;
              return const FinanceScreen();
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(repository.syncCalls, 1);

    rebuildHost(() {});
    await tester.pump();

    expect(repository.syncCalls, 1);
  });
}
