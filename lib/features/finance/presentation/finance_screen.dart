import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:life_os/features/finance/presentation/providers/finance_provider.dart';
import 'package:life_os/core/security/input_sanitizer.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/utils/app_logger.dart';
import 'package:life_os/features/premium/domain/services/plan_limits.dart';
import 'package:life_os/features/premium/domain/services/quota_service.dart';
import 'package:life_os/features/premium/presentation/plan_limits_provider.dart';

class FinanceScreen extends ConsumerStatefulWidget {
  const FinanceScreen({super.key});

  @override
  ConsumerState<FinanceScreen> createState() => _FinanceScreenState();
}

class _FinanceTransactionInputControllers extends StatefulWidget {
  final Widget Function(
    TextEditingController titleController,
    TextEditingController amountController,
    TextEditingController customCategoryController,
  )
  builder;

  const _FinanceTransactionInputControllers({required this.builder});

  @override
  State<_FinanceTransactionInputControllers> createState() =>
      _FinanceTransactionInputControllersState();
}

class _FinanceTransactionInputControllersState
    extends State<_FinanceTransactionInputControllers> {
  final _titleController = TextEditingController();
  final _amountController = TextEditingController();
  final _customCategoryController = TextEditingController();

  @override
  void dispose() {
    _titleController.dispose();
    _amountController.dispose();
    _customCategoryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.builder(
      _titleController,
      _amountController,
      _customCategoryController,
    );
  }
}

class _FinanceScreenState extends ConsumerState<FinanceScreen> {
  final ScrollController _scrollController = ScrollController();

  bool _isLoadingMore = false;
  FinanceTypeFilter _typeFilter = FinanceTypeFilter.all;
  String? _categoryFilter;

  static const Color _backgroundColor = Color(0xFF070B14);
  static const Color _cardColor = Color(0xFF11182E);
  static const Color _inputColor = Color(0xFF0B1020);
  static const Color _primaryColor = Color(0xFFB45CFF);

  FinanceFilters get _filters =>
      FinanceFilters(type: _typeFilter, category: _categoryFilter);

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        ref.read(financeRepositoryProvider).syncTransactionsFromFirestore(),
      );
    });
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;

    final position = _scrollController.position;

    if (position.pixels >= position.maxScrollExtent - 200) {
      if (!_isLoadingMore) {
        setState(() => _isLoadingMore = true);

        ref.read(transactionLimitProvider.notifier).increment(15);

        Future.delayed(const Duration(milliseconds: 350), () {
          if (mounted) {
            setState(() => _isLoadingMore = false);
          }
        });
      }
    }
  }

  void _setTypeFilter(FinanceTypeFilter filter) {
    if (_typeFilter == filter) return;

    ref.read(transactionLimitProvider.notifier).reset();
    setState(() => _typeFilter = filter);
  }

  void _setCategoryFilter(String? category) {
    if (_categoryFilter == category) return;

    ref.read(transactionLimitProvider.notifier).reset();
    setState(() => _categoryFilter = category);
  }

  void _showMessage(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _showDeleteConfirmation(
    BuildContext context,
    WidgetRef ref,
    Transaction tx,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: _cardColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        title: const Text(
          'Excluir transação',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
        ),
        content: const Text(
          'Tem certeza? Esta ação não pode ser desfeita.',
          style: TextStyle(color: Colors.white70, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text(
              'Cancelar',
              style: TextStyle(color: Colors.white70),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text(
              'Excluir',
              style: TextStyle(
                color: Colors.redAccent,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await ref.read(financeRepositoryProvider).deleteTransaction(tx.id);
      } catch (error, stackTrace) {
        AppLogger.e('Falha ao excluir transação.', error, stackTrace);

        if (context.mounted) {
          _showMessage(
            context,
            'Não foi possível excluir a transação. Tente novamente.',
          );
        }
        return;
      }

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Transação excluída.'),
            behavior: SnackBarBehavior.floating,
            backgroundColor: _cardColor,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        );
      }
    }
  }

  void _showAddTransactionDialog(BuildContext context, WidgetRef ref) {
    String selectedType = 'expense';
    String? selectedCategory;
    bool isSubmitting = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _FinanceTransactionInputControllers(
        builder: (titleController, amountController, customCategoryController) => StatefulBuilder(
          builder: (context, setModalState) {
            return Container(
              decoration: const BoxDecoration(
                color: _cardColor,
                borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
              ),
              child: Padding(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.of(context).viewInsets.bottom,
                  left: 20,
                  right: 20,
                  top: 12,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: Container(
                          width: 42,
                          height: 4,
                          decoration: BoxDecoration(
                            color: Colors.white24,
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      const Text(
                        'Nova transação',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 23,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 5),
                      const Text(
                        'Registre uma nova movimentação financeira.',
                        style: TextStyle(color: Colors.white54, fontSize: 13),
                      ),
                      const SizedBox(height: 24),
                      const Text(
                        'Título',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: titleController,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                        ),
                        decoration: _inputDec(
                          'Ex: Mercado',
                          Icons.edit_outlined,
                        ),
                      ),
                      const SizedBox(height: 18),
                      const Text(
                        'Valor',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: amountController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                        decoration: _inputDec(
                          'R\$ 0,00',
                          Icons.attach_money_rounded,
                        ),
                      ),
                      const SizedBox(height: 20),
                      const Text(
                        'Tipo de transação',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: _TransactionTypeButton(
                              label: 'Entrada',
                              icon: Icons.arrow_upward_rounded,
                              color: Colors.greenAccent,
                              selected: selectedType == 'income',
                              onTap: () {
                                setModalState(() => selectedType = 'income');
                              },
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _TransactionTypeButton(
                              label: 'Saída',
                              icon: Icons.arrow_downward_rounded,
                              color: Colors.redAccent,
                              selected: selectedType == 'expense',
                              onTap: () {
                                setModalState(() => selectedType = 'expense');
                              },
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      const Text(
                        'Categoria',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: financeOfficialCategories.map((category) {
                          return ChoiceChip(
                            key: ValueKey('create-category-$category'),
                            label: Text(category),
                            selected: selectedCategory == category,
                            onSelected: (_) {
                              setModalState(() => selectedCategory = category);
                            },
                            selectedColor: _primaryColor.withValues(
                              alpha: 0.20,
                            ),
                            backgroundColor: _inputColor,
                            side: BorderSide(
                              color: selectedCategory == category
                                  ? _primaryColor.withValues(alpha: 0.65)
                                  : Colors.white10,
                            ),
                            labelStyle: TextStyle(
                              color: selectedCategory == category
                                  ? Colors.white
                                  : Colors.white60,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          );
                        }).toList(),
                      ),
                      if (selectedCategory == 'Outros') ...[
                        const SizedBox(height: 18),
                        const Text(
                          'Categoria personalizada',
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          key: const ValueKey('custom-category-field'),
                          controller: customCategoryController,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                          ),
                          decoration: _inputDec(
                            'Ex.: Pet',
                            Icons.category_outlined,
                          ),
                        ),
                      ],
                      const SizedBox(height: 26),
                      SizedBox(
                        width: double.infinity,
                        height: 54,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _primaryColor,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          onPressed: isSubmitting
                              ? null
                              : () async {
                                  if (isSubmitting) return;

                                  final title = InputSanitizer.sanitize(
                                    titleController.text,
                                  );

                                  if (title.isEmpty) {
                                    _showMessage(context, 'Informe o título.');
                                    return;
                                  }

                                  if (title.length > 200) {
                                    _showMessage(
                                      context,
                                      'O título deve ter no máximo 200 caracteres.',
                                    );
                                    return;
                                  }

                                  final selected = selectedCategory;
                                  if (selected == null) {
                                    _showMessage(
                                      context,
                                      'Selecione uma categoria.',
                                    );
                                    return;
                                  }

                                  final category = selected == 'Outros'
                                      ? InputSanitizer.sanitize(
                                          customCategoryController.text,
                                        )
                                      : selected;

                                  if (category.isEmpty) {
                                    _showMessage(
                                      context,
                                      'Informe a categoria personalizada.',
                                    );
                                    return;
                                  }

                                  if (category.length > 100) {
                                    _showMessage(
                                      context,
                                      'A categoria deve ter no máximo 100 caracteres.',
                                    );
                                    return;
                                  }

                                  final normalizedAmount = amountController.text
                                      .trim()
                                      .replaceAll(',', '.');
                                  final amount = double.tryParse(
                                    normalizedAmount,
                                  );

                                  if (amount == null ||
                                      !amount.isFinite ||
                                      amount <= 0 ||
                                      amount > 1000000000) {
                                    _showMessage(
                                      context,
                                      'Informe um valor válido.',
                                    );
                                    return;
                                  }

                                  final transactionsAsync = ref.read(
                                    financeStreamProvider,
                                  );

                                  if (!transactionsAsync.hasValue) {
                                    if (context.mounted) {
                                      _showMessage(
                                        context,
                                        'Não foi possível verificar suas transações agora. Tente novamente.',
                                      );
                                    }
                                    return;
                                  }

                                  final transactions =
                                      transactionsAsync.requireValue;

                                  final limits = ref.read(planLimitsProvider);
                                  const quotaService = QuotaService();

                                  final transactionLimit = limits.limitFor(
                                    QuotaResource.transactions,
                                  );

                                  final canCreate = quotaService.canCreate(
                                    limit: transactionLimit,
                                    currentCount: transactions.length,
                                  );

                                  if (!canCreate) {
                                    final message = switch (transactionLimit
                                        .mode) {
                                      QuotaMode.disabled =>
                                        'Este recurso não está disponível no seu plano.',
                                      QuotaMode.limited =>
                                        'Você atingiu o limite de ${transactionLimit.maximum} transações do seu plano.',
                                      QuotaMode.unlimited =>
                                        'Você não possui limite de transações.',
                                      QuotaMode.notConfigured =>
                                        'O limite deste recurso ainda não está configurado.',
                                    };

                                    if (context.mounted) {
                                      _showMessage(context, message);
                                    }

                                    return;
                                  }

                                  setModalState(() => isSubmitting = true);

                                  try {
                                    await ref
                                        .read(financeRepositoryProvider)
                                        .addTransaction(
                                          title: title,
                                          amount: amount,
                                          type: selectedType,
                                          category: category,
                                        );
                                  } catch (error, stackTrace) {
                                    AppLogger.e(
                                      'Falha ao criar transação.',
                                      error,
                                      stackTrace,
                                    );

                                    if (context.mounted) {
                                      setModalState(() => isSubmitting = false);
                                      _showMessage(
                                        context,
                                        'Não foi possível salvar a transação. Tente novamente.',
                                      );
                                    }
                                    return;
                                  }

                                  if (context.mounted) {
                                    Navigator.pop(context);
                                  }
                                },
                          child: const Text(
                            'Confirmar lançamento',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  InputDecoration _inputDec(String hint, IconData icon) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: Colors.white30),
      prefixIcon: Icon(icon, color: Colors.white38, size: 20),
      filled: true,
      fillColor: _inputColor,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Colors.white10),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: _primaryColor, width: 1.2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final allTransactionsAsync = ref.watch(financeStreamProvider);
    final visibleTransactionsAsync = ref.watch(
      financeVisibleTransactionsProvider(_filters),
    );

    return Scaffold(
      backgroundColor: _backgroundColor,
      floatingActionButton: FloatingActionButton(
        backgroundColor: _primaryColor,
        elevation: 8,
        onPressed: () => _showAddTransactionDialog(context, ref),
        child: const Icon(Icons.add_rounded, color: Colors.white, size: 28),
      ),
      body: SafeArea(
        child: allTransactionsAsync.when(
          loading: () => const Center(
            child: CircularProgressIndicator(color: _primaryColor),
          ),
          error: (error, stackTrace) {
            AppLogger.e('Falha ao carregar transações.', error, stackTrace);
            return const _FinanceLoadError();
          },
          data: (allTransactions) {
            final summary = calculateFinanceSummary(allTransactions);

            return visibleTransactionsAsync.when(
              loading: () => const Center(
                child: CircularProgressIndicator(color: _primaryColor),
              ),
              error: (error, stackTrace) {
                AppLogger.e('Falha ao filtrar transações.', error, stackTrace);
                return const _FinanceLoadError();
              },
              data: (visibleTransactions) {
                return CustomScrollView(
                  key: const PageStorageKey<String>('finance_scroll_position'),
                  controller: _scrollController,
                  cacheExtent: 500,
                  physics: const BouncingScrollPhysics(),
                  slivers: [
                    _FinanceSummary(
                      income: summary.income,
                      expense: summary.expense,
                      balance: summary.balance,
                    ),
                    _TransactionFilters(
                      type: _typeFilter,
                      category: _categoryFilter,
                      onTypeChanged: _setTypeFilter,
                      onCategoryChanged: _setCategoryFilter,
                    ),
                    _TransactionList(
                      transactions: visibleTransactions,
                      hasAnyTransactions: allTransactions.isNotEmpty,
                      onDelete: (tx) =>
                          _showDeleteConfirmation(context, ref, tx),
                    ),
                    if (_isLoadingMore)
                      const SliverToBoxAdapter(child: SizedBox(height: 8)),
                    const SliverToBoxAdapter(child: SizedBox(height: 90)),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }
}

// ============================================================================
// FILTROS
// ============================================================================

class _TransactionFilters extends StatelessWidget {
  static const _allCategoriesValue = '__all_categories__';

  final FinanceTypeFilter type;
  final String? category;
  final ValueChanged<FinanceTypeFilter> onTypeChanged;
  final ValueChanged<String?> onCategoryChanged;

  const _TransactionFilters({
    required this.type,
    required this.category,
    required this.onTypeChanged,
    required this.onCategoryChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      sliver: SliverToBoxAdapter(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              children: [
                _FinanceFilterChip(
                  key: const ValueKey('finance-type-filter-all'),
                  label: 'Todas',
                  selected: type == FinanceTypeFilter.all,
                  onSelected: () => onTypeChanged(FinanceTypeFilter.all),
                ),
                _FinanceFilterChip(
                  key: const ValueKey('finance-type-filter-income'),
                  label: 'Entradas',
                  selected: type == FinanceTypeFilter.income,
                  onSelected: () => onTypeChanged(FinanceTypeFilter.income),
                ),
                _FinanceFilterChip(
                  key: const ValueKey('finance-type-filter-expense'),
                  label: 'Saídas',
                  selected: type == FinanceTypeFilter.expense,
                  onSelected: () => onTypeChanged(FinanceTypeFilter.expense),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: const Color(0xFF0B1020),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white10),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  key: const ValueKey('finance-category-filter'),
                  value: category ?? _allCategoriesValue,
                  isExpanded: true,
                  dropdownColor: const Color(0xFF11182E),
                  iconEnabledColor: Colors.white54,
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                  items: [
                    const DropdownMenuItem(
                      value: _allCategoriesValue,
                      child: Text('Todas as categorias'),
                    ),
                    ...financeOfficialCategories.map(
                      (item) => DropdownMenuItem(
                        value: item,
                        child: Text(
                          item,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    onCategoryChanged(
                      value == _allCategoriesValue ? null : value,
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FinanceFilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onSelected;

  const _FinanceFilterChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onSelected(),
      showCheckmark: false,
      selectedColor: const Color(0xFFB45CFF).withValues(alpha: 0.20),
      backgroundColor: const Color(0xFF0B1020),
      side: BorderSide(
        color: selected
            ? const Color(0xFFB45CFF).withValues(alpha: 0.65)
            : Colors.white10,
      ),
      labelStyle: TextStyle(
        color: selected ? Colors.white : Colors.white60,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

class _FinanceLoadError extends StatelessWidget {
  const _FinanceLoadError();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Não foi possível carregar suas transações.',
              style: TextStyle(color: Colors.white70),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 6),
            Text(
              'Tente novamente em instantes.',
              style: TextStyle(color: Colors.white38, fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// RESUMO FINANCEIRO
// ============================================================================

class _FinanceSummary extends StatelessWidget {
  final double income;
  final double expense;
  final double balance;

  const _FinanceSummary({
    required this.income,
    required this.expense,
    required this.balance,
  });

  String _formatCurrency(double value) {
    return NumberFormat.currency(locale: 'pt_BR', symbol: 'R\$').format(value);
  }

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 0),
      sliver: SliverList(
        delegate: SliverChildListDelegate([
          const Text(
            'Minhas Finanças',
            style: TextStyle(
              color: Colors.white,
              fontSize: 27,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.6,
            ),
          ),
          const SizedBox(height: 5),
          const Text(
            'Acompanhe sua vida financeira de forma simples.',
            style: TextStyle(color: Colors.white54, fontSize: 13),
          ),
          const SizedBox(height: 20),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
            decoration: BoxDecoration(
              color: const Color(0xFF11182E),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.20),
                  blurRadius: 24,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: const Color(0xFFB45CFF).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(
                        Icons.account_balance_wallet_outlined,
                        color: Color(0xFFB45CFF),
                        size: 18,
                      ),
                    ),
                    const SizedBox(width: 10),
                    const Text(
                      'Saldo disponível',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 15),
                Text(
                  _formatCurrency(balance),
                  style: TextStyle(
                    color: balance >= 0 ? Colors.white : Colors.redAccent,
                    fontSize: 31,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.8,
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: _SummaryMetric(
                        icon: Icons.arrow_upward_rounded,
                        title: 'Entradas',
                        value: _formatCurrency(income),
                        color: Colors.greenAccent,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _SummaryMetric(
                        icon: Icons.arrow_downward_rounded,
                        title: 'Gastos',
                        value: _formatCurrency(expense),
                        color: Colors.redAccent,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          const Text(
            'Transações recentes',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
        ]),
      ),
    );
  }
}

// ============================================================================
// MÉTRICAS
// ============================================================================

class _SummaryMetric extends StatelessWidget {
  final IconData icon;
  final String title;
  final String value;
  final Color color;

  const _SummaryMetric({
    required this.icon,
    required this.title,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF070B14),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.10),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 16),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(color: Colors.white54, fontSize: 11),
                ),
                const SizedBox(height: 2),
                FittedBox(
                  alignment: Alignment.centerLeft,
                  fit: BoxFit.scaleDown,
                  child: Text(
                    value,
                    style: TextStyle(
                      color: color,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// LISTA
// ============================================================================

class _TransactionList extends StatelessWidget {
  final List transactions;
  final bool hasAnyTransactions;
  final Function(Transaction) onDelete;

  const _TransactionList({
    required this.transactions,
    required this.hasAnyTransactions,
    required this.onDelete,
  });

  String _formatCurrency(double value) {
    return NumberFormat.currency(locale: 'pt_BR', symbol: 'R\$').format(value);
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();

    final currentDay = DateTime(now.year, now.month, now.day);

    final transactionDay = DateTime(date.year, date.month, date.day);

    final difference = currentDay.difference(transactionDay).inDays;

    if (difference == 0) {
      return 'Hoje';
    }

    if (difference == 1) {
      return 'Ontem';
    }

    return DateFormat('dd/MM/yyyy').format(date);
  }

  @override
  Widget build(BuildContext context) {
    if (transactions.isEmpty) {
      return SliverPadding(
        padding: EdgeInsets.symmetric(horizontal: 20),
        sliver: SliverToBoxAdapter(
          child: _EmptyTransactions(filtered: hasAnyTransactions),
        ),
      );
    }

    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      sliver: SliverList(
        delegate: SliverChildBuilderDelegate((context, index) {
          final tx = transactions[index];
          final isIncome = tx.type == 'income';

          return RepaintBoundary(
            child: Container(
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(
                color: const Color(0xFF11182E),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.035),
                ),
              ),
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 7,
                ),
                leading: Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: isIncome
                        ? Colors.greenAccent.withValues(alpha: 0.10)
                        : Colors.redAccent.withValues(alpha: 0.10),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    isIncome
                        ? Icons.arrow_upward_rounded
                        : Icons.arrow_downward_rounded,
                    color: isIncome ? Colors.greenAccent : Colors.redAccent,
                    size: 20,
                  ),
                ),
                title: Text(
                  tx.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '${tx.category} · ${_formatDate(tx.date)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white38, fontSize: 11),
                  ),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${isIncome ? '+ ' : '- '}${_formatCurrency(tx.amount)}',
                      style: TextStyle(
                        color: isIncome ? Colors.greenAccent : Colors.redAccent,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 2),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: 'Excluir transação',
                      icon: const Icon(
                        Icons.delete_outline_rounded,
                        color: Colors.white30,
                        size: 19,
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

// ============================================================================
// ESTADO VAZIO
// ============================================================================

class _EmptyTransactions extends StatelessWidget {
  final bool filtered;

  const _EmptyTransactions({this.filtered = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 34),
      decoration: BoxDecoration(
        color: const Color(0xFF11182E),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.04)),
      ),
      child: Column(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: const Color(0xFFB45CFF).withValues(alpha: 0.10),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.receipt_long_outlined,
              color: Color(0xFFB45CFF),
              size: 24,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            filtered
                ? 'Nenhuma movimentação encontrada.'
                : 'Nenhuma transação ainda',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            filtered
                ? 'Ajuste os filtros para ver outras transações.'
                : 'Suas movimentações financeiras aparecerão aqui.',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white38,
              fontSize: 12,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// TIPO DE TRANSAÇÃO
// ============================================================================

class _TransactionTypeButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  const _TransactionTypeButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          height: 50,
          decoration: BoxDecoration(
            color: selected
                ? color.withValues(alpha: 0.10)
                : const Color(0xFF0B1020),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected
                  ? color.withValues(alpha: 0.55)
                  : Colors.white.withValues(alpha: 0.07),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: selected ? color : Colors.white38, size: 18),
              const SizedBox(width: 7),
              Text(
                label,
                style: TextStyle(
                  color: selected ? color : Colors.white60,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
