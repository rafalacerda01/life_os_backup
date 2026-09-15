import '../entities/premium_plan_offer_entity.dart';
import '../entities/premium_status_entity.dart';

abstract class IPremiumRepository {
  Stream<PremiumStatusEntity> watchPremiumStatus();
  Future<List<PremiumPlanOfferEntity>> loadAvailablePlans() async => const [];
  Future<bool> purchasePlan(PremiumTier tier);
  Future<bool> restorePurchases();

  void dispose() {}
}
