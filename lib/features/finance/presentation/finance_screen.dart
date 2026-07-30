import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:life_os/features/finance/presentation/providers/finance_provider.dart';
import 'package:life_os/core/security/input_sanitizer.dart';
import 'package:life_os/core/database/app_database.dart';

class FinanceScreen extends ConsumerStatefulWidget {
  const FinanceScreen({super.key});

  @override
  ConsumerState<FinanceScreen> createState() => _FinanceScreenState();
}

class _FinanceScreenState extends ConsumerState<FinanceScreen> {
  final ScrollController _scrollController = ScrollController();
  bool _isLoadingMore = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      if (!_isLoadingMore) {
        setState(() => _isLoadingMore = true);
        ref.read(transactionLimitProvider.notifier).increment(15);

        Future.delayed(const Duration(milliseconds: 600), () {
          if (mounted) setState(() => _isLoadingMore = false);
        });
      }
    }
  }

  Future<void> _showDeleteConfirmation(
    BuildContext context,
    WidgetRef ref,
    Transaction tx,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF11182E),
        title: const Text(
          "Excluir Transação",
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          "Tem certeza? Esta ação não pode ser desfeita.",
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text(
              "Cancelar",
              style: TextStyle(color: Colors.white70),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text(
              "Excluir",
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await ref.read(financeRepositoryProvider).deleteTransaction(tx.id);
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text("Transação excluída.")));
      }
    }
  }

  void _showAddTransactionDialog(BuildContext context, WidgetRef ref) {
    final titleController = TextEditingController();
    final amountController = TextEditingController();
    String selectedType = 'expense';
    String selectedCategory = 'Lazer';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF11182E),
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) {
          return Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).viewInsets.bottom,
              left: 20,
              right: 20,
              top: 24,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  "Nova Transação",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: titleController,
                  decoration: _inputDec("Título"),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: amountController,
                  keyboardType: TextInputType.number,
                  decoration: _inputDec("Valor (R\$)"),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: ChoiceChip(
                        label: const Center(child: Text("Entrada")),
                        selected: selectedType == 'income',
                        onSelected: (_) =>
                            setModalState(() => selectedType = 'income'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ChoiceChip(
                        label: const Center(child: Text("Saída")),
                        selected: selectedType == 'expense',
                        onSelected: (_) =>
                            setModalState(() => selectedType = 'expense'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton(
                    onPressed: () async {
                      final title = InputSanitizer.sanitize(
                        titleController.text,
                      );
                      if (title.isNotEmpty &&
                          amountController.text.isNotEmpty) {
                        final amount =
                            double.tryParse(
                              amountController.text.replaceAll(',', '.'),
                            ) ??
                            0.0;
                        await ref
                            .read(financeRepositoryProvider)
                            .addTransaction(
                              title: title,
                              amount: amount,
                              type: selectedType,
                              category: selectedCategory,
                            );
                        if (context.mounted) Navigator.pop(context);
                      }
                    },
                    child: const Text("Confirmar Lançamento"),
                  ),
                ),
                const SizedBox(height: 24),
              ],
            ),
          );
        },
      ),
    );
  }

  InputDecoration _inputDec(String label) => InputDecoration(
    labelText: label,
    labelStyle: const TextStyle(color: Colors.white54),
    filled: true,
    fillColor: const Color(0xFF070B14),
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
  );

  @override
  Widget build(BuildContext context) {
    final transactionsAsync = ref.watch(financeStreamProvider);

    return Scaffold(
      backgroundColor: const Color(0xFF070B14),
      floatingActionButton: FloatingActionButton(
        backgroundColor: Colors.purpleAccent,
        onPressed: () => _showAddTransactionDialog(context, ref),
        child: const Icon(Icons.add, color: Colors.white),
      ),
      body: SafeArea(
        child: transactionsAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (err, _) => Center(child: Text("Erro: $err")),
          data: (transactions) {
            double income = 0;
            double expense = 0;
            for (var t in transactions) {
              if (t.type == 'income') {
                income += t.amount;
              } else {
                expense += t.amount;
              }
            }
            final balance = income - expense;

            return CustomScrollView(
              controller: _scrollController,
              cacheExtent:
                  500, // 👈 Pré-renderiza itens fora da tela, evitando piscar no scroll rápido
              slivers: [
                _FinanceSummary(
                  income: income,
                  expense: expense,
                  balance: balance,
                ),
                _TransactionList(
                  transactions: transactions,
                  onDelete: (tx) => _showDeleteConfirmation(context, ref, tx),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

// 📦 Bloco isolado de Resumo Financeiro
class _FinanceSummary extends StatelessWidget {
  final double income;
  final double expense;
  final double balance;

  const _FinanceSummary({
    required this.income,
    required this.expense,
    required this.balance,
  });

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.all(20),
      sliver: SliverList(
        delegate: SliverChildListDelegate([
          const Text(
            "Minhas Finanças",
            style: TextStyle(
              color: Colors.white,
              fontSize: 26,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: _MiniCardFinance(
                  title: "Entradas",
                  value: "R\$ ${income.toStringAsFixed(2)}",
                  color: Colors.greenAccent,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _MiniCardFinance(
                  title: "Gastos",
                  value: "R\$ ${expense.toStringAsFixed(2)}",
                  color: Colors.redAccent,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _BalanceCard(balance: balance),
          const SizedBox(height: 25),
        ]),
      ),
    );
  }
}

// 📦 Bloco isolado da Listagem de Transações com RepaintBoundary otimizado
class _TransactionList extends StatelessWidget {
  final List<Transaction> transactions;
  final Function(Transaction) onDelete;

  const _TransactionList({required this.transactions, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      sliver: SliverList(
        delegate: SliverChildBuilderDelegate((context, index) {
          final tx = transactions[index];
          final isIncome = tx.type == 'income';

          return RepaintBoundary(
            child: Container(
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: const Color(0xFF11182E),
                borderRadius: BorderRadius.circular(16),
              ),
              child: ListTile(
                title: Text(
                  tx.title,
                  style: const TextStyle(color: Colors.white),
                ),
                subtitle: Text(DateFormat('dd/MM/yyyy').format(tx.date)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      "${isIncome ? '+ ' : '- '}R\$ ${tx.amount.toStringAsFixed(2)}",
                      style: TextStyle(
                        color: isIncome ? Colors.greenAccent : Colors.redAccent,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.delete_outline,
                        color: Colors.white54,
                      ),
                      onPressed: () => onDelete(tx),
                    ),
                  ],
                ),
              ),
            ),
          );
        }, childCount: transactions.length),
      ),
    );
  }
}

class _BalanceCard extends StatelessWidget {
  final double balance;
  const _BalanceCard({required this.balance});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
      decoration: BoxDecoration(
        color: const Color(0xFF11182E),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          const Text(
            "Saldo Disponível",
            style: TextStyle(color: Colors.white54, fontSize: 12),
          ),
          const SizedBox(height: 8),
          Text(
            "R\$ ${balance.toStringAsFixed(2)}",
            style: TextStyle(
              color: balance >= 0 ? Colors.white : Colors.redAccent,
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniCardFinance extends StatelessWidget {
  final String title;
  final String value;
  final Color color;
  const _MiniCardFinance({
    required this.title,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF11182E),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Text(
            title,
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}
