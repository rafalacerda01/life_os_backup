import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:life_os/core/database/app_database.dart' as local_db;
import 'package:life_os/features/auth/domain/entities/user_entity.dart';
import 'package:life_os/features/auth/presentation/providers/auth_provider.dart';
import 'package:life_os/features/auth/presentation/providers/auth_state.dart';
import 'package:life_os/features/dashboard/data/models/dashboard_model.dart';
import 'package:life_os/features/finance/presentation/providers/finance_provider.dart';
import 'package:life_os/features/habits/data/models/habit_model.dart';
import 'package:life_os/features/habits/presentation/providers/habits_provider.dart';
import 'package:life_os/features/health/data/models/health_model.dart';
import 'package:life_os/features/health/presentation/providers/health_provider.dart';
import 'package:life_os/features/home/presentation/providers/home_provider.dart';
import 'package:life_os/features/home/presentation/screens/home_screen.dart';
import 'package:life_os/features/dashboard/domain/entities/models/insight_model.dart';
import 'package:life_os/features/home/presentation/providers/insight_provider.dart';
import 'package:life_os/features/notifications/domain/providers/notification_engine.dart';
import 'package:life_os/features/premium/domain/entities/premium_status_entity.dart';
import 'package:life_os/features/premium/presentation/premium_provider.dart';
import 'package:life_os/features/study/data/models/study_model.dart';
import 'package:life_os/features/study/domain/entities/study_subject_entity.dart';
import 'package:life_os/features/study/presentation/providers/study_provider.dart';
import 'package:life_os/features/tasks/data/models/task_model.dart';
import 'package:life_os/features/tasks/presentation/providers/tasks_provider.dart';

class _StaticAuthNotifier extends AuthNotifier {
  _StaticAuthNotifier(this.isPremium);

  final bool isPremium;

  @override
  AuthState build() => AuthState.authenticated(
    UserEntity(
      uid: 'user-a',
      email: 'user@example.test',
      displayName: 'Usuário',
      isPremium: isPremium,
      xp: 0,
      level: 1,
      streak: 0,
    ),
  );
}

class _StaticPremiumNotifier extends PremiumNotifier {
  _StaticPremiumNotifier(this.isPremium);

  final bool isPremium;

  @override
  PremiumStatusEntity build() => isPremium
      ? PremiumStatusEntity(
          isPremium: true,
          tier: PremiumTier.monthly,
          expirationDate: DateTime.now().add(const Duration(days: 30)),
          activatedFeatures: const ['Companion IA'],
        )
      : const PremiumStatusEntity(
          isPremium: false,
          tier: PremiumTier.free,
          activatedFeatures: ['Recursos essenciais'],
        );
}

const _insight = InsightModel(
  id: 'home-premium-source-insight',
  title: 'Resumo',
  message: 'Continue acompanhando sua rotina.',
  category: InsightCategory.balance,
  priority: InsightPriority.low,
);

class _SourceBuildCounts {
  int finance = 0;
  int study = 0;
  int health = 0;
  int tasks = 0;
  int medications = 0;
  int habits = 0;
  int subjects = 0;

  List<int> get values => [
    finance,
    study,
    health,
    tasks,
    medications,
    habits,
    subjects,
  ];
}

const _dashboard = DashboardModel(
  productivityScore: 80,
  healthScore: 90,
  financialScore: 70,
  studyStreak: 0,
  studyReviewQueue: 0,
  studyProgress: 0,
  activeMedications: 0,
  transactionsCount: 0,
  financeBalance: 0,
);

HomeStateData _homeState(HomeLoadState loadState) => HomeStateData(
  dashboard: _dashboard,
  completedHabitsToday: 0,
  totalHabits: 0,
  nextExam: null,
  medicationCount: 0,
  loadState: loadState,
);

Widget _homeApp(
  HomeLoadState loadState, {
  bool authPremium = false,
  bool providerPremium = false,
}) => ProviderScope(
  overrides: [
    homeStateProvider.overrideWithValue(_homeState(loadState)),
    authNotifierProvider.overrideWith(() => _StaticAuthNotifier(authPremium)),
    premiumProvider.overrideWith(() => _StaticPremiumNotifier(providerPremium)),
    unreadNotificationsCountProvider.overrideWith((ref) => 0),
    currentInsightProvider.overrideWithValue(_insight),
  ],
  child: const MaterialApp(home: Scaffold(body: HomeScreen())),
);

void main() {
  setUpAll(() => initializeDateFormatting('pt_BR'));

  testWidgets('loading mostra skeleton sem conteúdo ready ou erro', (
    tester,
  ) async {
    await tester.pumpWidget(_homeApp(HomeLoadState.loading));
    await tester.pump();

    expect(find.byType(TweenAnimationBuilder<double>), findsWidgets);
    expect(find.text('Pontuação geral'), findsNothing);
    expect(find.text('Não foi possível carregar seus dados.'), findsNothing);
    expect(find.text('Tentar novamente'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unavailable oculta fallback e mostra retry controlado', (
    tester,
  ) async {
    await tester.pumpWidget(_homeApp(HomeLoadState.unavailable));
    await tester.pump();

    expect(find.text('Não foi possível carregar seus dados.'), findsOneWidget);
    expect(
      find.text('Verifique sua conexão e tente novamente.'),
      findsOneWidget,
    );
    expect(find.text('Tentar novamente'), findsOneWidget);
    expect(find.text('Pontuação geral'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('retry invalida exatamente as sete fontes necessárias', (
    tester,
  ) async {
    final counts = _SourceBuildCounts();
    final container = ProviderContainer(
      overrides: [
        homeStateProvider.overrideWithValue(
          _homeState(HomeLoadState.unavailable),
        ),
        authNotifierProvider.overrideWith(() => _StaticAuthNotifier(false)),
        premiumProvider.overrideWith(() => _StaticPremiumNotifier(false)),
        financeStreamProvider.overrideWith((ref) {
          counts.finance++;
          return const Stream<List<local_db.Transaction>>.empty();
        }),
        studyStreamProvider.overrideWith((ref) {
          counts.study++;
          return const Stream<StudyModel>.empty();
        }),
        healthStreamProvider.overrideWith((ref) {
          counts.health++;
          return const Stream<HealthModel>.empty();
        }),
        tasksStreamProvider.overrideWith((ref) {
          counts.tasks++;
          return const Stream<List<TaskModel>>.empty();
        }),
        medicationsStreamProvider.overrideWith((ref) {
          counts.medications++;
          return const Stream<List<local_db.Medication>>.empty();
        }),
        habitsStreamProvider.overrideWith((ref) {
          counts.habits++;
          return const Stream<List<HabitModel>>.empty();
        }),
        subjectsStreamProvider.overrideWith((ref) {
          counts.subjects++;
          return const Stream<List<StudySubjectEntity>>.empty();
        }),
      ],
    );
    final subscriptions = [
      container.listen(financeStreamProvider, (_, _) {}),
      container.listen(studyStreamProvider, (_, _) {}),
      container.listen(healthStreamProvider, (_, _) {}),
      container.listen(tasksStreamProvider, (_, _) {}),
      container.listen(medicationsStreamProvider, (_, _) {}),
      container.listen(habitsStreamProvider, (_, _) {}),
      container.listen(subjectsStreamProvider, (_, _) {}),
    ];
    addTearDown(() {
      for (final subscription in subscriptions) {
        subscription.close();
      }
      container.dispose();
    });
    await container.pump();

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: HomeScreen())),
      ),
    );
    await tester.pump();
    final initialCounts = List<int>.of(counts.values);

    await tester.tap(find.text('Tentar novamente'));
    await tester.pump();
    await container.pump();

    expect(initialCounts, everyElement(1));
    expect(counts.values, everyElement(2));
    expect(find.text('Tentar novamente'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Home uses Premium provider when Auth says Free', (tester) async {
    await tester.pumpWidget(
      _homeApp(HomeLoadState.ready, providerPremium: true),
    );
    await tester.pumpAndSettle();

    expect(find.text('PREMIUM'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Home ignores stale Premium flag in Auth', (tester) async {
    await tester.pumpWidget(_homeApp(HomeLoadState.ready, authPremium: true));
    await tester.pumpAndSettle();

    expect(find.text('PREMIUM'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
