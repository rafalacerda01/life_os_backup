import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:life_os/core/database/app_database.dart';
import '../../data/repositories/checkin_repository.dart';
import 'checkin_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
    // Gatilho de sincronização em background ao abrir a tela
    _triggerBackgroundSync();

    return const CheckInState();
  }

  /// Tenta enviar check-ins criados offline para o Firebase
  Future<void> _triggerBackgroundSync() async {
    try {
      final repository = ref.read(checkInRepositoryProvider);
      await repository.syncPendingCheckIns();
    } catch (e) {
      // Falha silenciosa: modo offline mantido com sucesso
    }
  }

  // Métodos para atualizar a UI do formulário
  void updateEnergy(double value) => state = state.copyWith(energy: value);
  void updateFocus(double value) => state = state.copyWith(focus: value);
  void updateMotivation(double value) =>
      state = state.copyWith(motivation: value);

  // Lógica de submissão
  Future<void> submitCheckIn({
    required Function onSuccess,
    required Function(String error) onError,
  }) async {
    state = state.copyWith(isLoading: true);

    try {
      final repository = ref.read(checkInRepositoryProvider);

      await repository.saveDailyMetrics(
        energy: state.energy,
        focus: state.focus,
        motivation: state.motivation,
      );

      onSuccess();
    } catch (e) {
      onError(e.toString());
    } finally {
      state = state.copyWith(isLoading: false);
    }
  }
}
