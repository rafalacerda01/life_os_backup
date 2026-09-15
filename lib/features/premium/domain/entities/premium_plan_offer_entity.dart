import 'package:equatable/equatable.dart';

import 'premium_status_entity.dart';

class PremiumPlanOfferEntity extends Equatable {
  const PremiumPlanOfferEntity({
    required this.tier,
    required this.productId,
    required this.basePlanId,
    required this.formattedPrice,
    required this.rawPrice,
    required this.currencyCode,
  });

  final PremiumTier tier;
  final String productId;
  final String basePlanId;
  final String formattedPrice;
  final double rawPrice;
  final String currencyCode;

  @override
  List<Object?> get props => [
    tier,
    productId,
    basePlanId,
    formattedPrice,
    rawPrice,
    currencyCode,
  ];
}
