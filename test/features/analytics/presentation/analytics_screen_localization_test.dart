import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
