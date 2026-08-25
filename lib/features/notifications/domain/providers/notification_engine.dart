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

    await const NotificationModuleReconciler().sync(
      repository: repository,
      db: db,
      today: today,
      isCancelled: () => _disposed,
    );
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

  DateTime _startOfDay(DateTime value) {
    return DateTime(value.year, value.month, value.day);
  }
}

/// Gera e reconcilia somente as notificações derivadas atualmente suportadas.
class NotificationModuleReconciler {
  const NotificationModuleReconciler();

  Future<void> sync({
    required NotificationsRepository repository,
    required AppDatabase db,
    DateTime? today,
    bool Function()? isCancelled,
  }) async {
    final now = DateTime.now();
    final baseDay = _startOfDay(today ?? now);

    await _syncExams(
      repository: repository,
      db: db,
      baseDay: baseDay,
      now: now,
      isCancelled: isCancelled,
    );
    if (_isCancelled(isCancelled)) return;

    await _syncMedications(
      repository: repository,
      db: db,
      baseDay: baseDay,
      now: now,
      isCancelled: isCancelled,
    );
    if (_isCancelled(isCancelled)) return;

    await _syncHabits(
      repository: repository,
      db: db,
      baseDay: baseDay,
      now: now,
      isCancelled: isCancelled,
    );
  }

  Future<void> _syncExams({
    required NotificationsRepository repository,
    required AppDatabase db,
    required DateTime baseDay,
    required DateTime now,
    required bool Function()? isCancelled,
  }) async {
    final validIds = <String>{};

    try {
      final subjects = await db.select(db.subjects).get();
      if (_isCancelled(isCancelled)) return;

      for (final subject in subjects) {
        if (_isCancelled(isCancelled)) return;
        if (!subject.hasExam || subject.examDate == null) continue;

        final examDate = DateTime.fromMillisecondsSinceEpoch(subject.examDate!);
        if (_startOfDay(examDate).isBefore(baseDay)) continue;

        final id = 'exam_${subject.id}';
        validIds.add(id);
        final daysUntil = _calendarDaysBetween(baseDay, examDate);

        await repository.saveLocalNotification(
          NotificationModel(
            id: id,
            title: 'Prova de ${subject.title}',
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
            dueDate: examDate,
            createdAt: now,
          ),
        );
      }

      if (_isCancelled(isCancelled)) return;
      await _deleteOrphans(
        repository: repository,
        prefix: 'exam_',
        validIds: validIds,
        isCancelled: isCancelled,
      );
    } catch (error, stackTrace) {
      AppLogger.e(
        'NotificationEngine: erro ao reconciliar estudos',
        error,
        stackTrace,
      );
    }
  }

  Future<void> _syncMedications({
    required NotificationsRepository repository,
    required AppDatabase db,
    required DateTime baseDay,
    required DateTime now,
    required bool Function()? isCancelled,
  }) async {
    final validIds = <String>{};

    try {
      final medications = await db.select(db.medications).get();
      if (_isCancelled(isCancelled)) return;

      for (final medication in medications) {
        if (_isCancelled(isCancelled)) return;

        final startDate = _startOfDay(medication.startDate);
        final endDate = medication.endDate == null
            ? null
            : _startOfDay(medication.endDate!);
        if (startDate.isAfter(baseDay)) continue;
        if (endDate != null && endDate.isBefore(baseDay)) continue;

        final id = 'health_med_${medication.firestoreId ?? medication.id}';
        validIds.add(id);
        final daysToEnd = endDate == null
            ? null
            : _calendarDaysBetween(baseDay, endDate);

        await repository.saveLocalNotification(
          NotificationModel(
            id: id,
            title: 'Medicamento: ${medication.name}',
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
            dueDate: endDate ?? medication.startDate,
            createdAt: now,
          ),
        );
      }

      if (_isCancelled(isCancelled)) return;
      await _deleteOrphans(
        repository: repository,
        prefix: 'health_med_',
        validIds: validIds,
        isCancelled: isCancelled,
      );
    } catch (error, stackTrace) {
      AppLogger.e(
        'NotificationEngine: erro ao reconciliar medicamentos',
        error,
        stackTrace,
      );
    }
  }

  Future<void> _syncHabits({
    required NotificationsRepository repository,
    required AppDatabase db,
    required DateTime baseDay,
    required DateTime now,
    required bool Function()? isCancelled,
  }) async {
    final validIds = <String>{};

    try {
      final habits = await db.select(db.habits).get();
      if (_isCancelled(isCancelled)) return;

      final todayKey =
          '${baseDay.year.toString().padLeft(4, '0')}-'
          '${baseDay.month.toString().padLeft(2, '0')}-'
          '${baseDay.day.toString().padLeft(2, '0')}';

      for (final habit in habits) {
        if (_isCancelled(isCancelled)) return;

        final id = 'habit_${habit.id}';
        validIds.add(id);
        final completedToday = _decodeCompletedDates(
          habit.completedDates,
        ).contains(todayKey);

        await repository.saveLocalNotification(
          NotificationModel(
            id: id,
            title: 'Hábito: ${habit.title}',
            description: completedToday
                ? 'Hábito concluído hoje.'
                : 'Mantenha sua consistência! Registre seu progresso hoje.',
            priority: completedToday ? 'completed' : 'today',
            moduleType: 'habits',
            route: '/habits',
            isRead: completedToday,
            isCompleted: completedToday,
            dueDate: baseDay,
            createdAt: now,
          ),
        );
      }

      if (_isCancelled(isCancelled)) return;
      await _deleteOrphans(
        repository: repository,
        prefix: 'habit_',
        validIds: validIds,
        isCancelled: isCancelled,
      );
    } catch (error, stackTrace) {
      AppLogger.e(
        'NotificationEngine: erro ao reconciliar hábitos',
        error,
        stackTrace,
      );
    }
  }

  Future<void> _deleteOrphans({
    required NotificationsRepository repository,
    required String prefix,
    required Set<String> validIds,
    required bool Function()? isCancelled,
  }) async {
    final existing = await repository.getLocalNotifications();

    for (final notification in existing) {
      if (_isCancelled(isCancelled)) return;
      if (!notification.id.startsWith(prefix)) continue;
      if (validIds.contains(notification.id)) continue;

      await repository.deleteNotification(notification.id);
    }
  }

  bool _isCancelled(bool Function()? callback) => callback?.call() == true;

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
