import 'dart:convert';

import 'package:drift/drift.dart'
    show Value, QueryInterceptor, QueryExecutor, ApplyInterceptor;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:life_os/core/database/local_mutation_gate.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/features/ai_companion/data/models/ai_insight.dart';
import 'package:life_os/features/ai_companion/data/repositories/ai_companion_repository.dart';
import 'package:life_os/features/ai_companion/data/services/ai_insight_context_builder.dart';

class _FlashcardQueryObserver extends QueryInterceptor {
  final reads =
      <({String sql, List<Object?> args, List<Map<String, Object?>> rows})>[];
  Future<void> Function()? afterRead;

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    final rows = await executor.runSelect(statement, args);
    if (statement.toLowerCase().contains('from flashcards')) {
      reads.add((sql: statement, args: List.of(args), rows: rows));
      await afterRead?.call();
    }
    return rows;
  }
}

class _SnapshotDatabase extends AppDatabase {
  _SnapshotDatabase(QueryExecutor executor) : super(executor: executor);
  bool insideSnapshot = false;
  Future<void> Function()? afterSnapshot;

  @override
  Future<T> transaction<T>(
    Future<T> Function() action, {
    bool requireNew = false,
    LocalMutationTicket? admission,
    bool waitForReopen = true,
  }) async {
    final result = await super.transaction(
      () async {
        insideSnapshot = true;
        try {
          return await action();
        } finally {
          insideSnapshot = false;
        }
      },
      requireNew: requireNew,
      admission: admission,
      waitForReopen: waitForReopen,
    );
    await afterSnapshot?.call();
    return result;
  }
}

void main() {
  late _SnapshotDatabase db;
  late _FlashcardQueryObserver observer;
  String? uid;
  late AIInsightContextBuilder builder;
  final now = DateTime(2026, 9, 22, 12);

  setUp(() {
    observer = _FlashcardQueryObserver();
    db = _SnapshotDatabase(NativeDatabase.memory().interceptWith(observer));
    uid = 'user-a';
    builder = AIInsightContextBuilder(
      db,
      currentUserIdProvider: () => uid,
      clock: () => now,
    );
  });
  tearDown(() async => db.close());

  Future<void> task(String id, String priority, {bool completed = false}) => db
      .into(db.taskTable)
      .insert(
        TaskTableCompanion.insert(
          id: id,
          title: 'SECRET_TASK_TITLE',
          priority: priority,
          isCompleted: Value(completed),
          date: now,
        ),
      );

  Future<void> habit(String id, String dates) => db
      .into(db.habits)
      .insert(
        HabitsCompanion.insert(
          id: id,
          title: 'SECRET_HABIT_TITLE',
          completedDates: dates,
        ),
      );

  Future<void> focus(DateTime at, int seconds) => db
      .into(db.focusLogs)
      .insert(
        FocusLogsCompanion.insert(
          targetId: 'SECRET_TARGET_ID',
          targetType: 'task',
          durationSeconds: seconds,
          timestamp: at.millisecondsSinceEpoch,
        ),
      );

  Future<void> transaction(
    DateTime at,
    double amount,
    String type,
    String category, {
    bool deleted = false,
  }) => db
      .into(db.transactions)
      .insert(
        TransactionsCompanion.insert(
          title: 'SECRET_TRANSACTION_DESCRIPTION',
          firestoreId: const Value('SECRET_TRANSACTION_ID'),
          amount: amount,
          type: type,
          category: category,
          date: at,
          isDeleted: Value(deleted),
        ),
      );

  Future<void> stats({
    int reviewQueue = 15,
    String id = 'main',
    int streak = 3,
    double progress = 0.75,
  }) => db
      .into(db.studyStats)
      .insert(
        StudyStatsCompanion.insert(
          id: id,
          streak: streak,
          reviewQueue: reviewQueue,
          progress: progress,
        ),
      );

  Future<void> subject() => db
      .into(db.subjects)
      .insert(
        SubjectsCompanion.insert(
          id: 'SECRET_SUBJECT_ID',
          title: 'SECRET_SUBJECT_TITLE',
          cardsToReview: 99,
          streakDays: 3,
          progress: 0.75,
          hasExam: false,
        ),
      );

  Future<void> card(String id, {DateTime? reviewed}) => db
      .into(db.flashcards)
      .insert(
        FlashcardsCompanion.insert(
          id: id,
          subjectId: 'SECRET_SUBJECT_ID',
          question: 'SECRET_QUESTION',
          answer: 'SECRET_ANSWER',
          lastReviewed: Value(reviewed?.millisecondsSinceEpoch),
        ),
      );

  int reviews(Map<String, Object?> context, AIInsightIntent intent) =>
      intent == AIInsightIntent.dailyOverview
      ? (context['study'] as Map)['review_queue'] as int
      : (context['current'] as Map)['study_review_queue'] as int;

  const studyIntents = [
    AIInsightIntent.dailyOverview,
    AIInsightIntent.weeklyOverview,
  ];
  for (final intent in studyIntents) {
    test(
      '${intent.wireValue}: stale cache 15 and subject cache 99 yield three due cards',
      () async {
        await stats();
        await subject();
        await card('SECRET_NEVER_REVIEWED');
        await card(
          'SECRET_REVIEWED_YESTERDAY',
          reviewed: DateTime(2026, 9, 21, 12),
        );
        await card(
          'SECRET_JUST_BEFORE_MIDNIGHT',
          reviewed: DateTime(2026, 9, 21, 23, 59, 59, 999),
        );
        await card('SECRET_REVIEWED_TODAY', reviewed: now);
        await card('SECRET_MIDNIGHT', reviewed: DateTime(2026, 9, 22));
        await card('SECRET_FUTURE', reviewed: DateTime(2026, 9, 23));
        observer.afterRead = () async {
          expect(db.insideSnapshot, isTrue);
        };

        final context = await builder.buildContext(
          intent,
          expectedUserId: 'user-a',
        );

        expect(reviews(context, intent), 3);
        if (intent == AIInsightIntent.dailyOverview) {
          expect(context['study'], {
            'streak': 3,
            'review_queue': 3,
            'progress_percent': 75.0,
          });
        } else {
          expect((context['current'] as Map)['study_streak'], 3);
          expect((context['current'] as Map)['study_progress_percent'], 75.0);
        }
        final read = observer.reads.single;
        expect(read.sql.toUpperCase(), contains('COUNT(*)'));
        expect(read.args, [DateTime(2026, 9, 22).millisecondsSinceEpoch]);
        expect(read.rows.single.keys, ['due_count']);
      },
    );

    test(
      '${intent.wireValue}: no cards reports zero despite stale cache',
      () async {
        await stats();
        final context = await builder.buildContext(
          intent,
          expectedUserId: 'user-a',
        );
        expect(reviews(context, intent), 0);
      },
    );

    test(
      '${intent.wireValue}: zero cache does not suppress due cards',
      () async {
        await stats(reviewQueue: 0);
        await subject();
        await card('SECRET_DUE_CARD');
        final context = await builder.buildContext(
          intent,
          expectedUserId: 'user-a',
        );
        expect(reviews(context, intent), 1);
      },
    );

    test('${intent.wireValue}: wire JSON contains aggregates only', () async {
      await stats();
      await subject();
      await card('SECRET_FLASHCARD_ID');
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        final body = jsonDecode(request.body) as Map;
        expect(body.keys.toSet(), {'version', 'intent', 'context'});
        expect(body['intent'], intent.wireValue);
        expect(
          reviews(Map<String, Object?>.from(body['context'] as Map), intent),
          1,
        );
        for (final marker in [
          'SECRET_',
          'question',
          'answer',
          'subject_id',
          'subjectId',
          'last_reviewed',
          'lastReviewed',
          'user-a',
        ]) {
          expect(request.body, isNot(contains(marker)));
        }
        return http.Response(
          jsonEncode({
            'version': 2,
            'intent': intent.wireValue,
            'insight': {
              'headline': 'Resumo',
              'summary': 'Seguro',
              'recommendation': 'Revisar',
            },
          }),
          200,
        );
      });
      addTearDown(client.close);
      final repository = AICompanionRepository(
        client: client,
        idTokenProvider: () async => 'test-id-token',
        appCheckTokenProvider: () async => 'test-app-check',
        currentUserIdProvider: () => uid,
      );
      final context = await builder.buildContext(
        intent,
        expectedUserId: 'user-a',
      );
      await repository.requestInsight(
        intent,
        context,
        expectedUserId: 'user-a',
      );
      expect(calls, 1);
    });

    for (final otherStats in [false, true]) {
      test(
        '${intent.wireValue}: absent main stats keeps study optional (other stats $otherStats)',
        () async {
          if (otherStats) await stats(id: 'other');
          await subject();
          await card('SECRET_DUE_CARD');
          final context = await builder.buildContext(
            intent,
            expectedUserId: 'user-a',
          );
          if (intent == AIInsightIntent.dailyOverview) {
            expect(context, isNot(contains('study')));
          } else {
            final current = context['current'] as Map;
            expect(current, isNot(contains('study_streak')));
            expect(current, isNot(contains('study_review_queue')));
            expect(current, isNot(contains('study_progress_percent')));
          }
          expect(observer.reads, isEmpty);
        },
      );
    }

    test(
      '${intent.wireValue}: review count reuses the single captured clock instant',
      () async {
        await stats();
        await subject();
        await card('SECRET_TODAY_CARD', reviewed: DateTime(2026, 9, 22));
        var clockCalls = 0;
        builder = AIInsightContextBuilder(
          db,
          currentUserIdProvider: () => uid,
          clock: () {
            clockCalls++;
            return clockCalls == 1
                ? DateTime(2026, 9, 22, 23, 59)
                : DateTime(2026, 9, 23, 0, 1);
          },
        );

        final context = await builder.buildContext(
          intent,
          expectedUserId: 'user-a',
        );

        expect(reviews(context, intent), 0);
        expect(clockCalls, 1);
        expect(observer.reads.single.args, [
          DateTime(2026, 9, 22).millisecondsSinceEpoch,
        ]);
      },
    );
  }

  for (final (label, reviewed, expected) in [
    ('never', null, 1),
    ('yesterday', DateTime(2026, 9, 21, 23, 59, 59, 999), 1),
    ('today', now, 0),
    ('exact midnight', DateTime(2026, 9, 22), 0),
  ]) {
    test('review boundary $label uses the official due predicate', () async {
      await stats();
      await subject();
      await card('SECRET_CARD', reviewed: reviewed);
      final context = await builder.buildContext(
        AIInsightIntent.dailyOverview,
        expectedUserId: 'user-a',
      );
      expect(reviews(context, AIInsightIntent.dailyOverview), expected);
    });
  }

  test(
    'a card reviewed today is due again on the next local day in both contracts',
    () async {
      await stats();
      await subject();
      await card('SECRET_CARD', reviewed: now);
      var currentTime = now;
      builder = AIInsightContextBuilder(
        db,
        currentUserIdProvider: () => uid,
        clock: () => currentTime,
      );
      for (final intent in studyIntents) {
        expect(
          reviews(
            await builder.buildContext(intent, expectedUserId: 'user-a'),
            intent,
          ),
          0,
        );
      }
      currentTime = DateTime(2026, 9, 23);
      for (final intent in studyIntents) {
        expect(
          reviews(
            await builder.buildContext(intent, expectedUserId: 'user-a'),
            intent,
          ),
          1,
        );
      }
    },
  );

  test(
    'finance context keeps its fields even when study data is present',
    () async {
      await stats();
      await subject();
      await card('SECRET_CARD');
      await transaction(now, 10, 'expense', 'Outros');
      final context = await builder.buildContext(
        AIInsightIntent.financeMonthSummary,
        expectedUserId: 'user-a',
      );
      expect(context, {
        'finance': {
          'income': 0.0,
          'expense': 10.0,
          'balance': -10.0,
          'transaction_count': 1,
          'top_expense_categories': [
            {'category': 'Outros', 'amount': 10.0},
          ],
        },
      });
      expect(observer.reads, isEmpty);
    },
  );

  test(
    'study streak and progress retain their bounds while review count is dynamic',
    () async {
      await stats(reviewQueue: -7, streak: 1000001, progress: 2);
      await subject();
      await card('SECRET_CARD');
      final context = await builder.buildContext(
        AIInsightIntent.dailyOverview,
        expectedUserId: 'user-a',
      );
      expect(context['study'], {
        'streak': 1000000,
        'review_queue': 1,
        'progress_percent': 100.0,
      });
    },
  );

  for (final phase in ['count', 'after snapshot']) {
    test('session switch $phase fails closed before remote request', () async {
      await stats();
      await subject();
      await card('SECRET_CARD');
      if (phase == 'count') {
        observer.afterRead = () async {
          uid = 'user-b';
        };
      } else {
        db.afterSnapshot = () async {
          uid = null;
        };
      }
      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        return http.Response('{}', 200);
      });
      addTearDown(client.close);
      final repository = AICompanionRepository(
        client: client,
        idTokenProvider: () async => 'test-id-token',
        appCheckTokenProvider: () async => 'test-app-check',
        currentUserIdProvider: () => uid,
      );
      Future<void> request() async {
        final context = await builder.buildContext(
          AIInsightIntent.dailyOverview,
          expectedUserId: 'user-a',
        );
        await repository.requestInsight(
          AIInsightIntent.dailyOverview,
          context,
          expectedUserId: 'user-a',
        );
      }

      await expectLater(request(), throwsA(isA<AIAuthenticationException>()));
      expect(calls, 0);
    });
  }

  for (final invalidUid in ['user-b', null]) {
    test(
      'initial session $invalidUid prevents building and remote request',
      () async {
        var calls = 0;
        final client = MockClient((_) async {
          calls++;
          return http.Response('{}', 200);
        });
        addTearDown(client.close);
        final repository = AICompanionRepository(
          client: client,
          idTokenProvider: () async => 'test-id-token',
          appCheckTokenProvider: () async => 'test-app-check',
          currentUserIdProvider: () => uid,
        );
        uid = invalidUid;
        Future<void> request() async {
          final context = await builder.buildContext(
            AIInsightIntent.dailyOverview,
            expectedUserId: 'user-a',
          );
          await repository.requestInsight(
            AIInsightIntent.dailyOverview,
            context,
            expectedUserId: 'user-a',
          );
        }

        await expectLater(request(), throwsA(isA<AIAuthenticationException>()));
        expect(calls, 0);
        expect(observer.reads, isEmpty);
      },
    );
  }

  test('empty daily summary is local and zero-valued', () async {
    final context = await builder.buildContext(
      AIInsightIntent.dailyOverview,
      expectedUserId: 'user-a',
    );
    expect(context['tasks'], {'pending': 0, 'high_priority_pending': 0});
    expect(context['habits'], {'active': 0, 'completed_today': 0});
    expect(context['focus'], {'minutes_today': 0, 'sessions_today': 0});
    expect(context, isNot(contains('checkin')));
    expect(context, isNot(contains('study')));
    final summary = await builder.buildLocalSummary(expectedUserId: 'user-a');
    expect(summary.pendingTasks, 0);
    expect(summary.energy, isNull);
  });

  test(
    'daily aggregates omit identifiers, titles and malformed habits',
    () async {
      await task('SECRET_TASK_ID', ' HIGH ');
      await task('completed', 'high', completed: true);
      await habit('today', '["2026-09-22"]');
      await habit('broken', 'not-json');
      await focus(DateTime(2026, 9, 22), 125);
      await focus(DateTime(2026, 9, 21, 23, 59, 59), 600);
      await db
          .into(db.checkInTable)
          .insert(
            CheckInTableCompanion.insert(
              id: 'secret-checkin',
              energy: 4,
              focus: 3,
              motivation: 5,
              createdAt: DateTime(2026, 9, 22, 10),
            ),
          );
      await db
          .into(db.studyStats)
          .insert(
            StudyStatsCompanion.insert(
              id: 'main',
              streak: 3,
              reviewQueue: 7,
              progress: 0.75,
            ),
          );
      await subject();
      for (var index = 0; index < 7; index++) {
        await card('SECRET_FLASHCARD_ID_$index');
      }
      await db
          .into(db.healthEntries)
          .insert(
            HealthEntriesCompanion.insert(
              docId: '2026-09-22',
              date: DateTime(2026, 9, 22, 9),
              mood: const Value('Radiante'),
              waterIntakeMl: const Value(1750),
            ),
          );
      await db
          .into(db.goals)
          .insert(
            GoalsCompanion.insert(
              id: 'SECRET_GOAL_ID',
              title: 'SECRET_GOAL_TITLE',
              period: 'daily',
              currentValue: 2,
              targetValue: 4,
              createdAt: now.millisecondsSinceEpoch,
              lastReset: now.millisecondsSinceEpoch,
            ),
          );
      final context = await builder.buildContext(
        AIInsightIntent.dailyOverview,
        expectedUserId: 'user-a',
      );
      expect(context['tasks'], {'pending': 1, 'high_priority_pending': 1});
      expect(context['habits'], {'active': 2, 'completed_today': 1});
      expect(context['focus'], {'minutes_today': 2, 'sessions_today': 1});
      expect(context['checkin'], {
        'energy': 4.0,
        'focus': 3.0,
        'motivation': 5.0,
      });
      expect(context['study'], {
        'streak': 3,
        'review_queue': 7,
        'progress_percent': 75.0,
      });
      expect(context['health'], {'hydration_ml': 1750, 'mood': 'radiante'});
      expect(context['goals'], {'active': 1, 'average_progress_percent': 50.0});
      final serialized = jsonEncode(context);
      for (final marker in [
        'SECRET_QUESTION',
        'SECRET_ANSWER',
        'SECRET_SUBJECT_TITLE',
        'SECRET_SUBJECT_ID',
        'SECRET_FLASHCARD_ID',
        'SECRET_TASK_TITLE',
        'SECRET_HABIT_TITLE',
        'SECRET_GOAL_TITLE',
        'SECRET_TARGET_ID',
        'SECRET_TASK_ID',
        'SECRET_GOAL_ID',
        'secret-checkin',
        'uid',
        'email',
      ]) {
        expect(serialized, isNot(contains(marker)));
      }
    },
  );

  test('weekly uses seven local calendar days and current snapshot', () async {
    await task('current', 'high');
    await habit('weekly', '["2026-09-16","2026-09-22","2026-09-15"]');
    await focus(DateTime(2026, 9, 16), 120);
    await focus(DateTime(2026, 9, 15, 23, 59, 59), 600);
    await transaction(DateTime(2026, 9, 16), 20, 'income', 'Outros');
    await transaction(DateTime(2026, 9, 22), 5, 'expense', 'Outros');
    await transaction(
      DateTime(2026, 9, 22),
      99,
      'expense',
      'Outros',
      deleted: true,
    );
    final context = await builder.buildContext(
      AIInsightIntent.weeklyOverview,
      expectedUserId: 'user-a',
    );
    expect(context['habits'], {'active': 1, 'completions_last_7_days': 2});
    expect(context['focus'], {
      'minutes_last_7_days': 2,
      'sessions_last_7_days': 1,
    });
    expect(context['finance'], {
      'income_last_7_days': 20.0,
      'expense_last_7_days': 5.0,
      'transaction_count_last_7_days': 2,
    });
    expect((context['current'] as Map)['pending_tasks'], 1);
    expect(
      jsonEncode(context),
      isNot(contains('SECRET_TRANSACTION_DESCRIPTION')),
    );
  });

  test(
    'unknown daily mood is omitted and latest valid check-in wins',
    () async {
      await db
          .into(db.healthEntries)
          .insert(
            HealthEntriesCompanion.insert(
              docId: '2026-09-22',
              date: DateTime(2026, 9, 22),
              mood: const Value('PRIVATE_UNKNOWN_MOOD'),
            ),
          );
      await db
          .into(db.checkInTable)
          .insert(
            CheckInTableCompanion.insert(
              id: 'old',
              energy: 2,
              focus: 2,
              motivation: 2,
              createdAt: DateTime(2026, 9, 22, 8),
            ),
          );
      await db
          .into(db.checkInTable)
          .insert(
            CheckInTableCompanion.insert(
              id: 'latest',
              energy: 5,
              focus: 4,
              motivation: 3,
              createdAt: DateTime(2026, 9, 22, 11),
            ),
          );
      final context = await builder.buildContext(
        AIInsightIntent.dailyOverview,
        expectedUserId: 'user-a',
      );
      expect(context['health'], {'hydration_ml': 0});
      expect(context['checkin'], {
        'energy': 5.0,
        'focus': 4.0,
        'motivation': 3.0,
      });
      expect(jsonEncode(context), isNot(contains('PRIVATE_UNKNOWN_MOOD')));
    },
  );

  test(
    'weekly health and check-ins aggregate; tied official moods become misto',
    () async {
      for (final (day, mood, water) in [
        (16, 'Radiante', 0),
        (22, 'Estressado', 2000),
        (15, 'Cansado', 10000),
      ]) {
        await db
            .into(db.healthEntries)
            .insert(
              HealthEntriesCompanion.insert(
                docId: '2026-09-$day',
                date: DateTime(2026, 9, day),
                mood: Value(mood),
                waterIntakeMl: Value(water),
              ),
            );
      }
      for (final (id, day, value) in [
        ('first', 16, 2.0),
        ('last', 22, 4.0),
        ('outside', 15, 5.0),
      ]) {
        await db
            .into(db.checkInTable)
            .insert(
              CheckInTableCompanion.insert(
                id: id,
                energy: value,
                focus: value,
                motivation: value,
                createdAt: DateTime(2026, 9, day),
              ),
            );
      }
      final context = await builder.buildContext(
        AIInsightIntent.weeklyOverview,
        expectedUserId: 'user-a',
      );
      expect(context['health'], {
        'entries_last_7_days': 2,
        'average_hydration_ml': 1000.0,
        'mood_summary': 'misto',
      });
      expect(context['checkin'], {
        'entries_last_7_days': 2,
        'average_energy': 3.0,
        'average_focus': 3.0,
        'average_motivation': 3.0,
      });
    },
  );

  test(
    'month includes exact boundaries and canonicalizes top categories',
    () async {
      await transaction(DateTime(2026, 9, 1), 100, 'income', 'Outros');
      await transaction(
        DateTime(2026, 9, 30, 23, 59, 59),
        40,
        'expense',
        'alimentacao',
      );
      await transaction(
        DateTime(2026, 9, 2),
        30,
        'expense',
        'unknown private category',
      );
      await transaction(DateTime(2026, 9, 3), 20, 'expense', 'Transporte');
      await transaction(DateTime(2026, 9, 4), 10, 'expense', 'Moradia');
      await transaction(
        DateTime(2026, 8, 31, 23, 59),
        900,
        'expense',
        'Outros',
      );
      await transaction(DateTime(2026, 10, 1), 900, 'expense', 'Outros');
      await transaction(
        DateTime(2026, 9, 10),
        900,
        'expense',
        'Outros',
        deleted: true,
      );
      final context = await builder.buildContext(
        AIInsightIntent.financeMonthSummary,
        expectedUserId: 'user-a',
      );
      final finance = context['finance'] as Map<String, Object?>;
      expect(finance['income'], 100);
      expect(finance['expense'], 100);
      expect(finance['balance'], 0);
      expect(finance['transaction_count'], 5);
      expect(finance['top_expense_categories'], [
        {'category': 'Alimentação', 'amount': 40.0},
        {'category': 'Outros', 'amount': 30.0},
        {'category': 'Transporte', 'amount': 20.0},
      ]);
      expect(jsonEncode(context), isNot(contains('unknown private category')));
    },
  );

  test(
    'different or absent session fails closed before local data leaves',
    () async {
      await expectLater(
        builder.buildContext(
          AIInsightIntent.dailyOverview,
          expectedUserId: 'user-b',
        ),
        throwsA(isA<AIAuthenticationException>()),
      );
      uid = null;
      await expectLater(
        builder.buildLocalSummary(expectedUserId: 'user-a'),
        throwsA(isA<AIAuthenticationException>()),
      );
    },
  );
}
