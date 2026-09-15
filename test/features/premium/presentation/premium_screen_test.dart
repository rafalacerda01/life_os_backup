import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/features/premium/domain/entities/premium_plan_offer_entity.dart';
import 'package:life_os/features/premium/domain/entities/premium_status_entity.dart';
import 'package:life_os/features/premium/domain/repositories/i_premium_repository.dart';
import 'package:life_os/features/premium/presentation/premium_provider.dart';
import 'package:life_os/features/premium/presentation/premium_screen.dart';

void main() {
  testWidgets('shows Play prices and honest feature copy', (tester) async {
    final repository = _UiRepository();
    await _pump(tester, repository);

    expect(find.text('US\$ 2.99'), findsOneWidget);
    expect(find.text('US\$ 24.99'), findsOneWidget);
    expect(find.textContaining('R\$ 19,90'), findsNothing);
    expect(find.text('Companion IA'), findsOneWidget);
    expect(find.text('Premium: Disponível com limites de uso'), findsOneWidget);
    expect(find.textContaining('Ilimitad'), findsNothing);
  });

  testWidgets('restore waits for the awaitable result', (tester) async {
    final repository = _UiRepository();
    repository.restoreResult = Completer<bool>();
    await _pump(tester, repository);

    await tester.tap(find.text('Restaurar'));
    await tester.pump();
    expect(find.text('Restaurando compras...'), findsOneWidget);
    expect(find.textContaining('restaurada com segurança'), findsNothing);

    repository.restoreResult!.complete(true);
    await tester.pumpAndSettle();
    expect(find.text('Assinatura restaurada com segurança.'), findsOneWidget);
  });

  testWidgets('raw checkout exception is never exposed', (tester) async {
    final repository = _UiRepository()
      ..purchaseError = StateError('private-technical-error');
    await _pump(tester, repository);

    await tester.ensureVisible(find.text('Assinar plano mensal'));
    await tester.tap(find.text('Assinar plano mensal'));
    await tester.pumpAndSettle();
    expect(find.textContaining('private-technical-error'), findsNothing);
    expect(find.text('Não foi possível concluir a compra.'), findsOneWidget);
  });

  testWidgets('active monthly plan hides checkout and offers management', (
    tester,
  ) async {
    final repository = _UiRepository(
      status: PremiumStatusEntity(
        isPremium: true,
        tier: PremiumTier.monthly,
        expirationDate: DateTime(2099, 1, 2),
        activatedFeatures: const [],
      ),
    );
    await _pump(tester, repository);

    expect(find.textContaining('Plano Premium mensal'), findsOneWidget);
    expect(find.text('Assinar plano mensal'), findsNothing);
    expect(find.text('Gerenciar assinatura na Google Play'), findsOneWidget);
  });
}

Future<void> _pump(WidgetTester tester, _UiRepository repository) {
  return tester
      .pumpWidget(
        ProviderScope(
          overrides: [premiumRepositoryProvider.overrideWithValue(repository)],
          child: const MaterialApp(home: PremiumScreen()),
        ),
      )
      .then((_) => tester.pumpAndSettle());
}

class _UiRepository implements IPremiumRepository {
  _UiRepository({
    this.status = const PremiumStatusEntity(
      isPremium: false,
      tier: PremiumTier.free,
      activatedFeatures: [],
    ),
  });

  final PremiumStatusEntity status;
  Completer<bool>? restoreResult;
  Object? purchaseError;

  @override
  Future<List<PremiumPlanOfferEntity>> loadAvailablePlans() async => const [
    PremiumPlanOfferEntity(
      tier: PremiumTier.monthly,
      productId: 'life_os_premium',
      basePlanId: 'monthly',
      formattedPrice: 'US\$ 2.99',
      rawPrice: 2.99,
      currencyCode: 'USD',
    ),
    PremiumPlanOfferEntity(
      tier: PremiumTier.annual,
      productId: 'life_os_premium',
      basePlanId: 'annual',
      formattedPrice: 'US\$ 24.99',
      rawPrice: 24.99,
      currencyCode: 'USD',
    ),
  ];

  @override
  Future<bool> purchasePlan(PremiumTier tier) async {
    final error = purchaseError;
    if (error != null) throw error;
    return false;
  }

  @override
  Future<bool> restorePurchases() =>
      restoreResult?.future ?? Future.value(false);

  @override
  Stream<PremiumStatusEntity> watchPremiumStatus() => Stream.value(status);

  @override
  void dispose() {}
}
