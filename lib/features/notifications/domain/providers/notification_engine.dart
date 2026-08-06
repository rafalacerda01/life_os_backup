import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:life_os/features/notifications/data/repositories/notifications_repository.dart';
import 'package:life_os/features/notifications/domain/models/notification_model.dart';
import 'package:life_os/features/home/presentation/providers/home_provider.dart';
import 'package:life_os/core/database/database_provider.dart'; // 👈 Necessário para acessar o banco local e a tabela de medicamentos

part 'notification_engine.g.dart';

@riverpod
class NotificationEngine extends _$NotificationEngine {
  @override
  Stream<List<NotificationModel>> build() {
    final repository = ref.watch(notificationsRepositoryProvider);

    // Dispara a varredura dos módulos existentes em background ao iniciar
    Future.microtask(() => syncExistingModules());

    return repository.watchLocalNotifications();
  }

  /// 🚀 Motor Inteligente: Varre Estudos e Saúde (Medicamentos) do banco local
  /// e consolida na tabela de notificações (Offline-First)
  Future<void> syncExistingModules() async {
    final repository = ref.read(notificationsRepositoryProvider);

    // ===================================================================
    // 1. ESTUDOS (Provas cadastradas)
    // ===================================================================
    try {
      final homeState = ref.read(homeStateProvider);
      final nextExam = homeState.nextExam;
      if (nextExam != null) {
        final examNotificationId = 'exam_${nextExam.id ?? 'upcoming'}';

        final notification = NotificationModel(
          id: examNotificationId,
          title: 'Prova de ${nextExam.title}',
          description:
              'Prepare-se! Sua prova está cadastrada e se aproximando.',
          priority: 'today',
          moduleType: 'studies',
          route: '/study',
          isRead: false,
          isCompleted: false,
          dueDate: nextExam.examDate,
          createdAt: DateTime.now(),
        );

        await repository.saveLocalNotification(notification);
      }
    } catch (_) {}

    // ===================================================================
    // 2. SAÚDE (Medicamentos ativos no Drift)
    // ===================================================================
    try {
      final db = ref.read(databaseProvider);
      final medications = await db.select(db.medications).get();

      for (var med in medications) {
        final medId = med.firestoreId ?? med.id.toString();
        final notificationId = 'health_med_$medId';

        final medNotification = NotificationModel(
          id: notificationId,
          title: 'Medicamento: ${med.name}',
          description: 'Lembrete de rotina de saúde e acompanhamento.',
          priority: 'high', // Saúde tem alta prioridade
          moduleType: 'health',
          route: '/health',
          isRead: false,
          isCompleted: false,
          dueDate: med.endDate ?? med.startDate,
          createdAt: DateTime.now(),
        );

        await repository.saveLocalNotification(medNotification);
      }
    } catch (_) {}
  }

  Future<void> markAsRead(String id) async {
    await ref.read(notificationsRepositoryProvider).markAsReadLocal(id);
  }

  Future<void> markAsCompleted(String id) async {
    await ref.read(notificationsRepositoryProvider).markAsCompletedLocal(id);
  }

  /// 🗑️ Remove a notificação específica do banco local (Drift)
  Future<void> removeNotification(String id) async {
    final repository = ref.read(notificationsRepositoryProvider);
    await repository.deleteNotification(id);
  }
}

@riverpod
int unreadNotificationsCount(Ref ref) {
  final notificationsAsync = ref.watch(notificationEngineProvider);
  return notificationsAsync.maybeWhen(
    data: (notifications) =>
        notifications.where((n) => !n.isRead && !n.isCompleted).length,
    orElse: () => 0,
  );
}
