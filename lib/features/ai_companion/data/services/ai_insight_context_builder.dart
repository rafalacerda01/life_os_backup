import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/features/ai_companion/data/models/ai_insight.dart';
import 'package:life_os/features/ai_companion/data/repositories/ai_companion_repository.dart';

typedef AIUserIdProvider = String? Function();
typedef AIClock = DateTime Function();

class AIInsightContextBuilder {
  AIInsightContextBuilder(
    this._database, {
    AIUserIdProvider? currentUserIdProvider,
    AIClock? clock,
  }) : _currentUserIdProvider =
           currentUserIdProvider ??
           (() => FirebaseAuth.instance.currentUser?.uid),
       _clock = clock ?? DateTime.now;

  final AppDatabase _database;
  final AIUserIdProvider _currentUserIdProvider;
  final AIClock _clock;

  static const _officialCategories = [
    'Alimentação',
    'Moradia',
    'Transporte',
    'Saúde',
    'Educação',
    'Lazer',
    'Assinaturas',
    'Compras',
    'Contas',
    'Investimentos',
    'Trabalho',
    'Outros',
  ];
  static const _officialMoods = {
    'radiante',
    'focado',
    'neutro',
    'cansado',
    'estressado',
  };

  void _ensureSession(String expectedUserId) {
    if (expectedUserId.isEmpty || _currentUserIdProvider() != expectedUserId) {
      throw const AIAuthenticationException();
    }
  }

  Future<AICompanionLocalSummary> buildLocalSummary({
    required String expectedUserId,
  }) async {
    final context = await buildContext(
      AIInsightIntent.dailyOverview,
      expectedUserId: expectedUserId,
    );
    final tasks = context['tasks']! as Map<String, Object?>;
    final habits = context['habits']! as Map<String, Object?>;
    final focus = context['focus']! as Map<String, Object?>;
    final checkin = context['checkin'] as Map<String, Object?>?;
    return AICompanionLocalSummary(
      pendingTasks: tasks['pending']! as int,
      completedHabitsToday: habits['completed_today']! as int,
      activeHabits: habits['active']! as int,
      focusMinutesToday: focus['minutes_today']! as int,
      energy: checkin?['energy'] as double?,
    );
  }

  Future<Map<String, Object?>> buildContext(
    AIInsightIntent intent, {
    required String expectedUserId,
  }) async {
    _ensureSession(expectedUserId);
    final now = _clock().toLocal();
    final today = DateTime(now.year, now.month, now.day);
    final tomorrow = DateTime(now.year, now.month, now.day + 1);
    final weekStart = DateTime(now.year, now.month, now.day - 6);
    final monthStart = DateTime(now.year, now.month);
    final nextMonth = DateTime(now.year, now.month + 1);
    final todayKey = _dayKey(today);
    final weekKeys = {
      for (var day = 0; day < 7; day++)
        _dayKey(DateTime(now.year, now.month, now.day - day)),
    };

    final context = await _database.transaction(() async {
      final tasks = await _database.select(_database.taskTable).get();
      final habits = await _database.select(_database.habits).get();
      final focusLogs = await _database.select(_database.focusLogs).get();
      final checkins = await _database.select(_database.checkInTable).get();
      final studyStats = await _database.select(_database.studyStats).get();
      final healthEntries = await _database
          .select(_database.healthEntries)
          .get();
      final goals = await _database.select(_database.goals).get();
      final transactions = await _database.select(_database.transactions).get();
      _ensureSession(expectedUserId);

      final pending = tasks.where((task) => !task.isCompleted).toList();
      final highPriority = pending
          .where((task) => task.priority.trim().toLowerCase() == 'high')
          .length;
      final currentTasks = <String, Object?>{
        'pending': _count(pending.length),
        'high_priority_pending': _count(highPriority),
      };
      final todayHabits = habits
          .where(
            (habit) => _completedDays(habit.completedDates).contains(todayKey),
          )
          .length;
      final currentHabits = <String, Object?>{
        'active': _count(habits.length),
        'completed_today': _count(todayHabits),
      };
      final currentGoals = <String, Object?>{
        'active': _count(goals.length),
        'average_progress_percent': goals.isEmpty
            ? 0.0
            : _percent(
                goals.fold<double>(0, (sum, goal) {
                      if (goal.targetValue <= 0) return sum;
                      return sum +
                          _percent(goal.currentValue / goal.targetValue * 100);
                    }) /
                    goals.length,
              ),
      };
      final study = studyStats.where((row) => row.id == 'main').firstOrNull;
      final currentStudy = study == null
          ? null
          : <String, Object?>{
              'streak': _count(study.streak),
              'review_queue': _count(study.reviewQueue),
              'progress_percent': _percent(study.progress * 100),
            };

      bool inWindow(DateTime date, DateTime start, DateTime end) =>
          !date.isBefore(start) && date.isBefore(end);
      final todayFocus = focusLogs
          .where(
            (log) =>
                log.durationSeconds > 0 &&
                inWindow(
                  DateTime.fromMillisecondsSinceEpoch(log.timestamp),
                  today,
                  tomorrow,
                ),
          )
          .toList();
      final weeklyFocus = focusLogs
          .where(
            (log) =>
                log.durationSeconds > 0 &&
                inWindow(
                  DateTime.fromMillisecondsSinceEpoch(log.timestamp),
                  weekStart,
                  tomorrow,
                ),
          )
          .toList();
      int focusMinutes(Iterable<int> durations, int maximum) =>
          (durations.fold<int>(0, (sum, value) => sum + value) ~/ 60).clamp(
            0,
            maximum,
          );
      final dailyCheckins =
          checkins
              .where((entry) => inWindow(entry.createdAt, today, tomorrow))
              .toList()
            ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      final weeklyCheckins = checkins
          .where((entry) => inWindow(entry.createdAt, weekStart, tomorrow))
          .toList();
      final dailyHealth =
          healthEntries
              .where((entry) => inWindow(entry.date, today, tomorrow))
              .toList()
            ..sort((a, b) => b.date.compareTo(a.date));
      final weeklyHealth = healthEntries
          .where((entry) => inWindow(entry.date, weekStart, tomorrow))
          .toList();

      if (intent == AIInsightIntent.dailyOverview) {
        final result = <String, Object?>{
          'tasks': currentTasks,
          'habits': currentHabits,
          'focus': {
            'minutes_today': focusMinutes(
              todayFocus.map((log) => log.durationSeconds),
              1440,
            ),
            'sessions_today': _count(todayFocus.length),
          },
          'goals': currentGoals,
        };
        if (currentStudy != null) result['study'] = currentStudy;
        if (dailyCheckins.isNotEmpty) {
          final checkin = dailyCheckins.first;
          if (_validCheckin(checkin.energy) &&
              _validCheckin(checkin.focus) &&
              _validCheckin(checkin.motivation)) {
            result['checkin'] = {
              'energy': checkin.energy,
              'focus': checkin.focus,
              'motivation': checkin.motivation,
            };
          }
        }
        if (dailyHealth.isNotEmpty) {
          final health = dailyHealth.first;
          final mood = _mood(health.mood);
          result['health'] = {
            'hydration_ml': health.waterIntakeMl.clamp(0, 100000),
            'mood': ?mood,
          };
        }
        return result;
      }

      final validWeeklyTransactions = transactions
          .where(
            (transaction) =>
                !transaction.isDeleted &&
                (transaction.type == 'income' ||
                    transaction.type == 'expense') &&
                _validMoney(transaction.amount) &&
                inWindow(transaction.date, weekStart, tomorrow),
          )
          .toList();
      if (intent == AIInsightIntent.weeklyOverview) {
        final moodCounts = <String, int>{};
        for (final entry in weeklyHealth) {
          final mood = _mood(entry.mood);
          if (mood != null) moodCounts[mood] = (moodCounts[mood] ?? 0) + 1;
        }
        final moodMaximum = moodCounts.values.fold<int>(
          0,
          (max, count) => count > max ? count : max,
        );
        final leaders = moodCounts.entries
            .where((entry) => entry.value == moodMaximum)
            .toList();
        final validCheckins = weeklyCheckins
            .where(
              (entry) =>
                  _validCheckin(entry.energy) &&
                  _validCheckin(entry.focus) &&
                  _validCheckin(entry.motivation),
            )
            .toList();
        double average(Iterable<double> values) =>
            (values.fold<double>(0, (sum, value) => sum + value) /
                    validCheckins.length)
                .clamp(1.0, 5.0);
        return <String, Object?>{
          'habits': {
            'active': _count(habits.length),
            'completions_last_7_days': _count(
              habits.fold<int>(
                0,
                (sum, habit) =>
                    sum +
                    _completedDays(
                      habit.completedDates,
                    ).where(weekKeys.contains).length,
              ),
            ),
          },
          'focus': {
            'minutes_last_7_days': focusMinutes(
              weeklyFocus.map((log) => log.durationSeconds),
              10080,
            ),
            'sessions_last_7_days': _count(weeklyFocus.length),
          },
          'health': {
            'entries_last_7_days': _count(weeklyHealth.length),
            if (weeklyHealth.isNotEmpty)
              'average_hydration_ml':
                  (weeklyHealth.fold<int>(
                            0,
                            (sum, entry) =>
                                sum + entry.waterIntakeMl.clamp(0, 100000),
                          ) /
                          weeklyHealth.length)
                      .clamp(0.0, 100000.0),
            if (leaders.isNotEmpty)
              'mood_summary': leaders.length == 1 ? leaders.first.key : 'misto',
          },
          'checkin': {
            'entries_last_7_days': _count(weeklyCheckins.length),
            if (validCheckins.isNotEmpty) ...{
              'average_energy': average(
                validCheckins.map((entry) => entry.energy),
              ),
              'average_focus': average(
                validCheckins.map((entry) => entry.focus),
              ),
              'average_motivation': average(
                validCheckins.map((entry) => entry.motivation),
              ),
            },
          },
          'finance': {
            'income_last_7_days': _sumMoney(
              validWeeklyTransactions
                  .where((transaction) => transaction.type == 'income')
                  .map((transaction) => transaction.amount),
            ),
            'expense_last_7_days': _sumMoney(
              validWeeklyTransactions
                  .where((transaction) => transaction.type == 'expense')
                  .map((transaction) => transaction.amount),
            ),
            'transaction_count_last_7_days': _count(
              validWeeklyTransactions.length,
            ),
          },
          'current': {
            'pending_tasks': currentTasks['pending'],
            'high_priority_pending_tasks':
                currentTasks['high_priority_pending'],
            if (currentStudy != null) ...{
              'study_streak': currentStudy['streak'],
              'study_review_queue': currentStudy['review_queue'],
              'study_progress_percent': currentStudy['progress_percent'],
            },
            'active_goals': currentGoals['active'],
            'average_goals_progress_percent':
                currentGoals['average_progress_percent'],
          },
        };
      }

      final monthlyTransactions = transactions
          .where(
            (transaction) =>
                !transaction.isDeleted &&
                (transaction.type == 'income' ||
                    transaction.type == 'expense') &&
                _validMoney(transaction.amount) &&
                inWindow(transaction.date, monthStart, nextMonth),
          )
          .toList();
      final income = _sumMoney(
        monthlyTransactions
            .where((transaction) => transaction.type == 'income')
            .map((transaction) => transaction.amount),
      );
      final expense = _sumMoney(
        monthlyTransactions
            .where((transaction) => transaction.type == 'expense')
            .map((transaction) => transaction.amount),
      );
      final categories = <String, double>{};
      for (final transaction in monthlyTransactions.where(
        (transaction) => transaction.type == 'expense',
      )) {
        final key = _category(transaction.category);
        categories[key] = ((categories[key] ?? 0) + transaction.amount).clamp(
          0.0,
          1000000000000.0,
        );
      }
      final top = categories.entries.toList()
        ..sort((a, b) {
          final amountOrder = b.value.compareTo(a.value);
          return amountOrder != 0 ? amountOrder : a.key.compareTo(b.key);
        });
      return <String, Object?>{
        'finance': {
          'income': income,
          'expense': expense,
          'balance': income - expense,
          'transaction_count': _count(monthlyTransactions.length),
          'top_expense_categories': [
            for (final entry in top.take(3))
              {'category': entry.key, 'amount': entry.value},
          ],
        },
      };
    });
    _ensureSession(expectedUserId);
    return context;
  }

  static String _dayKey(DateTime date) => DateFormat('yyyy-MM-dd').format(date);

  static Set<String> _completedDays(String encoded) {
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! List) return {};
      return decoded.whereType<String>().toSet();
    } catch (_) {
      return {};
    }
  }

  static int _count(int value) => value.clamp(0, 1000000);
  static double _percent(num value) =>
      value.isFinite ? value.clamp(0, 100).toDouble() : 0;
  static bool _validCheckin(double value) =>
      value.isFinite && value >= 1 && value <= 5;
  static bool _validMoney(double value) =>
      value.isFinite && value >= 0 && value <= 1000000000000;
  static double _sumMoney(Iterable<double> values) => values.fold<double>(
    0,
    (sum, value) => (sum + value).clamp(0.0, 1000000000000.0),
  );

  static String? _mood(String value) {
    final normalized = value.trim().toLowerCase();
    return _officialMoods.contains(normalized) ? normalized : null;
  }

  static String _category(String value) {
    String fold(String text) => text
        .trim()
        .toLowerCase()
        .replaceAll(RegExp('[áàâãä]'), 'a')
        .replaceAll(RegExp('[éèêë]'), 'e')
        .replaceAll(RegExp('[íìîï]'), 'i')
        .replaceAll(RegExp('[óòôõö]'), 'o')
        .replaceAll(RegExp('[úùûü]'), 'u')
        .replaceAll('ç', 'c');
    final normalized = fold(value);
    for (final category in _officialCategories) {
      if (fold(category) == normalized) return category;
    }
    return 'Outros';
  }
}
