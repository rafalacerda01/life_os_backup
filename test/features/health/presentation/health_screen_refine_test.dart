import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/features/health/data/models/health_model.dart';
import 'package:life_os/features/health/presentation/health_screen.dart';
import 'package:life_os/features/health/presentation/providers/health_provider.dart';
import 'package:life_os/features/premium/domain/services/plan_limits.dart';
import 'package:life_os/features/premium/presentation/plan_limits_provider.dart';

void main() {
  testWidgets('resumo do dia mostra somente dados reais registrados', (
    tester,
  ) async {
    final health = HealthModel(
      mood: '—',
      waterIntakeMl: 1750,
      hasTakenPillToday: false,
      date: DateTime(2026, 9, 7),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          healthStreamProvider.overrideWith((ref) => Stream.value(health)),
          medicationsStreamProvider.overrideWith(
            (ref) => Stream.value(const []),
          ),
          planLimitsProvider.overrideWithValue(PlanLimits.free),
        ],
        child: const MaterialApp(home: HealthScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('HOJE'), findsOneWidget);
    expect(find.text('Não registrado'), findsOneWidget);
    expect(find.text('1750 ml'), findsOneWidget);
    expect(find.text('Cuidados'), findsNothing);
    expect(find.text('Monitorados'), findsNothing);
    expect(find.text('Sugestão'), findsNothing);
    expect(find.text('Disponível'), findsNothing);
  });

  testWidgets('card do ciclo preserva key e linguagem de estimativa', (
    tester,
  ) async {
    final health = HealthModel(
      mood: 'Neutro',
      waterIntakeMl: 0,
      hasTakenPillToday: false,
      menstrualCycle: {
        'isEnabled': true,
        'lastPeriodStart': DateTime.now().toIso8601String(),
        'cycleLengthDays': 28,
        'periodLengthDays': 5,
      },
      date: DateTime.now(),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CycleHealthSummaryCard(health: health, onTap: () {}),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('cycle-health-summary-card')),
      findsOneWidget,
    );
    expect(find.textContaining('Estimativa:'), findsOneWidget);
  });

  testWidgets('card do medicamento mostra horário persistido em 24 horas', (
    tester,
  ) async {
    final health = HealthModel(
      mood: 'Neutro',
      waterIntakeMl: 0,
      hasTakenPillToday: false,
      date: DateTime(2026, 9, 7),
    );
    final medication = Medication(
      id: 1,
      firestoreId: 'medication-1',
      name: 'Medicamento noturno',
      startDate: DateTime(2026, 9, 7, 21, 30),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          healthStreamProvider.overrideWith((ref) => Stream.value(health)),
          medicationsStreamProvider.overrideWith(
            (ref) => Stream.value([medication]),
          ),
          planLimitsProvider.overrideWithValue(PlanLimits.free),
        ],
        child: const MaterialApp(home: HealthScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Medicamento noturno'), 300);

    expect(find.text('Medicamento noturno'), findsOneWidget);
    expect(find.text('21:30'), findsOneWidget);
  });
}
