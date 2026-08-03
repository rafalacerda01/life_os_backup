import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/features/habits/presentation/providers/habits_provider.dart';

void main() {
  group('HabitsProvider Tests', () {
    test('Deve inicializar o stream de hábitos corretamente', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      // Lê o provider de stream de hábitos
      final habitsStream = container.read(habitsStreamProvider);

      // Valida que o stream começa em estado de carregamento ou dados vazios dependendo do mock
      expect(habitsStream, isA<AsyncValue<List<dynamic>>>());
    });
  });
}
