import 'dart:async';
import 'package:flutter/material.dart';
import 'package:life_os/core/services/water_v2_controller.dart';
import 'package:life_os/core/services/water_v2_provider.dart';
import 'package:life_os/features/health/data/repositories/health_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/features/health/data/models/health_model.dart';
import 'package:life_os/features/health/presentation/health_screen.dart';
import 'package:life_os/features/health/presentation/providers/health_provider.dart';
import 'package:life_os/features/premium/domain/services/plan_limits.dart';
import 'package:life_os/features/premium/presentation/plan_limits_provider.dart';

class _WaterRepository extends Fake implements HealthRepository {
  int calls = 0;
  Completer<void>? pending;
  @override
  Future<void> addWater() async {
    calls++;
    await pending?.future;
  }
}

class _GoalController extends Fake implements WaterV2Controller {
  final goals = <int>[];
  @override
  Future<void> setGoal(int value) async {
    goals.add(value);
  }
}

void main() {
  for (final state in [
    WaterAdmissionState.ready,
    WaterAdmissionState.offline,
    WaterAdmissionState.waiting,
    WaterAdmissionState.legacy,
    WaterAdmissionState.ineligible,
    WaterAdmissionState.deleting,
  ]) {
    testWidgets('Water V2 UI respects admission ${state.name}', (tester) async {
      final repository = _WaterRepository(), controller = _GoalController();
      final health = HealthModel(
        mood: 'Neutro',
        waterIntakeMl: 1000,
        hasTakenPillToday: false,
        date: DateTime(2026, 10, 13),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            healthStreamProvider.overrideWith((ref) => Stream.value(health)),
            medicationsStreamProvider.overrideWith(
              (ref) => Stream.value(const []),
            ),
            planLimitsProvider.overrideWithValue(PlanLimits.free),
            waterAdmissionProvider.overrideWith((ref) => Stream.value(state)),
            waterGoalProvider.overrideWith((ref) => Stream.value(2250)),
            waterV2ControllerProvider.overrideWithValue(controller),
            healthRepositoryProvider.overrideWithValue(repository),
          ],
          child: const MaterialApp(home: HealthScreen()),
        ),
      );
      await tester.pumpAndSettle();
      final label = find.text('+250 ml');
      await tester.scrollUntilVisible(label, 200);
      final button = tester.widget<OutlinedButton>(
        find.ancestor(of: label, matching: find.byType(OutlinedButton)).first,
      );
      final allowed = {
        WaterAdmissionState.ready,
        WaterAdmissionState.offline,
      }.contains(state);
      expect(button.onPressed != null, allowed);
      expect(find.text('Meta de 2250 ml'), findsOneWidget);
      if (allowed) {
        repository.pending = Completer<void>();
        await tester.tap(label);
        await tester.pump();
        await tester.tap(label);
        await tester.pump();
        expect(
          repository.calls,
          1,
        ); // UI serializes while the atomic local commit is pending.
        repository.pending!.complete();
        await tester.pumpAndSettle();
        await tester.tap(find.text('Alterar meta diária'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Salvar'));
        await tester.pumpAndSettle();
        expect(controller.goals, [2250]);
      } else {
        expect(repository.calls, 0);
      }
      expect(tester.takeException(), isNull);
    });
  }
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

  testWidgets('hidratação indisponível não aceita gesto nem anuncia crédito', (
    tester,
  ) async {
    final health = HealthModel(
      mood: 'Neutro',
      waterIntakeMl: 1000,
      hasTakenPillToday: false,
      date: DateTime(2026, 10, 13),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          healthStreamProvider.overrideWith((ref) => Stream.value(health)),
          medicationsStreamProvider.overrideWith(
            (ref) => Stream.value(const []),
          ),
          planLimitsProvider.overrideWithValue(PlanLimits.free),
          // No repository is available: tapping the disabled control must not read it.
          healthRepositoryProvider.overrideWith(
            (ref) => throw StateError('UNEXPECTED_WATER_GESTURE'),
          ),
        ],
        child: const MaterialApp(home: HealthScreen()),
      ),
    );
    await tester.pumpAndSettle();
    final label = find.text('Registro temporariamente indisponível');
    await tester.scrollUntilVisible(label, 250);
    await tester.ensureVisible(label);
    await tester.pumpAndSettle();
    final button = tester.widget<OutlinedButton>(
      find.ancestor(of: label, matching: find.byType(OutlinedButton)).first,
    );
    expect(button.onPressed, isNull);
    await tester.tap(label);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('Registrar +250 ml'), findsNothing);
    expect(find.text('1250 ml registrados'), findsNothing);
    expect(find.text('1000 ml registrados'), findsOneWidget);
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
