import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/entities/premium_status_entity.dart';
import '../domain/services/plan_limits.dart';
import 'premium_provider.dart';

final planLimitsProvider = Provider<PlanLimits>((ref) {
  final premiumStatus = ref.watch(premiumProvider);

  return PlanLimits.fromTier(premiumStatus.tier);
});
