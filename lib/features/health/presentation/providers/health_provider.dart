import 'dart:async';

import 'package:life_os/core/services/firebase_auth_provider.dart';
import 'package:life_os/core/database/local_account_session.dart';
import 'package:life_os/core/services/emulator_account_runtime.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:drift/drift.dart' as drift hide Column;
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/database_provider.dart';
import 'package:life_os/core/services/notification_service.dart';
import 'package:life_os/core/services/sync_manager_provider.dart';
import 'package:life_os/core/services/water_v2_provider.dart';
import 'package:life_os/features/health/data/models/health_model.dart';
import 'package:life_os/features/health/data/repositories/health_repository.dart';
import 'package:life_os/features/settings/presentation/providers/notification_provider.dart';

// ===========================================================================
// REPOSITORY
// ===========================================================================

final healthDayClockProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);

final healthDayTimerProvider =
    Provider<Timer Function(Duration, void Function())>((ref) => Timer.new);

DateTime nextHealthDayBoundary(DateTime now) {
  final localNow = now.toLocal();
  return DateTime(localNow.year, localNow.month, localNow.day + 1);
}

final healthRepositoryProvider = Provider<HealthRepository>((ref) {
  final db = ref.watch(databaseProvider);
  if (db.isLocalOnly) {
    return HealthRepository.local(db, now: ref.watch(healthDayClockProvider));
  }

  final local = ref.watch(emulatorAccountRuntimeProvider) != null;
  return HealthRepository(
    local
        ? NotificationService.instance
        : ref.watch(notificationServiceProvider),
    ref.watch(firebaseFirestoreProvider),
    ref.watch(firebaseAuthProvider),
    db,
    ref.watch(syncManagerProvider),
    now: ref.watch(healthDayClockProvider),
    sessionLease: ref.watch(localAccountSessionProvider).identity == null
        ? null
        : ref.read(localAccountSessionProvider.notifier).capture(),
    medicationsOnly: local,
    nativeRemindersEnabled: !local,
    waterController: local ? null : ref.watch(waterV2ControllerProvider),
    medicationLifecycle: local
        ? null
        : ref.watch(medicationReminderLifecycleProvider),
  );
});

// ===========================================================================
// SAÚDE DIÁRIA
// ===========================================================================

final healthStreamProvider = StreamProvider<HealthModel>((ref) {
  final repository = ref.watch(healthRepositoryProvider);
  final now = ref.watch(healthDayClockProvider)();
  final timer = ref.watch(healthDayTimerProvider)(
    nextHealthDayBoundary(now).difference(now),
    () {
      if (ref.mounted) ref.invalidateSelf();
    },
  );
  ref.onDispose(timer.cancel);

  // 🛡️ CORREÇÃO: Removido o .cast<HealthModel>() que estava matando o Broadcast
  // e impedindo a UI de receber as atualizações em tempo real.
  return repository.getHealthStream();
});

// ===========================================================================
// MEDICAMENTOS
// ===========================================================================

final medicationsStreamProvider = StreamProvider.autoDispose<List<Medication>>((
  ref,
) {
  final db = ref.watch(databaseProvider);

  return (db.select(db.medications)..orderBy([
        (table) => drift.OrderingTerm(
          expression: table.startDate,
          mode: drift.OrderingMode.desc,
        ),
      ]))
      .watch();
});

final localWaterGoalProvider = StreamProvider<int>(
  (ref) => ref.watch(healthRepositoryProvider).watchLocalWaterGoal(),
);
