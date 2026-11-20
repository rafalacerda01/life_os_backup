import 'dart:convert';

import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/services/notification_preferences.dart';
import 'package:life_os/core/utils/app_logger.dart';
import 'package:life_os/features/notifications/domain/models/notification_model.dart';

abstract interface class NotificationDerivationStore {
  Future<List<NotificationModel>> getLocalNotifications();
  Future<void> saveLocalNotification(NotificationModel notification);
  Future<void> deleteDerivedNotification(String id);
}

/// Gera e reconcilia somente as notificações derivadas atualmente suportadas.
class NotificationModuleReconciler {
  const NotificationModuleReconciler({this.propagateErrors = false});

  final bool propagateErrors;

  Future<void> sync({
    required NotificationDerivationStore repository,
    required AppDatabase db,
    required NotificationPreferences preferences,
    DateTime? today,
    bool Function()? isCancelled,
  }) => db.localMutations.run(
    () => _syncAdmitted(
      repository: repository,
      db: db,
      preferences: preferences,
      today: today,
      isCancelled: isCancelled,
    ),
    waitForReopen: false,
  );

  Future<void> _syncAdmitted({
    required NotificationDerivationStore repository,
    required AppDatabase db,
    required NotificationPreferences preferences,
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
      enabled: preferences.allNotifications && preferences.studyReminders,
      isCancelled: isCancelled,
    );
    if (_isCancelled(isCancelled)) return;

    await _syncMedications(
      repository: repository,
      db: db,
      baseDay: baseDay,
      now: now,
      enabled: preferences.allNotifications && preferences.medicationReminders,
      isCancelled: isCancelled,
    );
    if (_isCancelled(isCancelled)) return;

    await _syncHabits(
      repository: repository,
      db: db,
      baseDay: baseDay,
      now: now,
      enabled: preferences.allNotifications && preferences.habitReminders,
      isCancelled: isCancelled,
    );
  }

  Future<void> _syncExams({
    required NotificationDerivationStore repository,
    required AppDatabase db,
    required DateTime baseDay,
    required DateTime now,
    required bool enabled,
    required bool Function()? isCancelled,
  }) async {
    final validIds = <String>{};

    try {
      if (!enabled) {
        await _deleteOrphans(
          repository: repository,
          prefix: 'exam_',
          validIds: validIds,
          isCancelled: isCancelled,
        );
        return;
      }

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
      if (propagateErrors) rethrow;
      AppLogger.e(
        'NotificationEngine: erro ao reconciliar estudos',
        error,
        stackTrace,
      );
    }
  }

  Future<void> _syncMedications({
    required NotificationDerivationStore repository,
    required AppDatabase db,
    required DateTime baseDay,
    required DateTime now,
    required bool enabled,
    required bool Function()? isCancelled,
  }) async {
    final validIds = <String>{};

    try {
      if (!enabled) {
        await _deleteOrphans(
          repository: repository,
          prefix: 'health_med_',
          validIds: validIds,
          isCancelled: isCancelled,
        );
        return;
      }

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
      if (propagateErrors) rethrow;
      AppLogger.e(
        'NotificationEngine: erro ao reconciliar medicamentos',
        error,
        stackTrace,
      );
    }
  }

  Future<void> _syncHabits({
    required NotificationDerivationStore repository,
    required AppDatabase db,
    required DateTime baseDay,
    required DateTime now,
    required bool enabled,
    required bool Function()? isCancelled,
  }) async {
    final validIds = <String>{};

    try {
      if (!enabled) {
        await _deleteOrphans(
          repository: repository,
          prefix: 'habit_',
          validIds: validIds,
          isCancelled: isCancelled,
        );
        return;
      }

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
      if (propagateErrors) rethrow;
      AppLogger.e(
        'NotificationEngine: erro ao reconciliar hábitos',
        error,
        stackTrace,
      );
    }
  }

  Future<void> _deleteOrphans({
    required NotificationDerivationStore repository,
    required String prefix,
    required Set<String> validIds,
    required bool Function()? isCancelled,
  }) async {
    final existing = await repository.getLocalNotifications();

    for (final notification in existing) {
      if (_isCancelled(isCancelled)) return;
      if (!notification.id.startsWith(prefix)) continue;
      if (validIds.contains(notification.id)) continue;

      await repository.deleteDerivedNotification(notification.id);
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
