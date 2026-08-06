import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
// 🟢 IMPORT CORRIGIDO PARA O DOMAIN
import 'package:life_os/features/notifications/domain/models/notification_model.dart';
import 'package:life_os/features/notifications/domain/providers/notification_engine.dart';

class NotificationTile extends ConsumerWidget {
  final NotificationModel notification;

  const NotificationTile({super.key, required this.notification});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      elevation: 0,
      color: notification.isRead
          ? Theme.of(context).colorScheme.surfaceContainerHighest
          : Theme.of(context).colorScheme.surface,
      shape: RoundedRectangleBorder(
        side: BorderSide(
          color: Theme.of(context).colorScheme.outlineVariant,
          width: 1,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ListTile(
        leading: Icon(
          _getIconForModule(notification.moduleType),
          color: notification.isRead
              ? Colors.grey
              : Theme.of(context).colorScheme.primary,
        ),
        title: Text(
          notification.title,
          style: TextStyle(
            fontWeight: notification.isRead
                ? FontWeight.normal
                : FontWeight.bold,
          ),
        ),
        subtitle: Text(notification.description),
        trailing: Checkbox(
          value: notification.isCompleted,
          onChanged: (val) {
            if (val == true) {
              ref
                  .read(notificationEngineProvider.notifier)
                  .markAsCompleted(notification.id);
            }
          },
        ),
        onTap: () {
          ref
              .read(notificationEngineProvider.notifier)
              .markAsRead(notification.id);
          context.push(notification.route);
        },
      ),
    );
  }

  IconData _getIconForModule(String module) {
    switch (module) {
      case 'health':
        return Icons.favorite;
      case 'habits':
        return Icons.loop;
      case 'studies':
        return Icons.school;
      case 'finances':
        return Icons.attach_money;
      default:
        return Icons.notifications;
    }
  }
}
