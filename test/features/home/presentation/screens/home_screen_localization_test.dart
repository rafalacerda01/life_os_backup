import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:life_os/features/auth/domain/entities/user_entity.dart';
import 'package:life_os/features/auth/presentation/providers/auth_provider.dart';
import 'package:life_os/features/auth/presentation/providers/auth_state.dart';
import 'package:life_os/features/dashboard/data/models/dashboard_model.dart';
import 'package:life_os/features/dashboard/domain/entities/models/insight_model.dart';
import 'package:life_os/features/finance/presentation/providers/finance_provider.dart';
import 'package:life_os/features/home/presentation/providers/home_provider.dart';
import 'package:life_os/features/home/presentation/providers/insight_provider.dart';
import 'package:life_os/features/home/presentation/screens/home_screen.dart';
import 'package:life_os/features/notifications/domain/providers/notification_engine.dart';

class _StaticAuthNotifier extends AuthNotifier {
  @override
  AuthState build() => AuthState.authenticated(
    const UserEntity(
      uid: 'user-a',
      email: 'user@example.test',
      displayName: 'Usuário',
      isPremium: true,
      xp: 0,
      level: 1,
      streak: 0,
    ),
  );
}

void main() {
  setUpAll(() => initializeDateFormatting('pt_BR'));

  for (final sample in [
    (value: 1234.56, expected: 'R\$\u00a01.234,56'),
    (value: 0.0, expected: 'R\$\u00a00,00'),
    (value: 10.5, expected: 'R\$\u00a010,50'),
  ]) {
    testWidgets('Home formats ${sample.value} as BRL with English Intl', (
      tester,
    ) async {
      final platform = tester.binding.platformDispatcher;
      platform.localesTestValue = const [Locale('en', 'US')];
      addTearDown(platform.clearLocalesTestValue);

      await Intl.withLocale('en_US', () async {
        final dashboard = DashboardModel(
          productivityScore: 80,
          healthScore: 90,
          financialScore: 70,
          studyStreak: 0,
          studyReviewQueue: 0,
          studyProgress: 0,
          activeMedications: 0,
          transactionsCount: 1,
          financeBalance: sample.value,
        );
        final originalData = dashboard.toJson();

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              homeStateProvider.overrideWithValue(
                HomeStateData(
                  dashboard: dashboard,
                  completedHabitsToday: 0,
                  totalHabits: 0,
                  nextExam: null,
                  medicationCount: 0,
                ),
              ),
              authNotifierProvider.overrideWith(_StaticAuthNotifier.new),
              financeStreamProvider.overrideWith((ref) => Stream.value([])),
              unreadNotificationsCountProvider.overrideWith((ref) => 0),
              currentInsightProvider.overrideWithValue(
                const InsightModel(
                  id: 'test-insight',
                  title: 'Resumo',
                  message: 'Continue acompanhando sua rotina.',
                  category: InsightCategory.balance,
                  priority: InsightPriority.low,
                ),
              ),
            ],
            child: const MaterialApp(home: Scaffold(body: HomeScreen())),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Revisões'), findsOneWidget);
        expect(find.text('Pontuação geral'), findsOneWidget);
        expect(find.text('PREMIUM'), findsOneWidget);
        expect(find.text('PRO'), findsNothing);
        expect(find.textContaining('Streak:'), findsNothing);
        expect(find.text('Score geral do dia'), findsNothing);
        expect(
          find.byWidgetPredicate(
            (widget) =>
                widget is Semantics &&
                widget.properties.label ==
                    'Sugestão do dia: Resumo. Continue acompanhando sua rotina.',
          ),
          findsOneWidget,
        );

        expect(platform.locale, const Locale('en', 'US'));
        expect(Intl.getCurrentLocale(), 'en_US');
        expect(NumberFormat('0.00').format(1234.56), '1234.56');

        final balanceCard = find.byKey(const Key('home-summary-balance'));
        await tester.ensureVisible(balanceCard);
        await tester.pumpAndSettle();

        // Intl's BRL pattern uses a non-breaking space after the symbol.
        expect(
          find.descendant(
            of: balanceCard,
            matching: find.text(sample.expected),
          ),
          findsOneWidget,
        );
        expect(dashboard.financeBalance, sample.value);
        expect(dashboard.toJson(), originalData);
        expect(tester.takeException(), isNull);
      });
    });
  }
}
