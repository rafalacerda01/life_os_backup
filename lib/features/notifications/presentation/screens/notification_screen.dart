import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/features/notifications/domain/providers/notification_engine.dart';
// 🟢 O Widget de tile já fará o import correto do model
import 'package:life_os/features/notifications/presentation/widgets/notification_tile.dart';

class NotificationScreen extends ConsumerWidget {
  const NotificationScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notificationsStream = ref.watch(notificationEngineProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Central de Notificações')),
      body: notificationsStream.when(
        data: (notifications) {
          if (notifications.isEmpty) {
            return const Center(child: Text('Nenhuma notificação no momento.'));
          }

          final highPriority = notifications
              .where((n) => n.priority == 'high' && !n.isCompleted)
              .toList();
          final today = notifications
              .where((n) => n.priority == 'today' && !n.isCompleted)
              .toList();
          final upcoming = notifications
              .where((n) => n.priority == 'upcoming' && !n.isCompleted)
              .toList();
          final completed = notifications.where((n) => n.isCompleted).toList();

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (highPriority.isNotEmpty) ...[
                Text(
                  'Alta Prioridade',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                ...highPriority.map((n) => NotificationTile(notification: n)),
                const SizedBox(height: 16),
              ],
              if (today.isNotEmpty) ...[
                Text(
                  'Hoje',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                ...today.map((n) => NotificationTile(notification: n)),
                const SizedBox(height: 16),
              ],
              if (upcoming.isNotEmpty) ...[
                Text(
                  'Próximos Dias',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                ...upcoming.map((n) => NotificationTile(notification: n)),
                const SizedBox(height: 16),
              ],
              if (completed.isNotEmpty) ...[
                Text(
                  'Concluídas',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Colors.grey,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                ...completed.map((n) => NotificationTile(notification: n)),
              ],
            ],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, stack) => Center(child: Text('Erro: $err')),
      ),
    );
  }
}
