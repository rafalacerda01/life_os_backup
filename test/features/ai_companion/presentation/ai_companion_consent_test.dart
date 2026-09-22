import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/features/ai_companion/presentation/ai_companion_screen.dart';
import 'package:life_os/features/ai_companion/presentation/ai_companion_hub.dart';
import 'package:life_os/features/ai_companion/data/models/ai_insight.dart';
import 'package:life_os/features/ai_companion/presentation/providers/ai_companion_provider.dart';
import 'package:life_os/features/ai_companion/presentation/providers/ai_consent_provider.dart';
import 'package:life_os/features/ai_companion/presentation/screens/ai_consent_view.dart';
import 'package:life_os/features/premium/domain/entities/premium_status_entity.dart';
import 'package:life_os/features/premium/presentation/premium_provider.dart';

class _PremiumTestNotifier extends PremiumNotifier {
  @override
  PremiumStatusEntity build() => const PremiumStatusEntity(
    isPremium: true,
    tier: PremiumTier.monthly,
    activatedFeatures: ['AI Companion'],
  );
}

class _FreePremiumTestNotifier extends PremiumNotifier {
  @override
  PremiumStatusEntity build() => const PremiumStatusEntity(
    isPremium: false,
    tier: PremiumTier.free,
    activatedFeatures: [],
  );
}

class _AiCompanionTestNotifier extends AICompanionNotifier {
  @override
  AICompanionState build() =>
      AICompanionState(messages: const [], isLoading: false);
}

class _RecordingInsightNotifier extends _AiCompanionTestNotifier {
  final calls = <AIInsightIntent>[];

  @override
  Future<void> requestInsight(
    AIInsightIntent intent, {
    required String expectedUserId,
  }) async {
    expect(expectedUserId, 'user-a');
    calls.add(intent);
  }
}

class _ConsentTestNotifier extends AiConsentNotifier {
  @override
  Future<bool> build() async => true;

  @override
  Future<void> revokeConsent() async {
    state = const AsyncData(false);
  }
}

class _AcceptingConsentTestNotifier extends AiConsentNotifier {
  @override
  Future<bool> build() async => false;

  @override
  Future<void> acceptConsent() async {
    state = const AsyncData(true);
  }
}

void main() {
  const summary = AICompanionLocalSummary(
    pendingTasks: 3,
    completedHabitsToday: 1,
    activeHabits: 2,
    focusMinutesToday: 25,
    energy: 4,
  );

  testWidgets('hub shows local metrics and exactly three typed actions', (
    tester,
  ) async {
    final calls = <AIInsightIntent>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AICompanionHub(
            state: AICompanionState(),
            localSummary: const AsyncData(summary),
            onIntent: calls.add,
            onRevoke: () {},
          ),
        ),
      ),
    );
    expect(find.text('Seu sistema hoje'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('1/2'), findsOneWidget);
    expect(find.text('25 min'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(
      find.byKey(const ValueKey('insight-daily_overview')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('insight-weekly_overview')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('insight-finance_month_summary')),
      findsOneWidget,
    );
    for (final intent in AIInsightIntent.values) {
      await tester.ensureVisible(
        find.byKey(ValueKey('insight-${intent.wireValue}')),
      );
      await tester.tap(find.byKey(ValueKey('insight-${intent.wireValue}')));
      await tester.pump();
    }
    expect(calls, AIInsightIntent.values);
  });

  testWidgets(
    'hub loading disables actions, success and error remain sanitized',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final calls = <AIInsightIntent>[];
      Future<void> show(AICompanionState state) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AICompanionHub(
              state: state,
              localSummary: const AsyncData(summary),
              onIntent: calls.add,
              onRevoke: () {},
            ),
          ),
        ),
      );
      await show(AICompanionState(isLoading: true));
      await tester.tap(find.byKey(const ValueKey('insight-daily_overview')));
      expect(calls, isEmpty);
      expect(find.text('Preparando sua análise...'), findsOneWidget);
      await show(
        AICompanionState(
          insight: const AIInsight(
            headline: 'Headline',
            summary: 'Summary',
            recommendation: 'Recommendation',
          ),
        ),
      );
      await tester.ensureVisible(find.text('Headline'));
      expect(find.text('Summary'), findsOneWidget);
      expect(find.text('Recommendation'), findsOneWidget);
      await show(
        AICompanionState(
          lastIntent: AIInsightIntent.weeklyOverview,
          sanitizedError: 'Não foi possível conectar.',
        ),
      );
      await tester.ensureVisible(find.text('Tentar novamente'));
      await tester.tap(find.text('Tentar novamente'));
      expect(calls, [AIInsightIntent.weeklyOverview]);
    },
  );

  testWidgets('Analytics initial weekly intent runs once after consent', (
    tester,
  ) async {
    final notifier = _RecordingInsightNotifier();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          premiumProvider.overrideWith(_PremiumTestNotifier.new),
          aiCompanionProvider.overrideWith(() => notifier),
          aiConsentProvider.overrideWith(_ConsentTestNotifier.new),
          aiCompanionCurrentUserIdProvider.overrideWithValue(() => 'user-a'),
          aiCompanionLocalSummaryProvider.overrideWith(
            (ref, uid) async => summary,
          ),
        ],
        child: const MaterialApp(
          home: AICompanionScreen(
            initialIntent: AIInsightIntent.weeklyOverview,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(notifier.calls, [AIInsightIntent.weeklyOverview]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          premiumProvider.overrideWith(_PremiumTestNotifier.new),
          aiCompanionProvider.overrideWith(() => notifier),
          aiConsentProvider.overrideWith(_ConsentTestNotifier.new),
          aiCompanionCurrentUserIdProvider.overrideWithValue(() => 'user-a'),
          aiCompanionLocalSummaryProvider.overrideWith(
            (ref, uid) async => summary,
          ),
        ],
        child: const MaterialApp(
          home: AICompanionScreen(
            initialIntent: AIInsightIntent.weeklyOverview,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(notifier.calls, [AIInsightIntent.weeklyOverview]);
  });

  testWidgets('weekly initial intent waits for explicit V2 consent', (
    tester,
  ) async {
    final notifier = _RecordingInsightNotifier();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          premiumProvider.overrideWith(_PremiumTestNotifier.new),
          aiCompanionProvider.overrideWith(() => notifier),
          aiConsentProvider.overrideWith(_AcceptingConsentTestNotifier.new),
          aiCompanionCurrentUserIdProvider.overrideWithValue(() => 'user-a'),
          aiCompanionLocalSummaryProvider.overrideWith(
            (ref, uid) async => summary,
          ),
        ],
        child: const MaterialApp(
          home: AICompanionScreen(
            initialIntent: AIInsightIntent.weeklyOverview,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AiConsentView), findsOneWidget);
    expect(notifier.calls, isEmpty);
    await tester.ensureVisible(find.text('Permitir acesso aos meus dados'));
    await tester.tap(find.text('Permitir acesso aos meus dados'));
    await tester.pumpAndSettle();
    expect(notifier.calls, [AIInsightIntent.weeklyOverview]);
    await tester.pump();
    expect(notifier.calls, hasLength(1));
  });

  testWidgets('bloqueio Premium usa nomenclatura oficial', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [premiumProvider.overrideWith(_FreePremiumTestNotifier.new)],
        child: const MaterialApp(home: AICompanionScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Desbloquear com Premium'), findsOneWidget);
    expect(find.text('Desbloquear com Plano PRO'), findsNothing);
  });

  testWidgets('consentimento V2 descreve agregados e ação explícita', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: AiConsentView()));

    expect(find.textContaining('A geração requer conexão'), findsOneWidget);
    expect(
      find.textContaining('Nesta versão são enviados agregados'),
      findsOneWidget,
    );
    expect(
      find.textContaining('nenhuma análise é feita sem uma ação'),
      findsOneWidget,
    );
    expect(find.textContaining('nomes de medicamentos.'), findsOneWidget);
  });

  testWidgets('UI volta para AiConsentView após revogação', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          premiumProvider.overrideWith(_PremiumTestNotifier.new),
          aiCompanionProvider.overrideWith(_AiCompanionTestNotifier.new),
          aiConsentProvider.overrideWith(_ConsentTestNotifier.new),
          aiCompanionCurrentUserIdProvider.overrideWithValue(() => 'user-a'),
          aiCompanionLocalSummaryProvider.overrideWith(
            (ref, uid) async => summary,
          ),
        ],
        child: const MaterialApp(home: AICompanionScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Companion IA'), findsOneWidget);
    expect(find.text('Seu sistema hoje'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.byKey(const ValueKey('revoke-ai-consent')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('revoke-ai-consent')));
    await tester.pumpAndSettle();
    expect(find.text('Revogar consentimento da IA?'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('confirm-revoke-ai-consent')));
    await tester.pumpAndSettle();

    expect(find.text('Permitir acesso aos meus dados'), findsOneWidget);
    expect(find.byKey(const ValueKey('revoke-ai-consent')), findsNothing);
  });
}
