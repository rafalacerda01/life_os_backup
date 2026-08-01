import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/features/notifications/data/models/notification_model.dart';
import 'package:life_os/features/notifications/data/repositories/notifications_repository.dart';

// --- INJEÇÃO DO REPOSITÓRIO ---
final notificationsRepositoryProvider = Provider<NotificationsRepository>((
  ref,
) {
  return NotificationsRepository();
});

/// Provider reativo para listar notificações em tempo real com segurança
final notificationsProvider =
    StreamProvider.autoDispose<List<NotificationModel>>((ref) {
      final repository = ref.watch(notificationsRepositoryProvider);
      return repository.getNotificationsStream();
    });
