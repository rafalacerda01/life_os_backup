import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:life_os/features/analytics/domain/entities/analytics_entity.dart';
import 'package:life_os/features/analytics/presentation/analytics_provider.dart';
import 'package:life_os/features/analytics/presentation/analytics_screen.dart';
import 'package:life_os/features/premium/domain/entities/premium_status_entity.dart';
import 'package:life_os/features/premium/presentation/premium_provider.dart';

class _FreePremiumNotifier extends PremiumNotifier {
  @override
  PremiumStatusEntity build() => const PremiumStatusEntity(
    isPremium: false,
    tier: PremiumTier.free,
    activatedFeatures: [],
  );
}

class _PremiumTestNotifier extends PremiumNotifier {
  @override
  PremiumStatusEntity build() => const PremiumStatusEntity(
    isPremium: true,
    tier: PremiumTier.monthly,
    activatedFeatures: ['AI Companion', 'Analytics Avançado'],
  );
}

void main() {
  const emptyAnalytics = AnalyticsEntity(
    productivityIndex: 0,
    healthIndex: 0,
    financeIndex: 0,
    habitConsistency: 0,
    weeklyEvolution: [],
  );
  const weeklyEvolution = [
    DailyPerformance(dayName: 'Seg', scorePercentage: 1.0),
    DailyPerformance(dayName: 'Ter', scorePercentage: 0.0),
    DailyPerformance(dayName: 'Qua', scorePercentage: 0.25),
    DailyPerformance(dayName: 'Qui', scorePercentage: 0.5),
    DailyPerformance(dayName: 'Sex', scorePercentage: 0.75),
    DailyPerformance(dayName: 'Sáb', scorePercentage: 0.0),
    DailyPerformance(dayName: 'Dom', scorePercentage: 1.0),
  ];
  final weeklyBars = find.byWidgetPredicate((widget) {
    if (widget is! Container) return false;
    final decoration = widget.decoration;
    return widget.constraints?.maxWidth == 14 &&
        decoration is BoxDecoration &&
        decoration.gradient is LinearGradient;
  });

  testWidgets(
    'Premium without habits shows an empty state without weekly bars',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            analyticsProvider.overrideWithValue(emptyAnalytics),
            premiumProvider.overrideWith(_PremiumTestNotifier.new),
          ],
          child: const MaterialApp(home: AnalyticsScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Sem dados de hábitos nesta semana.'), findsOneWidget);
      expect(find.text('Consistência Geral da Semana'), findsOneWidget);
      expect(weeklyBars, findsNothing);
      for (final day in weeklyEvolution) {
        expect(find.text(day.dayName), findsNothing);
      }
      expect(find.text('Gráfico Semanal Premium'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Premium with data preserves weekly bars and labels', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          analyticsProvider.overrideWithValue(
            const AnalyticsEntity(
              productivityIndex: 0,
              healthIndex: 0,
              financeIndex: 0,
              habitConsistency: 0,
              weeklyEvolution: weeklyEvolution,
            ),
          ),
          premiumProvider.overrideWith(_PremiumTestNotifier.new),
        ],
        child: const MaterialApp(home: AnalyticsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(weeklyBars, findsNWidgets(7));
    final bars = tester.widgetList<Container>(weeklyBars).toList();
    for (var i = 0; i < weeklyEvolution.length; i++) {
      expect(find.text(weeklyEvolution[i].dayName), findsOneWidget);
      expect(
        bars[i].constraints?.maxHeight,
        110 * weeklyEvolution[i].scorePercentage,
      );
      expect(
        ((bars[i].decoration! as BoxDecoration).gradient! as LinearGradient)
            .colors,
        const [Color(0xFF5D0EFF), Color(0xFFB026FF)],
      );
    }
    expect(find.text('Sem dados de hábitos nesta semana.'), findsNothing);
    expect(find.text('Gráfico Semanal Premium'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Free keeps its weekly Premium overlay instead of the empty state',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            analyticsProvider.overrideWithValue(emptyAnalytics),
            premiumProvider.overrideWith(_FreePremiumNotifier.new),
          ],
          child: const MaterialApp(home: AnalyticsScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Gráfico Semanal Premium'), findsOneWidget);
      expect(find.text('Sem dados de hábitos nesta semana.'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Analytics CTA navigates to typed weekly V2 intent', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: '/analytics',
      routes: [
        GoRoute(path: '/analytics', builder: (_, _) => const AnalyticsScreen()),
        GoRoute(
          path: '/ai-companion',
          builder: (_, state) => Scaffold(
            body: Text('intent=${state.uri.queryParameters['intent']}'),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          analyticsProvider.overrideWithValue(
            const AnalyticsEntity(
              productivityIndex: 0,
              healthIndex: 0,
              financeIndex: 0,
              habitConsistency: 0,
              weeklyEvolution: [],
            ),
          ),
          premiumProvider.overrideWith(_PremiumTestNotifier.new),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    final action = find.text('Analisar meus dados com a IA');
    await tester.ensureVisible(action);
    await tester.tap(action);
    await tester.pumpAndSettle();
    expect(find.text('intent=weekly_overview'), findsOneWidget);
  });

  testWidgets('Analytics uses decimal commas without rescaling percentages', (
    tester,
  ) async {
    final platform = tester.binding.platformDispatcher;
    platform.localesTestValue = const [Locale('en', 'US')];
    addTearDown(platform.clearLocalesTestValue);

    await Intl.withLocale('en_US', () async {
      const analytics = AnalyticsEntity(
        productivityIndex: 87.5,
        healthIndex: 0,
        financeIndex: 10.5,
        habitConsistency: 100,
        weeklyEvolution: [],
      );
      final originalValues = List<Object?>.of(analytics.props);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            analyticsProvider.overrideWithValue(analytics),
            premiumProvider.overrideWith(_FreePremiumNotifier.new),
          ],
          child: const MaterialApp(home: AnalyticsScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(platform.locale, const Locale('en', 'US'));
      expect(Intl.getCurrentLocale(), 'en_US');
      expect(NumberFormat('0.0').format(87.5), '87.5');

      for (final label in ['87,5%', '0,0%', '10,5%', '100,0%']) {
        final text = find.text(label);
        expect(text, findsOneWidget);
        await tester.ensureVisible(text);
        await tester.pumpAndSettle();
      }
      expect(find.text('87.5%'), findsNothing);
      expect(find.text('8750,0%'), findsNothing);

      final progressValues = tester
          .widgetList<LinearProgressIndicator>(
            find.byType(LinearProgressIndicator),
          )
          .map((indicator) => indicator.value)
          .toList();
      expect(progressValues, [0.875, 0.0, 0.105, 1.0]);
      expect(analytics.props, originalValues);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('Analytics apresenta CTA da IA em pt-BR', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          analyticsProvider.overrideWithValue(
            const AnalyticsEntity(
              productivityIndex: 0,
              healthIndex: 0,
              financeIndex: 0,
              habitConsistency: 0,
              weeklyEvolution: [],
            ),
          ),
          premiumProvider.overrideWith(_PremiumTestNotifier.new),
        ],
        child: const MaterialApp(home: AnalyticsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    final cta = find.text('Analisar meus dados com a IA');
    await tester.ensureVisible(cta);
    await tester.pumpAndSettle();

    expect(cta, findsOneWidget);
    expect(find.text('Consultar AI Coach sobre Analytics'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
