import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'dart:async';

@GenerateNiceMocks([MockSpec<CheckinRepository>()])
import 'checkin_provider_test.mocks.dart';

class CheckinRepository {
  Future<bool> saveCheckin(String note) async => true;
}

final checkinRepositoryProvider = Provider<CheckinRepository>(
  (ref) => CheckinRepository(),
);

final checkinNotifierProvider = AsyncNotifierProvider<CheckinNotifier, bool>(
  CheckinNotifier.new,
);

class CheckinNotifier extends AsyncNotifier<bool> {
  @override
  FutureOr<bool> build() => false;

  Future<void> makeCheckin(String note) async {
    final repository = ref.read(checkinRepositoryProvider);
    state = const AsyncLoading();
    final result = await repository.saveCheckin(note);
    state = AsyncData(result);
  }
}

void main() {
  late MockCheckinRepository mockRepository;
  late ProviderContainer container;

  setUp(() {
    mockRepository = MockCheckinRepository();
    container = ProviderContainer(
      overrides: [checkinRepositoryProvider.overrideWithValue(mockRepository)],
    );
  });

  tearDown(() {
    container.dispose();
  });

  test('deve salvar o checkin com sucesso e atualizar o estado', () async {
    // Configura o mock
    when(mockRepository.saveCheckin(any)).thenAnswer((_) async => true);

    // Lê o notifier através do container
    final notifier = container.read(checkinNotifierProvider.notifier);

    // Estado inicial deve ser false
    expect(container.read(checkinNotifierProvider).value, false);

    // Executa a ação de checkin
    final future = notifier.makeCheckin('Bom dia!');

    // Verifica se passou pelo estado de carregamento (Loading)
    expect(container.read(checkinNotifierProvider).isLoading, true);

    await future;

    // Verifica se o estado final é true (Data)
    expect(container.read(checkinNotifierProvider).value, true);

    // Confirma que o método do repositório foi chamado corretamente
    verify(mockRepository.saveCheckin('Bom dia!')).called(1);
  });
}
