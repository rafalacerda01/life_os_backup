import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:life_os/features/auth/domain/entities/user_entity.dart';
import 'package:life_os/features/auth/presentation/providers/auth_provider.dart';
import 'package:life_os/features/auth/presentation/providers/auth_state.dart';
import 'package:life_os/features/dashboard/data/models/dashboard_model.dart';
import 'package:life_os/features/dashboard/domain/entities/models/insight_model.dart';
import 'package:life_os/features/home/presentation/providers/home_provider.dart';
import 'package:life_os/features/home/presentation/providers/insight_provider.dart';
import 'package:life_os/features/home/presentation/screens/home_screen.dart';
import 'package:life_os/features/notifications/domain/providers/notification_engine.dart';
import 'package:life_os/features/premium/domain/entities/premium_status_entity.dart';
import 'package:life_os/features/premium/presentation/premium_provider.dart';

class _StaticAuthNotifier extends AuthNotifier {
  final String displayName;

  _StaticAuthNotifier(this.displayName);

  @override
  AuthState build() => AuthState.authenticated(
    UserEntity(
      uid: 'user-a',
      email: 'user@example.test',
      displayName: displayName,
      isPremium: true,
      xp: 0,
      level: 1,
      streak: 0,
    ),
  );
}

class _StaticPremiumNotifier extends PremiumNotifier {
  @override
  PremiumStatusEntity build() => PremiumStatusEntity(
    isPremium: true,
    tier: PremiumTier.monthly,
    expirationDate: DateTime.now().add(const Duration(days: 30)),
    activatedFeatures: const ['Companion IA'],
  );
}

const _insight = InsightModel(
  id: 'home-refine-insight',
  title: 'Resumo',
  message: 'Continue acompanhando sua rotina.',
  category: InsightCategory.balance,
  priority: InsightPriority.low,
);

DashboardModel _dashboard({bool hasData = true, int reviewQueue = 4}) =>
    DashboardModel(
      productivityScore: 75,
      hasProductivityData: hasData,
      healthScore: 85,
      hasHealthData: hasData,
      financialScore: 80,
      hasFinancialData: hasData,
      studyStreak: 2,
      studyReviewQueue: reviewQueue,
      studyProgress: 60,
      activeMedications: 2,
      transactionsCount: 3,
      financeBalance: 1234.56,
    );

Widget _homeApp({
  bool hasData = true,
  String displayName = 'Usuário',
  int reviewQueue = 4,
  int medicationCount = 2,
  DateTime Function()? now,
  Timer Function(Duration, void Function())? scheduleBoundary,
}) => ProviderScope(
  overrides: [
    homeStateProvider.overrideWithValue(
      HomeStateData(
        dashboard: _dashboard(hasData: hasData, reviewQueue: reviewQueue),
        completedHabitsToday: 3,
        totalHabits: 5,
        nextExam: null,
        medicationCount: medicationCount,
      ),
    ),
    authNotifierProvider.overrideWith(() => _StaticAuthNotifier(displayName)),
    premiumProvider.overrideWith(_StaticPremiumNotifier.new),
    unreadNotificationsCountProvider.overrideWith((ref) => 0),
    currentInsightProvider.overrideWithValue(_insight),
  ],
  child: MaterialApp(
    home: Scaffold(
      body: HomeScreen(
        now: now ?? () => DateTime(2026, 8, 21, 10),
        scheduleBoundary: scheduleBoundary,
      ),
    ),
  ),
);

class _BoundaryTimer implements Timer {
  _BoundaryTimer(this.delay, this.callback);

  final Duration delay;
  final void Function() callback;
  bool _active = true;
  int _tick = 0;

  @override
  bool get isActive => _active;

  @override
  int get tick => _tick;

  @override
  void cancel() => _active = false;

  void fire() {
    if (!_active) return;
    _active = false;
    _tick += 1;
    callback();
  }
}

void main() {
  setUpAll(() => initializeDateFormatting('pt_BR'));

  for (final (hour, minute, greeting) in [
    (0, 0, 'Boa noite'),
    (4, 59, 'Boa noite'),
    (5, 0, 'Bom dia'),
    (11, 59, 'Bom dia'),
    (12, 0, 'Boa tarde'),
    (17, 59, 'Boa tarde'),
    (18, 0, 'Boa noite'),
    (23, 59, 'Boa noite'),
    (2, 30, 'Boa noite'),
    (8, 30, 'Bom dia'),
    (15, 30, 'Boa tarde'),
    (21, 30, 'Boa noite'),
  ]) {
    test('local greeting at $hour:$minute is $greeting', () {
      expect(homeGreetingFor(DateTime(2026, 8, 21, hour, minute)), greeting);
    });
  }

  for (final (now, expected) in [
    (DateTime(2026, 8, 21, 4, 59), DateTime(2026, 8, 21, 5)),
    (DateTime(2026, 8, 21, 5, 1), DateTime(2026, 8, 21, 12)),
    (DateTime(2026, 8, 21, 11, 59), DateTime(2026, 8, 21, 12)),
    (DateTime(2026, 8, 21, 12, 1), DateTime(2026, 8, 21, 18)),
    (DateTime(2026, 8, 21, 17, 59), DateTime(2026, 8, 21, 18)),
    (DateTime(2026, 8, 21, 18, 1), DateTime(2026, 8, 22)),
    (DateTime(2026, 8, 21, 23, 59), DateTime(2026, 8, 22)),
    (DateTime(2026, 8, 21, 0, 1), DateTime(2026, 8, 21, 5)),
    (DateTime(2026, 8, 31, 23, 59), DateTime(2026, 9, 1)),
    (DateTime(2026, 12, 31, 23, 59), DateTime(2027)),
    (DateTime(2026, 8, 21), DateTime(2026, 8, 21, 5)),
    (DateTime(2026, 8, 21, 5), DateTime(2026, 8, 21, 12)),
    (DateTime(2026, 8, 21, 12), DateTime(2026, 8, 21, 18)),
    (DateTime(2026, 8, 21, 18), DateTime(2026, 8, 22)),
  ]) {
    test('next local Home boundary after $now is $expected', () {
      final boundary = nextHomeTimeBoundary(now);
      expect(boundary, expected);
      expect(boundary.isUtc, isFalse);
      expect(boundary.isAfter(now), isTrue);
    });
  }

  for (final (name, start, end, before, after) in [
    (
      '05:00',
      DateTime(2026, 8, 21, 4, 59),
      DateTime(2026, 8, 21, 5),
      'Boa noite',
      'Bom dia',
    ),
    (
      '12:00',
      DateTime(2026, 8, 21, 11, 59),
      DateTime(2026, 8, 21, 12),
      'Bom dia',
      'Boa tarde',
    ),
    (
      '18:00',
      DateTime(2026, 8, 21, 17, 59),
      DateTime(2026, 8, 21, 18),
      'Boa tarde',
      'Boa noite',
    ),
    (
      'late callback at 20:00',
      DateTime(2026, 8, 21, 17, 30),
      DateTime(2026, 8, 21, 20),
      'Boa tarde',
      'Boa noite',
    ),
  ]) {
    testWidgets('mounted Home refreshes at $name without provider emissions', (
      tester,
    ) async {
      var now = start;
      final timers = <_BoundaryTimer>[];
      await tester.pumpWidget(
        _homeApp(
          displayName: 'Rafael Lacerda',
          now: () => now,
          scheduleBoundary: (delay, callback) {
            final timer = _BoundaryTimer(delay, callback);
            timers.add(timer);
            return timer;
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('$before, Rafael'), findsOneWidget);
      expect(
        timers.single.delay,
        nextHomeTimeBoundary(start).difference(start),
      );

      now = end;
      timers.single.fire();
      await tester.pumpAndSettle();
      expect(find.text('$after, Rafael'), findsOneWidget);
      expect(find.textContaining('Rafael Lacerda'), findsNothing);
      expect(timers.first.isActive, isFalse);
      expect(timers.last.delay, nextHomeTimeBoundary(end).difference(end));
      expect(timers.where((timer) => timer.isActive), hasLength(1));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'mounted Home changes date at midnight without provider emissions',
    (tester) async {
      var now = DateTime(2026, 8, 21, 23, 59);
      final timers = <_BoundaryTimer>[];
      await tester.pumpWidget(
        _homeApp(
          displayName: 'Rafael Lacerda',
          now: () => now,
          scheduleBoundary: (delay, callback) {
            final timer = _BoundaryTimer(delay, callback);
            timers.add(timer);
            return timer;
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('21/08/2026'), findsOneWidget);
      expect(find.text('Boa noite, Rafael'), findsOneWidget);

      now = DateTime(2026, 8, 22);
      timers.single.fire();
      await tester.pumpAndSettle();
      expect(find.textContaining('21/08/2026'), findsNothing);
      expect(find.textContaining('22/08/2026'), findsOneWidget);
      expect(find.text('Boa noite, Rafael'), findsOneWidget);
      expect(timers.last.delay, const Duration(hours: 5));
      expect(timers.where((timer) => timer.isActive), hasLength(1));
    },
  );

  for (final (start, end, before, after) in [
    (
      DateTime(2026, 8, 21, 17, 30),
      DateTime(2026, 8, 21, 20),
      'Boa tarde',
      'Boa noite',
    ),
    (
      DateTime(2026, 8, 21, 23, 50),
      DateTime(2026, 8, 22, 0, 10),
      'Boa noite',
      'Boa noite',
    ),
    (
      DateTime(2026, 8, 21, 17, 30),
      DateTime(2026, 8, 21, 8, 30),
      'Boa tarde',
      'Bom dia',
    ),
  ]) {
    testWidgets('resume refreshes local clock from $start to $end', (
      tester,
    ) async {
      var now = start;
      final timers = <_BoundaryTimer>[];
      await tester.pumpWidget(
        _homeApp(
          displayName: 'Rafael Lacerda',
          now: () => now,
          scheduleBoundary: (delay, callback) {
            final timer = _BoundaryTimer(delay, callback);
            timers.add(timer);
            return timer;
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('$before, Rafael'), findsOneWidget);
      final previousTimer = timers.single;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      now = end;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('$after, Rafael'), findsOneWidget);
      expect(
        find.textContaining('${end.day.toString().padLeft(2, '0')}/08/2026'),
        findsOneWidget,
      );
      expect(previousTimer.isActive, isFalse);
      expect(timers.last.delay, nextHomeTimeBoundary(end).difference(end));
      expect(timers.where((timer) => timer.isActive), hasLength(1));
      previousTimer.fire();
      expect(timers, hasLength(2));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('new Home at 20:00 already greets Boa noite', (tester) async {
    await tester.pumpWidget(
      _homeApp(
        displayName: 'Rafael Lacerda',
        now: () => DateTime(2026, 8, 21, 20),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Boa noite, Rafael'), findsOneWidget);
  });

  testWidgets('dispose cancels timer and removes lifecycle observer', (
    tester,
  ) async {
    final timers = <_BoundaryTimer>[];
    await tester.pumpWidget(
      _homeApp(
        now: () => DateTime(2026, 8, 21, 10),
        scheduleBoundary: (delay, callback) {
          final timer = _BoundaryTimer(delay, callback);
          timers.add(timer);
          return timer;
        },
      ),
    );
    await tester.pumpAndSettle();
    final previousTimer = timers.single;
    await tester.pumpWidget(const SizedBox.shrink());
    expect(previousTimer.isActive, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    previousTimer.callback();
    await tester.pump();
    expect(timers, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('ready usa a hierarquia refinada sem tendências inventadas', (
    tester,
  ) async {
    await tester.pumpWidget(_homeApp());
    await tester.pumpAndSettle();

    for (final label in [
      'Pontuação geral',
      'Produtividade',
      'Saúde',
      'Financeiro',
      'Planejar meu dia',
      'Resumo rápido',
      'Hábitos',
      'Revisões',
      'Medicamentos',
      'Saldo',
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    for (final trend in ['+12%', '+8%', '+5%']) {
      expect(find.text(trend), findsNothing);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('score ausente permanece representado por travessão', (
    tester,
  ) async {
    await tester.pumpWidget(_homeApp(hasData: false));
    await tester.pumpAndSettle();

    expect(find.text('Pontuação geral'), findsOneWidget);
    final score = tester.widget<Text>(
      find.byKey(const Key('home-overall-score-value')),
    );
    expect(score.data, '—');
    expect(tester.takeException(), isNull);
  });

  testWidgets('saudação exibe somente o primeiro nome', (tester) async {
    await tester.pumpWidget(_homeApp(displayName: 'Rafael Lacerda'));
    await tester.pumpAndSettle();

    expect(find.textContaining(', Rafael'), findsOneWidget);
    expect(find.textContaining('Rafael Lacerda'), findsNothing);
  });

  for (final counts in [
    (
      reviewQueue: 1,
      medicationCount: 1,
      reviewText: '1 pendente',
      medicationText: '1 ativo',
      reviewDetail: 'pendente',
      medicationDetail: 'ativo',
    ),
    (
      reviewQueue: 2,
      medicationCount: 2,
      reviewText: '2 pendentes',
      medicationText: '2 ativos',
      reviewDetail: 'pendentes',
      medicationDetail: 'ativos',
    ),
  ]) {
    testWidgets('pluraliza ${counts.reviewQueue} revisão e '
        '${counts.medicationCount} medicamento', (tester) async {
      await tester.pumpWidget(
        _homeApp(
          reviewQueue: counts.reviewQueue,
          medicationCount: counts.medicationCount,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text(counts.reviewDetail), findsOneWidget);
      expect(find.text(counts.medicationDetail), findsOneWidget);

      final plannerButton = find.text('Planejar meu dia');
      await tester.ensureVisible(plannerButton);
      await tester.tap(plannerButton);
      await tester.pumpAndSettle();

      expect(find.text(counts.reviewText), findsOneWidget);
      expect(find.text(counts.medicationText), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('planner mostra dados reais e ações locais', (tester) async {
    await tester.pumpWidget(_homeApp());
    await tester.pumpAndSettle();

    final plannerButton = find.text('Planejar meu dia');
    await tester.ensureVisible(plannerButton);
    await tester.tap(plannerButton);
    await tester.pumpAndSettle();

    expect(find.text('Planejar meu dia'), findsNWidgets(2));
    expect(
      find.text('Organize seu próximo passo com o que já está no Life OS.'),
      findsOneWidget,
    );
    expect(find.text('3/5 concluídos'), findsOneWidget);
    expect(find.text('4 pendentes'), findsOneWidget);
    expect(find.text('2 ativos'), findsOneWidget);
    expect(find.text('R\$\u00a01.234,56'), findsNWidgets(2));
    expect(find.text('Iniciar foco'), findsOneWidget);
    expect(find.text('Ver tarefas'), findsOneWidget);
    expect(find.text('Ver estudos'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
