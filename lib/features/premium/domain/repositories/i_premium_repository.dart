import '../entities/premium_status_entity.dart';

abstract class IPremiumRepository {
  Stream<PremiumStatusEntity> watchPremiumStatus();
  Future<bool> purchasePlan(PremiumTier tier);
  Future<bool> restorePurchases();
}
