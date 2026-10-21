import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:life_os/core/services/water_v2_configuration.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/core/database/database_provider.dart';
import 'package:life_os/core/services/sync_manager_provider.dart';
import 'package:life_os/core/services/water_v2_controller.dart';
import 'package:life_os/core/services/water_v2_remote_data_source.dart';
import 'package:life_os/core/services/water_v2_sync_processor.dart';
import 'package:life_os/features/auth/presentation/providers/auth_provider.dart';

final waterV2RemoteProvider = Provider<WaterV2RemoteDataSource>((ref) {
  final db = ref.watch(databaseProvider);
  return WaterV2RemoteDataSource(
    ref.watch(firebaseAuthProvider),
    captureRemoteSend: (uid) =>
        db.localMutations.captureRemoteSend(expectedUid: uid),
  );
});
final waterV2ProcessorProvider = Provider<WaterV2SyncProcessor>(
  (ref) => WaterV2SyncProcessor(
    ref.watch(databaseProvider),
    ref.watch(waterV2RemoteProvider),
  ),
);
final waterV2ControllerProvider = Provider<WaterV2Controller>((ref) {
  final auth = ref.watch(firebaseAuthProvider);
  final controller = WaterV2Controller(
    ref.watch(databaseProvider),
    ref.watch(waterV2RemoteProvider),
    ref.watch(waterV2ProcessorProvider),
    () => auth.currentUser?.uid,
    afterCommit: () => ref.read(syncManagerProvider).processPendingItems(),
  );
  Timer? timer;
  final lifecycle = _WaterLifecycle(() => unawaited(controller.refresh()));
  if (controller.isEnabled) {
    WidgetsBinding.instance.addObserver(lifecycle);
    timer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => unawaited(controller.refresh()),
    );
    unawaited(controller.refresh());
  }
  ref.onDispose(() {
    timer?.cancel();
    if (controller.isEnabled) WidgetsBinding.instance.removeObserver(lifecycle);
    controller.dispose();
  });
  return controller;
});
final waterAdmissionProvider = StreamProvider<WaterAdmissionState>((
  ref,
) async* {
  if (!WaterV2Configuration.enabled) {
    yield WaterAdmissionState.disabled;
    return;
  }
  final controller = ref.watch(waterV2ControllerProvider);
  yield controller.state;
  yield* controller.states;
});
final waterGoalProvider = StreamProvider<int>((ref) {
  if (!WaterV2Configuration.enabled) return Stream.value(3000);
  return ref.watch(waterV2ControllerProvider).watchGoal();
});

class _WaterLifecycle extends WidgetsBindingObserver {
  _WaterLifecycle(this.resume);
  final void Function() resume;
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) resume();
  }
}
