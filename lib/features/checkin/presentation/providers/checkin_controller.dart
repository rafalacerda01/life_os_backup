import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/features/checkin/presentation/providers/check_in_provider.dart';
import 'package:life_os/core/utils/app_logger.dart'; // 🚀 Nosso Logger injetado
import 'checkin_state.dart';
import 'package:life_os/core/services/emulator_account_runtime.dart';

part 'checkin_controller.g.dart';

// ===========================================================================
// 1. PROVIDER DE HISTÓRICO (STREAM PROVIDER TRADICIONAL)
// ===========================================================================
final checkInHistoryProvider = StreamProvider.autoDispose<List<CheckInEntry>>((
  ref,
) {
  final repository = ref.watch(checkInRepositoryProvider);
  return repository.watchCheckIns();
});

// ===========================================================================
// 2. CONTROLLER DO FORMULÁRIO (STATE MANAGEMENT)
// ===========================================================================
@riverpod
class CheckInController extends _$CheckInController {
  @override
  CheckInState build() {
    ref.watch(checkInRepositoryProvider);
    // Gatilho de sincronização em background ao abrir a tela
    _triggerBackgroundSync();
    return const CheckInState();
  }

  /// Tenta enviar check-ins criados offline para o Firebase
  Future<void> _triggerBackgroundSync() async {
    try {
      final repository = ref.read(checkInRepositoryProvider);
      await repository.syncPendingCheckIns();
      if (ref.mounted && ref.read(emulatorAccountRuntimeProvider) != null) await repository.syncCheckinsFromFirebaseToLocal();
    } catch (error, stackTrace) {
      // 🚀 Falha silenciosa para o usuário, mas registrada para o desenvolvedor!
      AppLogger.e(
        'Falha silenciosa no background sync de check-ins',
        error,
        stackTrace,
      );
    }
  }

  // Métodos para atualizar a UI do formulário
  void updateEnergy(double value) => state = state.copyWith(energy: value);
  void updateFocus(double value) => state = state.copyWith(focus: value);
  void updateMotivation(double value) =>
      state = state.copyWith(motivation: value);

  // Lógica de submissão
  Future<void> submitCheckIn({
    required void Function() onSuccess,
    required void Function() onError,
  }) async {
    state = state.copyWith(isLoading: true);

    try {
      final repository = ref.read(checkInRepositoryProvider);

      await repository.saveDailyMetrics(
        energy: state.energy,
        focus: state.focus,
        motivation: state.motivation,
      );

      if (ref.mounted) onSuccess();
    } catch (error, stackTrace) {
      AppLogger.e('Erro ao submeter check-in', error, stackTrace);
      if (ref.mounted) onError();
    } finally {
      if (ref.mounted) state = state.copyWith(isLoading: false);
    }
  }
}
