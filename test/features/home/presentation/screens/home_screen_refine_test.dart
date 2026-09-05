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
    unreadNotificationsCountProvider.overrideWith((ref) => 0),
    currentInsightProvider.overrideWithValue(_insight),
  ],
  child: const MaterialApp(home: Scaffold(body: HomeScreen())),
);

void main() {
  setUpAll(() => initializeDateFormatting('pt_BR'));

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
