import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:life_os/features/checkin/data/repositories/checkin_repository.dart';
import 'package:life_os/features/checkin/presentation/providers/checkin_controller.dart';
import 'package:life_os/features/checkin/presentation/providers/check_in_provider.dart';

@GenerateNiceMocks([MockSpec<CheckInRepository>()])
import 'checkin_controller_test.mocks.dart';

void main() {
  late MockCheckInRepository mockCheckInRepository;
  late ProviderContainer container;

  setUp(() {
    mockCheckInRepository = MockCheckInRepository();

    // Stub do background sync chamado automaticamente no build() do controller
    when(mockCheckInRepository.syncPendingCheckIns()).thenAnswer((_) async {});

    container = ProviderContainer(
      overrides: [
        checkInRepositoryProvider.overrideWithValue(mockCheckInRepository),
      ],
    );
  });

  tearDown(() {
    container.dispose();
  });

  group('CheckInController Tests', () {
    test('estado inicial deve ter valores padrão (3.0) e isLoading falso', () {
      final state = container.read(checkInControllerProvider);

      expect(state.energy, 3.0);
      expect(state.focus, 3.0);
      expect(state.motivation, 3.0);
      expect(state.isLoading, false);
    });

    test(
      'deve atualizar os valores de energia, foco e motivação corretamente',
      () {
        final notifier = container.read(checkInControllerProvider.notifier);

        notifier.updateEnergy(4.5);
        notifier.updateFocus(5.0);
        notifier.updateMotivation(2.0);

        final state = container.read(checkInControllerProvider);
        expect(state.energy, 4.5);
        expect(state.focus, 5.0);
        expect(state.motivation, 2.0);
      },
    );

    test(
      'submitCheckIn deve salvar métricas com sucesso e chamar onSuccess',
      () async {
        final notifier = container.read(checkInControllerProvider.notifier);

        when(
          mockCheckInRepository.saveDailyMetrics(
            energy: 3.0,
            focus: 3.0,
            motivation: 3.0,
          ),
        ).thenAnswer((_) async {});

        bool successCalled = false;
        String? errorCaptured;

        await notifier.submitCheckIn(
          onSuccess: () => successCalled = true,
          onError: (err) => errorCaptured = err,
        );

        expect(successCalled, isTrue);
        expect(errorCaptured, isNull);
        verify(
          mockCheckInRepository.saveDailyMetrics(
            energy: 3.0,
            focus: 3.0,
            motivation: 3.0,
          ),
        ).called(1);

        expect(container.read(checkInControllerProvider).isLoading, isFalse);
      },
    );

    test(
      'submitCheckIn deve capturar exceção, chamar onError e resetar isLoading',
      () async {
        final notifier = container.read(checkInControllerProvider.notifier);

        when(
          mockCheckInRepository.saveDailyMetrics(
            energy: 3.0,
            focus: 3.0,
            motivation: 3.0,
          ),
        ).thenThrow(Exception('Erro ao gravar no banco local'));

        bool successCalled = false;
        String? errorCaptured;

        await notifier.submitCheckIn(
          onSuccess: () => successCalled = true,
          onError: (err) => errorCaptured = err,
        );

        expect(successCalled, isFalse);
        expect(
          errorCaptured,
          contains('Exception: Erro ao gravar no banco local'),
        );
        expect(container.read(checkInControllerProvider).isLoading, isFalse);
      },
    );
  });
}
