import 'dart:async';
import 'dart:convert';

import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/database_provider.dart';
import 'package:life_os/core/utils/app_logger.dart';
import 'package:life_os/features/notifications/data/repositories/notifications_repository.dart';
import 'package:life_os/features/notifications/domain/models/notification_model.dart';

part 'notification_engine.g.dart';

@riverpod
class NotificationEngine extends _$NotificationEngine {
  Future<void>? _bootstrapJob;
  DateTime? _lastBootstrapDay;
  bool _disposed = false;

  @override
  Stream<List<NotificationModel>> build() {
    final repository = ref.watch(notificationsRepositoryProvider);
    final db = ref.read(databaseProvider);

    ref.onDispose(() {
      _disposed = true;
      _bootstrapJob = null;
    });

    _scheduleBootstrap(repository: repository, db: db);

    return repository.watchLocalNotifications();
  }

  void _scheduleBootstrap({
    required NotificationsRepository repository,
    required AppDatabase db,
  }) {
    final today = _startOfDay(DateTime.now());

    if (_disposed) return;

    if (_bootstrapJob != null) return;

    if (_lastBootstrapDay != null && _lastBootstrapDay == today) {
      return;
    }

    final job = _bootstrap(today: today, repository: repository, db: db);

    _bootstrapJob = job;

    unawaited(
      job.whenComplete(() {
        if (_disposed) return;

        _bootstrapJob = null;
      }),
    );
  }

  Future<void> _bootstrap({
    required DateTime today,
    required NotificationsRepository repository,
    required AppDatabase db,
  }) async {
    if (_disposed) return;

    try {
      await repository.syncNotificationsFromFirebaseToLocal();

      if (_disposed) return;

      await syncExistingModules(repository: repository, db: db, today: today);

      if (_disposed) return;

      _lastBootstrapDay = today;
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
  /// As dependências são recebidas por parâmetro para impedir que
  /// `ref.read()` seja executado depois de um `await`.
  ///
  /// As notificações possuem IDs estáveis e o repository utiliza
  /// upsertPreservingState(), preservando o estado de leitura/conclusão.
  Future<void> syncExistingModules({
    required NotificationsRepository repository,
    required AppDatabase db,
    DateTime? today,
  }) async {
    if (_disposed) return;

    final now = DateTime.now();
    final baseDay = today ?? _startOfDay(now);

    // ===================================================================
    // 1. ESTUDOS — próxima prova cadastrada
    // ===================================================================
    try {
      final subjects = await db.select(db.subjects).get();

      if (_disposed) return;

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

        if (_disposed) return;
      }
    } catch (error, stackTrace) {
      AppLogger.e(
        'NotificationEngine: erro ao processar estudos',
        error,
        stackTrace,
      );
    }

    if (_disposed) return;

    // ===================================================================
    // 2. SAÚDE — medicamentos atualmente ativos
    // ===================================================================
    try {
      final medications = await db.select(db.medications).get();

      if (_disposed) return;

      for (final med in medications) {
        if (_disposed) return;

        final startDate = _startOfDay(med.startDate);
        final endDate = med.endDate == null ? null : _startOfDay(med.endDate!);

        if (startDate.isAfter(baseDay)) continue;

        if (endDate != null && endDate.isBefore(baseDay)) {
          continue;
        }

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

    if (_disposed) return;

    // ===================================================================
    // 3. HÁBITOS — somente pendências reais do dia
    // ===================================================================
    try {
      final habits = await db.select(db.habits).get();

      if (_disposed) return;

      final todayKey =
          '${baseDay.year.toString().padLeft(4, '0')}-'
          '${baseDay.month.toString().padLeft(2, '0')}-'
          '${baseDay.day.toString().padLeft(2, '0')}';

      for (final habit in habits) {
        if (_disposed) return;

        final completedDates = _decodeCompletedDates(habit.completedDates);

        final completedToday = completedDates.contains(todayKey);

        final notification = NotificationModel(
          id: 'habit_${habit.id}',
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
    if (_disposed) return;

    final repository = ref.read(notificationsRepositoryProvider);
    await repository.markAsReadLocal(id);
  }

  Future<void> markAsCompleted(String id) async {
    if (_disposed) return;

    final repository = ref.read(notificationsRepositoryProvider);
    await repository.markAsCompletedLocal(id);
  }

  Future<void> removeNotification(String id) async {
    if (_disposed) return;

    final repository = ref.read(notificationsRepositoryProvider);
    await repository.deleteNotification(id);
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
    if (daysToEnd != null && daysToEnd <= 3) {
      return 'high';
    }

    if (daysToEnd != null && daysToEnd <= 7) {
      return 'today';
    }

    return 'upcoming';
  }

  List<String> _decodeCompletedDates(String raw) {
    try {
      final decoded = jsonDecode(raw);

      if (decoded is List) {
        return decoded.map((value) => value.toString()).toList();
      }
    } catch (_) {
      // Dados antigos inválidos não devem derrubar a Central.
    }

    return const [];
  }
}

@riverpod
int unreadNotificationsCount(Ref ref) {
  final notificationsAsync = ref.watch(notificationEngineProvider);

  return notificationsAsync.maybeWhen(
    data: (notifications) => notifications
        .where(
          (notification) => !notification.isRead && !notification.isCompleted,
        )
        .length,
    orElse: () => 0,
  );
}
