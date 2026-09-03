import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:life_os/core/router/router.dart';
import 'package:life_os/features/auth/presentation/providers/auth_provider.dart';
import 'package:life_os/features/auth/presentation/providers/auth_state.dart';
import 'package:life_os/features/health/data/models/health_model.dart';
import 'package:life_os/features/health/presentation/health_screen.dart';
import 'package:life_os/features/health/presentation/providers/health_provider.dart';
import 'package:life_os/features/health/services/cycle_reminder_action_bootstrap.dart';
import 'package:life_os/features/premium/domain/services/plan_limits.dart';
import 'package:life_os/features/premium/presentation/plan_limits_provider.dart';
import 'package:life_os/main.dart';

// Keep the real app root without starting native notification services.
class _UnusedNotificationBootstrap implements CycleReminderActionBootstrap {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _UnauthenticatedNotifier extends AuthNotifier {
  @override
  AuthState build() => AuthState.unauthenticated();
}

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
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => HealthScreen(
            medicationAdder: medicationAdder,
            medicationTimePicker: timePicker,
            clock: () => selectedDate,
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          routerProvider.overrideWithValue(router),
          authNotifierProvider.overrideWith(_UnauthenticatedNotifier.new),
          cycleReminderActionBootstrapProvider.overrideWithValue(
            _UnusedNotificationBootstrap(),
          ),
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
        child: const LifeOSApp(),
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

  for (final sample in [
    (hour: 9, minute: 5, label: '09:05', twelveHourLabel: '9:05'),
    (hour: 21, minute: 30, label: '21:30', twelveHourLabel: '9:30'),
  ]) {
    testWidgets('medication uses ${sample.label} on an English 12h device', (
      tester,
    ) async {
      final platform = tester.binding.platformDispatcher;
      platform.localesTestValue = const [Locale('en', 'US')];
      platform.alwaysUse24HourFormatTestValue = false;
      addTearDown(platform.clearLocalesTestValue);
      addTearDown(platform.clearAlwaysUse24HourTestValue);

      DateTime? receivedStartDate;
      var saveCalls = 0;
      await pumpHealthScreen(
        tester,
        medicationAdder: (_, startDate, _) async {
          saveCalls += 1;
          receivedStartDate = startDate;
        },
      );
      // Leave medicationTimePicker unset to open the production showTimePicker.
      expect(platform.locale, const Locale('en', 'US'));
      expect(platform.alwaysUse24HourFormat, isFalse);
      final screenContext = tester.element(find.byType(HealthScreen));
      expect(Localizations.localeOf(screenContext), const Locale('pt', 'BR'));
      expect(MediaQuery.alwaysUse24HourFormatOf(screenContext), isFalse);

      await tester.tap(find.text('Selecionar horário'));
      await tester.pumpAndSettle();
      final picker = find.byType(TimePickerDialog);
      expect(picker, findsOneWidget);
      final pickerContext = tester.element(picker);
      final localizations = MaterialLocalizations.of(pickerContext);
      expect(Localizations.localeOf(pickerContext), const Locale('pt', 'BR'));
      expect(MediaQuery.alwaysUse24HourFormatOf(pickerContext), isTrue);
      expect(
        localizations.timeOfDayFormat(
          alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(
            pickerContext,
          ),
        ),
        TimeOfDayFormat.HH_colon_mm,
      );
      expect(localizations.cancelButtonLabel, 'Cancelar');
      expect(
        find.descendant(of: picker, matching: find.text('Cancelar')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: picker, matching: find.text('OK')),
        findsOneWidget,
      );
      expect(find.text('Cancel'), findsNothing);
      expect(find.text('AM'), findsNothing);
      expect(find.text('PM'), findsNothing);

      await tester.tap(find.byTooltip(localizations.inputTimeModeButtonLabel));
      await tester.pumpAndSettle();
      final fields = find.descendant(
        of: picker,
        matching: find.byType(TextField),
      );
      expect(fields, findsNWidgets(2));
      expect(localizations.timePickerHourLabel, 'Hora');
      expect(localizations.timePickerMinuteLabel, 'Minuto');
      expect(
        find.descendant(
          of: picker,
          matching: find.text(localizations.timePickerHourLabel),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: picker,
          matching: find.text(localizations.timePickerMinuteLabel),
        ),
        findsOneWidget,
      );
      await tester.enterText(fields.at(0), sample.hour.toString());
      await tester.enterText(fields.at(1), sample.minute.toString());
      expect(find.text('AM'), findsNothing);
      expect(find.text('PM'), findsNothing);
      await tester.tap(
        find.descendant(
          of: picker,
          matching: find.text(localizations.okButtonLabel),
        ),
      );
      await tester.pumpAndSettle();

      expect(picker, findsNothing);
      // This label is rendered by HealthScreen's actual TimeOfDay.format call.
      final displayedTime = find.text(sample.label);
      expect(displayedTime, findsOneWidget);
      final displayedContext = tester.element(displayedTime);
      expect(
        Localizations.localeOf(displayedContext),
        const Locale('pt', 'BR'),
      );
      expect(MediaQuery.alwaysUse24HourFormatOf(displayedContext), isFalse);
      expect(find.text(sample.twelveHourLabel), findsNothing);
      expect(find.text('${sample.twelveHourLabel} AM'), findsNothing);
      expect(find.text('${sample.twelveHourLabel} PM'), findsNothing);
      expect(find.text('${sample.label} AM'), findsNothing);
      expect(find.text('${sample.label} PM'), findsNothing);
      expect(saveCalls, 0);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Salvar'));
      await tester.pumpAndSettle();
      expect(saveCalls, 1);
      expect(
        receivedStartDate,
        DateTime(2026, 8, 25, sample.hour, sample.minute),
      );
      expect(receivedStartDate?.hour, sample.hour);
      expect(receivedStartDate?.minute, sample.minute);
      expect(tester.takeException(), isNull);
    });
  }
}
