import '../entities/premium_status_entity.dart';

enum PremiumFeature { aiCompanion, analyticsAdvanced }

class FeatureGate {
  const FeatureGate();

  bool canAccess({
    required PremiumStatusEntity status,
    required PremiumFeature feature,
  }) {
    if (!status.isPremium) {
      return false;
    }

    switch (feature) {
      case PremiumFeature.aiCompanion:
        return true;

      case PremiumFeature.analyticsAdvanced:
        return true;
    }
  }
}
