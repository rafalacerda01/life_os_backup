import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/core/services/emulator_account_runtime.dart';

import '../domain/entities/premium_status_entity.dart';
import '../domain/services/plan_limits.dart';
import 'premium_provider.dart';

final planLimitsProvider = Provider<PlanLimits>((ref) {
  if (ref.watch(emulatorAccountRuntimeProvider) != null) return PlanLimits.free;
  final premiumStatus = ref.watch(premiumProvider);

  return PlanLimits.fromTier(premiumStatus.tier);
});
