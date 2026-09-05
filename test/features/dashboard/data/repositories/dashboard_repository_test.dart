import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/features/dashboard/data/models/dashboard_model.dart';
import 'package:life_os/features/dashboard/data/repositories/dashboard_repository.dart';

class _FakeHealthData {
  final String mood;
  final dynamic waterIntakeMl;

  const _FakeHealthData({required this.mood, required this.waterIntakeMl});
}

class _FakeTransaction {
  final String type;
  final double amount;

  const _FakeTransaction(this.type, this.amount);
}

class _FakeTask {
  final bool isCompleted;

  const _FakeTask(this.isCompleted);
}

class _FakeStudyData {
  final double progress;
  final int reviewQueue;
  final int streak = 0;

  const _FakeStudyData({required this.progress, required this.reviewQueue});
}

class _InvalidTransaction {
  const _InvalidTransaction();
}

DashboardModel _dashboard({
  double productivityScore = 0,
  bool hasProductivityData = false,
  double healthScore = 0,
  bool hasHealthData = false,
  double financialScore = 0,
  bool hasFinancialData = false,
}) {
  return DashboardModel(
    productivityScore: productivityScore,
    hasProductivityData: hasProductivityData,
    healthScore: healthScore,
    hasHealthData: hasHealthData,
    financialScore: financialScore,
    hasFinancialData: hasFinancialData,
    studyStreak: 0,
    studyReviewQueue: 0,
    studyProgress: 0,
    activeMedications: 0,
    transactionsCount: 0,
    financeBalance: 0,
  );
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

    test('usuário novo sem humor e sem água fica sem dados de saúde', () {
      final dashboard = generate(
        healthData: const _FakeHealthData(mood: '—', waterIntakeMl: 0),
      );

      expect(dashboard.healthScore, 0.0);
      expect(dashboard.hasHealthData, isFalse);
    });

    test('água em 1500 ml sem humor gera 50%', () {
      final dashboard = generate(
        healthData: const _FakeHealthData(mood: '—', waterIntakeMl: 1500),
      );

      expect(dashboard.healthScore, 50.0);
      expect(dashboard.hasHealthData, isTrue);
    });

    test('água em 3000 ml ou mais sem humor gera 100%', () {
      final dashboardAtLimit = generate(
        healthData: const _FakeHealthData(mood: '—', waterIntakeMl: 3000),
      );

      final dashboardAboveLimit = generate(
        healthData: const _FakeHealthData(mood: '—', waterIntakeMl: 4200),
      );

      expect(dashboardAtLimit.healthScore, 100.0);
      expect(dashboardAboveLimit.healthScore, 100.0);
      expect(dashboardAtLimit.hasHealthData, isTrue);
    });

    test('normaliza corretamente cada humor quando não há água', () {
      final cases = <String, double>{
        '—': 0.0,
        'Sem registro': 0.0,
        'Estressado': 20.0,
        'Cansado': 40.0,
        'Neutro': 60.0,
        'Focado': 80.0,
        'Radiante': 100.0,
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
      expect(dashboard.hasHealthData, isTrue);
    });

    test('Neutro com 1500 ml gera 55%', () {
      final dashboard = generate(
        healthData: const _FakeHealthData(mood: 'Neutro', waterIntakeMl: 1500),
      );

      expect(dashboard.healthScore, 55.0);
      expect(dashboard.hasHealthData, isTrue);
    });

    test('sem transações fica sem dados financeiros', () {
      final dashboard = generate();

      expect(dashboard.financialScore, 0.0);
      expect(dashboard.hasFinancialData, isFalse);
    });

    test('receita 1000 e despesa 200 gera score financeiro 80%', () {
      final dashboard = generate(
        transactions: const [
          _FakeTransaction('income', 1000),
          _FakeTransaction('expense', 200),
        ],
      );

      expect(dashboard.financialScore, 80.0);
      expect(dashboard.hasFinancialData, isTrue);
    });

    test('despesa acima da receita limita score financeiro em zero', () {
      final dashboard = generate(
        transactions: const [
          _FakeTransaction('income', 1000),
          _FakeTransaction('expense', 1200),
        ],
      );

      expect(dashboard.financialScore, 0.0);
      expect(dashboard.hasFinancialData, isTrue);
    });

    test('somente despesa é dado financeiro real com score zero', () {
      final dashboard = generate(
        transactions: const [_FakeTransaction('expense', 200)],
      );

      expect(dashboard.financialScore, 0.0);
      expect(dashboard.hasFinancialData, isTrue);
    });

    test('sem tarefas e sem estudo fica sem dados de produtividade', () {
      final dashboard = generate();

      expect(dashboard.productivityScore, 0.0);
      expect(dashboard.hasProductivityData, isFalse);
    });

    test('tarefas incompletas são dados reais com score zero', () {
      final dashboard = generate(
        taskList: const [_FakeTask(false), _FakeTask(false)],
      );

      expect(dashboard.productivityScore, 0.0);
      expect(dashboard.hasProductivityData, isTrue);
    });

    test('tarefas e estudo preservam a fórmula 70/30', () {
      final dashboard = generate(
        taskList: const [_FakeTask(true), _FakeTask(false)],
        studyData: const _FakeStudyData(progress: 0.8, reviewQueue: 1),
      );

      expect(dashboard.productivityScore, 59.0);
      expect(dashboard.hasProductivityData, isTrue);
    });

    test('entrada inválida aciona fallback seguro sem dados', () {
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
      expect(dashboard.financialScore, 0.0);
      expect(dashboard.mood, '—');
      expect(dashboard.hasProductivityData, isFalse);
      expect(dashboard.hasHealthData, isFalse);
      expect(dashboard.hasFinancialData, isFalse);
    });
  });

  group('DashboardModel.overallScore', () {
    test('usa produtividade e saúde quando finanças estão ausentes', () {
      final dashboard = _dashboard(
        productivityScore: 80,
        hasProductivityData: true,
        healthScore: 60,
        hasHealthData: true,
      );

      expect(dashboard.overallScore, 70.0);
    });

    test('usa somente saúde quando é o único domínio presente', () {
      final dashboard = _dashboard(healthScore: 50, hasHealthData: true);

      expect(dashboard.overallScore, 50.0);
    });

    test('retorna null quando nenhum domínio possui dados', () {
      expect(_dashboard().overallScore, isNull);
    });
  });

  group('DashboardModel serialization', () {
    test('JSON legado sem flags permanece compatível', () {
      final dashboard = DashboardModel.fromJson(const {
        'productivityScore': 80,
        'healthScore': 60,
        'financialScore': 40,
      });

      expect(dashboard.productivityScore, 80.0);
      expect(dashboard.healthScore, 60.0);
      expect(dashboard.financialScore, 40.0);
      expect(dashboard.hasProductivityData, isFalse);
      expect(dashboard.hasHealthData, isFalse);
      expect(dashboard.hasFinancialData, isFalse);
      expect(dashboard.overallScore, isNull);
    });

    test('toJson e fromJson preservam as três flags', () {
      final original = _dashboard(
        productivityScore: 0,
        hasProductivityData: true,
        healthScore: 50,
        hasHealthData: true,
        financialScore: 0,
        hasFinancialData: true,
      );
      final restored = DashboardModel.fromJson(original.toJson());

      expect(restored, original);
      expect(restored.hasProductivityData, isTrue);
      expect(restored.hasHealthData, isTrue);
      expect(restored.hasFinancialData, isTrue);
    });
  });
}
