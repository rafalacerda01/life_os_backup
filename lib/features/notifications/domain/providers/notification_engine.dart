import 'dart:async';
import 'dart:convert';

import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:life_os/core/database/database_provider.dart';
import 'package:life_os/core/utils/app_logger.dart';
import 'package:life_os/features/notifications/data/repositories/notifications_repository.dart';
import 'package:life_os/features/notifications/domain/models/notification_model.dart';

part 'notification_engine.g.dart';

@riverpod
class NotificationEngine extends _$NotificationEngine {
  Future<void>? _bootstrapJob;
  DateTime? _lastBootstrapDay;

  @override
  Stream<List<NotificationModel>> build() {
    final repository = ref.watch(notificationsRepositoryProvider);
    _scheduleBootstrap();
    return repository.watchLocalNotifications();
  }

  void _scheduleBootstrap() {
    final today = _startOfDay(DateTime.now());

    if (_bootstrapJob != null) {
      return;
    }

    if (_lastBootstrapDay != null && _lastBootstrapDay == today) {
      return;
    }

    _bootstrapJob = _bootstrap(today).whenComplete(() {
      _lastBootstrapDay = today;
      _bootstrapJob = null;
    });

    unawaited(_bootstrapJob);
  }

  Future<void> _bootstrap(DateTime today) async {
    final repository = ref.read(notificationsRepositoryProvider);

    try {
      await repository.syncNotificationsFromFirebaseToLocal();
      await syncExistingModules(today: today);
    } catch (error, stackTrace) {
      AppLogger.e(
        'NotificationEngine: falha no bootstrap inicial',
        error,
        stackTrace,
      );
    }
  }

  /// Reconcilia notificações derivadas dos módulos existentes.
  ///
  /// Este método é idempotente: executar várias vezes não deve criar
  /// duplicatas nem apagar o estado de leitura/conclusão do usuário.
  Future<void> syncExistingModules({DateTime? today}) async {
    final repository = ref.read(notificationsRepositoryProvider);
    final db = ref.read(databaseProvider);
    final now = DateTime.now();
    final baseDay = today ?? _startOfDay(now);

    // ===================================================================
    // 1. ESTUDOS — próxima prova cadastrada
    // ===================================================================
    try {
      final subjects = await db.select(db.subjects).get();

      final exams =
          subjects
              .where((subject) => subject.hasExam && subject.examDate != null)
              .map(
                (subject) => (
                  id: subject.id,
                  title: subject.title,
                  date: DateTime.fromMillisecondsSinceEpoch(subject.examDate!),
                ),
              )
              .where((exam) => !exam.date.isBefore(now))
              .toList()
            ..sort((a, b) => a.date.compareTo(b.date));

      if (exams.isNotEmpty) {
        final nextExam = exams.first;
        final daysUntil = _calendarDaysBetween(baseDay, nextExam.date);

        final notification = NotificationModel(
          id: 'exam_${nextExam.id}',
          title: 'Prova de ${nextExam.title}',
          description: daysUntil == 0
              ? 'Sua prova é hoje. Prepare-se!'
              : daysUntil == 1
              ? 'Sua prova é amanhã. Reserve um tempo para revisar.'
              : 'Sua prova está se aproximando.',
          priority: _examPriority(daysUntil),
          moduleType: 'studies',
          route: '/study',
          isRead: false,
          isCompleted: false,
          dueDate: nextExam.date,
          createdAt: now,
        );

        await repository.saveLocalNotification(notification);
      }
    } catch (error, stackTrace) {
      AppLogger.e(
        'NotificationEngine: erro ao processar estudos',
        error,
        stackTrace,
      );
    }

    // ===================================================================
    // 2. SAÚDE — medicamentos atualmente ativos
    // ===================================================================
    try {
      final medications = await db.select(db.medications).get();

      for (final med in medications) {
        final startDate = _startOfDay(med.startDate);
        final endDate = med.endDate == null ? null : _startOfDay(med.endDate!);

        // Sem horário/posologia nesta fase: só usamos o período do tratamento.
        if (startDate.isAfter(baseDay)) continue;
        if (endDate != null && endDate.isBefore(baseDay)) continue;

        final daysToEnd = endDate == null
            ? null
            : _calendarDaysBetween(baseDay, endDate);

        final notification = NotificationModel(
          id: 'health_med_${med.firestoreId ?? med.id}',
          title: 'Medicamento: ${med.name}',
          description: daysToEnd == null
              ? 'Tratamento em andamento.'
              : daysToEnd == 0
              ? 'O tratamento termina hoje.'
              : daysToEnd <= 3
              ? 'O tratamento termina em $daysToEnd dia(s).'
              : 'Tratamento em andamento.',
          priority: _medicationPriority(daysToEnd),
          moduleType: 'health',
          route: '/health',
          isRead: false,
          isCompleted: false,
          dueDate: endDate ?? med.startDate,
          createdAt: now,
        );

        await repository.saveLocalNotification(notification);
      }
    } catch (error, stackTrace) {
      AppLogger.e(
        'NotificationEngine: erro ao processar medicamentos',
        error,
        stackTrace,
      );
    }

    // ===================================================================
    // 3. HÁBITOS — somente pendências reais do dia
    // ===================================================================
    try {
      final habits = await db.select(db.habits).get();
      final todayKey =
          '${baseDay.year.toString().padLeft(4, '0')}-'
          '${baseDay.month.toString().padLeft(2, '0')}-'
          '${baseDay.day.toString().padLeft(2, '0')}';

      for (final habit in habits) {
        final completedDates = _decodeCompletedDates(habit.completedDates);
        final completedToday = completedDates.contains(todayKey);

        // A identidade do item é estável para evitar duplicatas.
        final notificationId = 'habit_${habit.id}';
        final notification = NotificationModel(
          id: notificationId,
          title: 'Hábito: ${habit.title}',
          description: completedToday
              ? 'Hábito concluído hoje.'
              : 'Mantenha sua consistência! Registre seu progresso hoje.',
          priority: completedToday ? 'completed' : 'today',
          moduleType: 'habits',
          route: '/habits',
          isRead: false,
          isCompleted: completedToday,
          dueDate: baseDay,
          createdAt: now,
        );

        await repository.saveLocalNotification(notification);
      }
    } catch (error, stackTrace) {
      AppLogger.e(
        'NotificationEngine: erro ao processar hábitos',
        error,
        stackTrace,
      );
    }
  }

  Future<void> markAsRead(String id) async {
    await ref.read(notificationsRepositoryProvider).markAsReadLocal(id);
  }

  Future<void> markAsCompleted(String id) async {
    await ref.read(notificationsRepositoryProvider).markAsCompletedLocal(id);
  }

  Future<void> removeNotification(String id) async {
    await ref.read(notificationsRepositoryProvider).deleteNotification(id);
  }

  int _calendarDaysBetween(DateTime from, DateTime to) {
    final a = _startOfDay(from);
    final b = _startOfDay(to);
    return b.difference(a).inDays;
  }

  DateTime _startOfDay(DateTime value) {
    return DateTime(value.year, value.month, value.day);
  }

  String _examPriority(int daysUntil) {
    if (daysUntil <= 0) return 'high';
    if (daysUntil == 1) return 'today';
    return 'upcoming';
  }

  String _medicationPriority(int? daysToEnd) {
    if (daysToEnd != null && daysToEnd <= 3) return 'high';
    if (daysToEnd != null && daysToEnd <= 7) return 'today';
    return 'upcoming';
  }

  List<String> _decodeCompletedDates(String raw) {
    try {
      final decoded = _decodeJson(raw);
      if (decoded is List) {
        return decoded.map((value) => value.toString()).toList();
      }
    } catch (_) {
      // Dados antigos inválidos não devem derrubar a Central.
    }
    return const [];
  }

  dynamic _decodeJson(String raw) => jsonDecode(raw);
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
