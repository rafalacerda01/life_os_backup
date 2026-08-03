import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/features/home/presentation/providers/home_provider.dart';
import 'package:life_os/features/dashboard/presentation/providers/dashboard_provider.dart';
import 'package:life_os/features/habits/presentation/providers/habits_provider.dart';
import 'package:life_os/features/health/presentation/providers/health_provider.dart';
import 'package:life_os/features/study/presentation/providers/study_provider.dart';
import 'package:life_os/features/dashboard/data/models/dashboard_model.dart';

void main() {
  group('HomeStateProvider Tests', () {
    test('Deve calcular corretamente as métricas iniciais da Home', () {
      // 1. Cria o container do Riverpod para gerenciar os estados nos testes
      final container = ProviderContainer(
        overrides: [
          // Sobrescrevemos o dashboard com os parâmetros corretos exigidos pelo modelo
          dashboardStateProvider.overrideWith(
            (ref) => DashboardModel(
              productivityScore: 85.0,
              healthScore: 90.0,
              financialScore: 75.0,
              studyStreak: 5,
              studyReviewQueue: 2,
              studyProgress: 0.6,
              activeMedications: 1,
              transactionsCount: 10,
              financeBalance: 1500.0,
            ),
          ),
          // StreamProviders exigem o retorno de um Stream e não de um AsyncValue diretamente
          habitsStreamProvider.overrideWith((ref) => Stream.value([])),
          medicationsStreamProvider.overrideWith((ref) => Stream.value([])),
          subjectsStreamProvider.overrideWith((ref) => Stream.value([])),
        ],
      );

      // Garante o dispose correto do container após o teste
      addTearDown(container.dispose);

      // 2. Lê o provider que desejamos testar
      final homeState = container.read(homeStateProvider);

      // 3. Valida se o estado reflete o comportamento esperado
      expect(homeState.totalHabits, 0);
      expect(homeState.completedHabitsToday, 0);
      expect(homeState.medicationCount, 0);
      expect(homeState.dashboard.productivityScore, 85.0);
      expect(homeState.dashboard.studyStreak, 5);
    });
  });
}
