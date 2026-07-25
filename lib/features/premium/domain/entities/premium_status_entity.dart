import 'package:equatable/equatable.dart';

enum PremiumTier { free, monthly, annual }

class PremiumStatusEntity extends Equatable {
  final bool isPremium;
  final PremiumTier tier;
  final DateTime? expirationDate;
  final List<String> activatedFeatures;

  const PremiumStatusEntity({
    required this.isPremium,
    required this.tier,
    this.expirationDate,
    required this.activatedFeatures,
  });

  @override
  List<Object?> get props => [
    isPremium,
    tier,
    expirationDate,
    activatedFeatures,
  ];
}
