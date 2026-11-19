import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/database_provider.dart';
import 'package:life_os/features/market/data/market_repository.dart';
import 'package:life_os/features/premium/domain/services/quota_service.dart';

final _marketRepository = Provider.autoDispose<MarketRepository>((ref) {
  return MarketRepository(ref.watch(databaseProvider));
});
final _marketList = StreamProvider.autoDispose<List<MarketItem>>((ref) {
  return ref.watch(_marketRepository).watchList();
});
final _marketHistory = StreamProvider.autoDispose<List<MarketReceipt>>((ref) {
  return ref.watch(_marketRepository).watchHistory();
});

class MarketScreen extends ConsumerStatefulWidget {
  const MarketScreen({super.key});

  @override
  ConsumerState<MarketScreen> createState() => _MarketScreenState();
}

class _MarketScreenState extends ConsumerState<MarketScreen> {
  bool _busy = false;

  Future<bool> _save(Future<void> Function(MarketRepository) action) async {
    if (_busy) return false;
    setState(() => _busy = true);
    try {
      await action(ref.read(_marketRepository));
      return true;
    } on PlanQuotaExceeded {
      if (mounted)
        _message(
          'Limite de Finanças atingido. Você pode salvar a compra sem lançar a despesa.',
        );
      return false;
    } catch (_) {
      if (mounted) _message('Não foi possível salvar a alteração.');
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _message(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _edit([MarketItem? item]) async {
    final result = await showDialog<({String name, int quantity})>(
      context: context,
      builder: (context) => _ItemDialog(item: item),
    );
    if (!mounted || result == null) return;
    await _save(
      (repository) => item == null
          ? repository.addItem(name: result.name, quantity: result.quantity)
          : repository.editItem(
              item.id,
              name: result.name,
              quantity: result.quantity,
            ),
    );
  }

  Future<void> _checkout() async {
    final result = await showDialog<({int cents, bool finance})>(
      context: context,
      builder: (context) => const _CheckoutDialog(),
    );
    if (!mounted || result == null) return;
    final saved = await _save((repository) async {
      await repository.checkout(
        totalCents: result.cents,
        recordExpense: result.finance,
      );
    });
    if (mounted && saved) _message('Compra salva no histórico.');
  }

  @override
  Widget build(BuildContext context) {
    final items = ref.watch(_marketList);
    final history = ref.watch(_marketHistory);
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Mercado'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Lista'),
              Tab(text: 'Histórico'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            items.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (_, _) => _retry(
                'Não foi possível abrir a lista.',
                () => ref.invalidate(_marketList),
              ),
              data: _list,
            ),
            history.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (_, _) => _retry(
                'Não foi possível abrir o histórico.',
                () => ref.invalidate(_marketHistory),
              ),
              data: _history,
            ),
          ],
        ),
      ),
    );
  }

  Widget _list(List<MarketItem> items) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _busy ? null : _edit,
                icon: const Icon(Icons.add),
                label: const Text('Adicionar item'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                onPressed: !_busy && items.any((item) => item.checked)
                    ? _checkout
                    : null,
                child: const Text('Finalizar compra'),
              ),
            ),
          ],
        ),
      ),
      Expanded(
        child: items.isEmpty
            ? const Center(child: Text('Sua lista está vazia.'))
            : ListView.builder(
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final item = items[index];
                  return ListTile(
                    key: ValueKey('market-item-${item.id}'),
                    leading: Checkbox(
                      semanticLabel: 'Marcar ${item.name}',
                      value: item.checked,
                      onChanged: _busy
                          ? null
                          : (value) {
                              if (value != null)
                                _save(
                                  (repository) =>
                                      repository.setChecked(item.id, value),
                                );
                            },
                    ),
                    title: Text(item.name),
                    subtitle: Text('Quantidade ${item.quantity}'),
                    trailing: PopupMenuButton<String>(
                      enabled: !_busy,
                      tooltip: 'Opções de ${item.name}',
                      onSelected: (action) {
                        if (action == 'edit') {
                          _edit(item);
                        } else {
                          _save((repository) => repository.removeItem(item.id));
                        }
                      },
                      itemBuilder: (context) => const [
                        PopupMenuItem(value: 'edit', child: Text('Editar')),
                        PopupMenuItem(
                          value: 'remove',
                          child: Text('Remover da lista'),
                        ),
                      ],
                    ),
                  );
                },
              ),
      ),
    ],
  );

  Widget _history(List<MarketReceipt> receipts) {
    if (receipts.isEmpty)
      return const Center(child: Text('Nenhuma compra registrada.'));
    final currency = NumberFormat.currency(locale: 'pt_BR', symbol: 'R\$');
    final date = DateFormat('dd/MM/yyyy HH:mm', 'pt_BR');
    return ListView.builder(
      itemCount: receipts.length,
      itemBuilder: (context, index) {
        final receipt = receipts[index];
        final purchase = receipt.purchase;
        return ExpansionTile(
          key: ValueKey('market-purchase-${purchase.id}'),
          title: Text(currency.format(purchase.totalCents / 100)),
          subtitle: Text(date.format(purchase.purchasedAt.toLocal())),
          children: [
            for (final item in receipt.items)
              ListTile(
                title: Text(item.name),
                trailing: Text('×${item.quantity}'),
              ),
            if (purchase.financeTransactionId != null)
              const ListTile(
                leading: Icon(Icons.account_balance_wallet_outlined),
                title: Text('Despesa registrada em Finanças'),
              ),
          ],
        );
      },
    );
  }

  Widget _retry(String message, VoidCallback onPressed) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(message),
        TextButton(onPressed: onPressed, child: const Text('Tentar novamente')),
      ],
    ),
  );
}

class _ItemDialog extends StatefulWidget {
  const _ItemDialog({this.item});
  final MarketItem? item;

  @override
  State<_ItemDialog> createState() => _ItemDialogState();
}

class _ItemDialogState extends State<_ItemDialog> {
  final _form = GlobalKey<FormState>();
  String _name = '';
  int _quantity = 1;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.item == null ? 'Novo item' : 'Editar item'),
    content: Form(
      key: _form,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              key: const Key('market-item-name'),
              initialValue: widget.item?.name,
              decoration: const InputDecoration(labelText: 'Nome'),
              maxLength: 120,
              textCapitalization: TextCapitalization.sentences,
              validator: (value) => value == null || value.trim().isEmpty
                  ? 'Informe o nome.'
                  : null,
              onSaved: (value) => _name = value!.trim(),
            ),
            TextFormField(
              key: const Key('market-item-quantity'),
              initialValue: (widget.item?.quantity ?? 1).toString(),
              decoration: const InputDecoration(labelText: 'Quantidade'),
              keyboardType: TextInputType.number,
              validator: (value) {
                final quantity = int.tryParse(value?.trim() ?? '');
                return quantity == null || quantity < 1 || quantity > 999
                    ? 'Use um número de 1 a 999.'
                    : null;
              },
              onSaved: (value) => _quantity = int.parse(value!.trim()),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancelar'),
      ),
      FilledButton(
        onPressed: () {
          if (!_form.currentState!.validate()) return;
          _form.currentState!.save();
          Navigator.of(context).pop((name: _name, quantity: _quantity));
        },
        child: const Text('Salvar item'),
      ),
    ],
  );
}

class _CheckoutDialog extends StatefulWidget {
  const _CheckoutDialog();

  @override
  State<_CheckoutDialog> createState() => _CheckoutDialogState();
}

class _CheckoutDialogState extends State<_CheckoutDialog> {
  final _form = GlobalKey<FormState>();
  bool _recordExpense = true;
  int _cents = 0;

  int? _parseCents(String? value) {
    final input = value?.trim() ?? '';
    if (!RegExp(r'^[0-9]{1,10}([,.][0-9]{1,2})?$').hasMatch(input)) return null;
    final parts = input.replaceAll(',', '.').split('.');
    final cents =
        int.parse(parts.first) * 100 +
        (parts.length == 1 ? 0 : int.parse(parts.last.padRight(2, '0')));
    return cents > 0 && cents <= MarketRepository.maxTotalCents ? cents : null;
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Finalizar compra'),
    content: Form(
      key: _form,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              key: const Key('market-total'),
              decoration: const InputDecoration(
                labelText: 'Total pago em reais',
                hintText: '48,75',
              ),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              validator: (value) => _parseCents(value) == null
                  ? 'Informe um valor válido, como 48,75.'
                  : null,
              onSaved: (value) => _cents = _parseCents(value)!,
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Registrar despesa em Finanças'),
              value: _recordExpense,
              onChanged: (value) =>
                  setState(() => _recordExpense = value ?? false),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancelar'),
      ),
      FilledButton(
        onPressed: () {
          if (!_form.currentState!.validate()) return;
          _form.currentState!.save();
          Navigator.of(context).pop((cents: _cents, finance: _recordExpense));
        },
        child: const Text('Salvar compra'),
      ),
    ],
  );
}
