import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/core/database/database_provider.dart';
import 'package:life_os/features/notifications/data/repositories/local_notification_inbox.dart';
import 'package:life_os/features/notifications/domain/models/notification_model.dart';

final _inboxProvider = Provider.autoDispose<LocalNotificationInbox>(
  (ref) => LocalNotificationInbox(ref.watch(databaseProvider)),
);

final _cardsProvider = StreamProvider.autoDispose<List<NotificationModel>>((
  ref,
) async* {
  final inbox = ref.watch(_inboxProvider);
  await inbox.reconcile();
  yield* inbox.watch();
});

class LocalNotificationCenterScreen extends ConsumerWidget {
  const LocalNotificationCenterScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cards = ref.watch(_cardsProvider);
    final inbox = ref.watch(_inboxProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Central de Notificações'),
        actions: [
          IconButton(
            onPressed: cards.isLoading
                ? null
                : () => ref.invalidate(_cardsProvider),
            icon: const Icon(Icons.refresh),
            tooltip: 'Atualizar notificações',
          ),
        ],
      ),
      body: cards.when(
        data: (rows) {
          if (rows.isEmpty) {
            return const Center(child: Text('Nenhuma notificação no momento.'));
          }
          const sections = {
            'high': 'Alta prioridade',
            'today': 'Hoje',
            'upcoming': 'Próximos dias',
            'completed': 'Concluídas',
            'normal': 'Geral',
          };
          final groups = <String, List<NotificationModel>>{};
          for (final card in rows) {
            final priority = card.isCompleted
                ? 'completed'
                : sections.containsKey(card.priority)
                ? card.priority
                : 'normal';
            groups.putIfAbsent(priority, () => []).add(card);
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              for (final entry in sections.entries)
                if (groups[entry.key] case final group?) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      entry.value,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  for (final card in group)
                    _NotificationCard(card: card, inbox: inbox),
                ],
            ],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => const Center(
          child: Text('Não foi possível carregar as notificações.'),
        ),
      ),
    );
  }
}

class _NotificationCard extends ConsumerWidget {
  const _NotificationCard({required this.card, required this.inbox});

  final NotificationModel card;
  final LocalNotificationInbox inbox;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final route = switch ((card.moduleType, card.route)) {
      ('studies', '/study') => '/study',
      ('health', '/health') => '/health',
      ('habits', '/habits') => '/habits',
      _ => null,
    };

    Future<bool> run(Future<void> Function() action) async {
      try {
        await action();
        return true;
      } catch (_) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Não foi possível atualizar a notificação.'),
            ),
          );
        }
        return false;
      }
    }

    return Card(
      child: ListTile(
        title: Text(
          card.title,
          style: card.isRead
              ? null
              : const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text(card.description),
        onTap: route == null
            ? null
            : () async {
                if (await run(() => inbox.markAsRead(card)) &&
                    context.mounted) {
                  await Navigator.of(context).pushNamed(route);
                  if (context.mounted) ref.invalidate(_cardsProvider);
                }
              },
        trailing: PopupMenuButton<bool>(
          tooltip: 'Ações da notificação',
          itemBuilder: (_) => [
            if (!card.isCompleted)
              const PopupMenuItem(value: true, child: Text('Concluir')),
            const PopupMenuItem(value: false, child: Text('Dispensar')),
          ],
          onSelected: (complete) async {
            await run(
              () =>
                  complete ? inbox.markAsCompleted(card) : inbox.dismiss(card),
            );
          },
        ),
      ),
    );
  }
}
