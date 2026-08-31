import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/features/ai_companion/presentation/ai_companion_screen.dart';
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

class _ConsentTestNotifier extends AiConsentNotifier {
  @override
  Future<bool> build() async => true;

  @override
  Future<void> revokeConsent() async {
    state = const AsyncData(false);
  }
}

void main() {
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

  testWidgets('consentimento descreve somente dados usados atualmente', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: AiConsentView()));

    expect(find.textContaining('humor, hidratação'), findsOneWidget);
    expect(
      find.textContaining('nomes de medicamentos registrados'),
      findsOneWidget,
    );
    expect(find.textContaining('resumo financeiro'), findsOneWidget);
    expect(find.textContaining('ciclo menstrual'), findsOneWidget);
    expect(find.textContaining('foco'), findsNothing);
    expect(find.textContaining('metas'), findsNothing);
    expect(find.textContaining('hábitos'), findsNothing);
    expect(find.textContaining('dados selecionados nesta tela'), findsNothing);
  });

  testWidgets('UI volta para AiConsentView após revogação', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          premiumProvider.overrideWith(_PremiumTestNotifier.new),
          aiCompanionProvider.overrideWith(_AiCompanionTestNotifier.new),
          aiConsentProvider.overrideWith(_ConsentTestNotifier.new),
        ],
        child: const MaterialApp(home: AICompanionScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Assistente de IA do Life OS'), findsOneWidget);
    expect(find.text('Online • Core 3.5 Flash'), findsNothing);
    expect(find.text('Converse com o Companion IA...'), findsOneWidget);
    expect(find.text('Fale com o Core do sistema...'), findsNothing);
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
