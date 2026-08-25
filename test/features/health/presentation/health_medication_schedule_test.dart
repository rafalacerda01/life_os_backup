import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/features/health/data/models/health_model.dart';
import 'package:life_os/features/health/presentation/health_screen.dart';
import 'package:life_os/features/health/presentation/providers/health_provider.dart';
import 'package:life_os/features/premium/domain/services/plan_limits.dart';
import 'package:life_os/features/premium/presentation/plan_limits_provider.dart';

void main() {
  final selectedDate = DateTime(2026, 8, 25, 14, 37, 42, 900);

  test('combina 25/08/2026 e 21:00 sem segundos', () {
    final result = combineMedicationDateAndTime(
      selectedDate,
      const TimeOfDay(hour: 21, minute: 0),
    );

    expect(result, DateTime(2026, 8, 25, 21));
  });

  test('meia-noite escolhida explicitamente continua válida', () {
    final result = combineMedicationDateAndTime(
      selectedDate,
      const TimeOfDay(hour: 0, minute: 0),
    );

    expect(result, DateTime(2026, 8, 25));
  });

  Future<void> pumpHealthScreen(
    WidgetTester tester, {
    required MedicationAdder medicationAdder,
    MedicationTimePicker? timePicker,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          healthStreamProvider.overrideWith(
            (ref) => Stream.value(
              HealthModel(
                mood: 'Neutro',
                waterIntakeMl: 0,
                hasTakenPillToday: false,
                date: selectedDate,
              ),
            ),
          ),
          medicationsStreamProvider.overrideWith(
            (ref) => Stream.value(const []),
          ),
          planLimitsProvider.overrideWithValue(PlanLimits.free),
        ],
        child: MaterialApp(
          home: HealthScreen(
            medicationAdder: medicationAdder,
            medicationTimePicker: timePicker,
            clock: () => selectedDate,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byTooltip('Adicionar medicamento'),
      300,
    );
    await tester.tap(find.byTooltip('Adicionar medicamento'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Vitamina D');
  }

  testWidgets('sem horário não chama addMedication', (tester) async {
    var calls = 0;
    await pumpHealthScreen(
      tester,
      medicationAdder: (_, _, _) async => calls += 1,
    );

    await tester.tap(find.widgetWithText(ElevatedButton, 'Salvar'));
    await tester.pumpAndSettle();

    expect(calls, 0);
    expect(find.text('Selecione o horário do lembrete.'), findsOneWidget);
  });

  testWidgets('horário escolhido chega combinado ao repository', (
    tester,
  ) async {
    DateTime? receivedStartDate;
    await pumpHealthScreen(
      tester,
      medicationAdder: (_, startDate, _) async {
        receivedStartDate = startDate;
      },
      timePicker: (_) async => const TimeOfDay(hour: 21, minute: 0),
    );

    await tester.tap(find.text('Selecionar horário'));
    await tester.pump();
    await tester.tap(find.widgetWithText(ElevatedButton, 'Salvar'));
    await tester.pumpAndSettle();

    expect(receivedStartDate, DateTime(2026, 8, 25, 21));
  });
}
