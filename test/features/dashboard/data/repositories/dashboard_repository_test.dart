import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/features/dashboard/data/models/dashboard_model.dart';
import 'package:life_os/features/dashboard/data/repositories/dashboard_repository.dart';

class _FakeHealthData {
  final String mood;
  final dynamic waterIntakeMl;

  const _FakeHealthData({required this.mood, required this.waterIntakeMl});
}

class _InvalidTransaction {
  const _InvalidTransaction();
}

void main() {
  group('DashboardRepository.generateDashboard', () {
    late DashboardRepository repository;

    setUp(() {
      repository = DashboardRepository();
    });

    DashboardModel generate({
      dynamic healthData,
      List<dynamic> transactions = const [],
      dynamic studyData,
      List<dynamic> taskList = const [],
      List<dynamic> medicationsList = const [],
    }) {
      return repository.generateDashboard(
        transactions: transactions,
        studyData: studyData,
        healthData: healthData,
        taskList: taskList,
        medicationsList: medicationsList,
      );
    }

    test('usuário novo sem humor e sem água fica em 0%', () {
      final dashboard = generate(
        healthData: const _FakeHealthData(mood: '—', waterIntakeMl: 0),
      );

      expect(dashboard.healthScore, 0.0);
    });

    test('água em 1500 ml gera 25 pontos', () {
      final dashboard = generate(
        healthData: const _FakeHealthData(mood: '—', waterIntakeMl: 1500),
      );

      expect(dashboard.healthScore, 25.0);
    });

    test('água em 3000 ml ou mais gera 50 pontos', () {
      final dashboardAtLimit = generate(
        healthData: const _FakeHealthData(mood: '—', waterIntakeMl: 3000),
      );

      final dashboardAboveLimit = generate(
        healthData: const _FakeHealthData(mood: '—', waterIntakeMl: 4200),
      );

      expect(dashboardAtLimit.healthScore, 50.0);
      expect(dashboardAboveLimit.healthScore, 50.0);
    });

    test('mapeia corretamente cada humor', () {
      final cases = <String, double>{
        '—': 0.0,
        'Sem registro': 0.0,
        'Estressado': 10.0,
        'Cansado': 20.0,
        'Neutro': 30.0,
        'Focado': 40.0,
        'Radiante': 50.0,
      };

      for (final entry in cases.entries) {
        final dashboard = generate(
          healthData: _FakeHealthData(mood: entry.key, waterIntakeMl: 0),
        );

        expect(
          dashboard.healthScore,
          entry.value,
          reason: 'Humor ${entry.key} deveria gerar ${entry.value} pontos',
        );
      }
    });

    test('Radiante com 3000 ml fecha em 100%', () {
      final dashboard = generate(
        healthData: const _FakeHealthData(
          mood: 'Radiante',
          waterIntakeMl: 3000,
        ),
      );

      expect(dashboard.healthScore, 100.0);
    });

    test('entrada inválida aciona fallback seguro com healthScore 0', () {
      final dashboard = repository.generateDashboard(
        transactions: const [_InvalidTransaction()],
        studyData: null,
        healthData: const _FakeHealthData(
          mood: 'Radiante',
          waterIntakeMl: 3000,
        ),
        taskList: const [],
        medicationsList: const [],
      );

      expect(dashboard.healthScore, 0.0);
      expect(dashboard.mood, '—');
    });
  });
}
