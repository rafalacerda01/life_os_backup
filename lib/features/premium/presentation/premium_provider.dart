import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../domain/entities/premium_status_entity.dart';
import '../domain/repositories/i_premium_repository.dart';
import '../data/repositories/mock_premium_repository.dart';

// Injeção de dependência do Repositório
final premiumRepositoryProvider = Provider<IPremiumRepository>((ref) {
  return MockPremiumRepository(); // No futuro, troque para RevenueCatPremiumRepository()
});

class PremiumNotifier extends Notifier<PremiumStatusEntity> {
  StreamSubscription? _subscription;

  @override
  PremiumStatusEntity build() {
    ref.onDispose(() => _subscription?.cancel());

    final repository = ref.watch(premiumRepositoryProvider);

    // Ouve o repositório e atualiza o estado automaticamente
    _subscription = repository.watchPremiumStatus().listen((status) {
      state = status;
    });

    return const PremiumStatusEntity(
      isPremium: false,
      tier: PremiumTier.free,
      activatedFeatures: ["Tarefas Básicas"],
    );
  }

  Future<void> restorePurchase() async {
    await ref.read(premiumRepositoryProvider).restorePurchases();
  }

  Future<bool> processSecureCheckout(PremiumTier tier) async {
    return await ref.read(premiumRepositoryProvider).purchasePlan(tier);
  }
}

final premiumProvider = NotifierProvider<PremiumNotifier, PremiumStatusEntity>(
  PremiumNotifier.new,
);
