import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:life_os/core/router/router.dart';
import 'package:life_os/features/health/services/cycle_reminder_action_bootstrap.dart';
import 'package:life_os/main.dart';

// The root only watches this provider; no native notification startup is needed.
class _UnusedNotificationBootstrap implements CycleReminderActionBootstrap {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _openDatePickerKey = Key('open-date-picker');

Future<BuildContext> _pumpApp(
  WidgetTester tester, {
  ValueChanged<DateTime?>? onDateSelected,
}) async {
  tester.binding.platformDispatcher.localesTestValue = const [
    Locale('en', 'US'),
  ];
  addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);

  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => Scaffold(
          body: Center(
            child: TextButton(
              key: _openDatePickerKey,
              onPressed: () async {
                // No local overrides: exercise the actual LifeOSApp delegates.
                final date = await showDatePicker(
                  context: context,
                  initialDate: DateTime(2026, 9, 15),
                  currentDate: DateTime(2026, 9, 8),
                  firstDate: DateTime(2025),
                  lastDate: DateTime(2035),
                );
                onDateSelected?.call(date);
              },
              child: const Text('Abrir data'),
            ),
          ),
        ),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        routerProvider.overrideWithValue(router),
        cycleReminderActionBootstrapProvider.overrideWithValue(
          _UnusedNotificationBootstrap(),
        ),
      ],
      child: const LifeOSApp(),
    ),
  );
  await tester.pumpAndSettle();
  return tester.element(find.byKey(_openDatePickerKey));
}

Future<MaterialLocalizations> _openDatePicker(
  WidgetTester tester, {
  bool inputMode = false,
}) async {
  await tester.tap(find.byKey(_openDatePickerKey));
  await tester.pumpAndSettle();
  final context = tester.element(find.byType(DatePickerDialog));
  expect(Localizations.localeOf(context), const Locale('pt', 'BR'));
  final localizations = MaterialLocalizations.of(context);
  if (inputMode) {
    await tester.tap(find.byTooltip(localizations.inputDateModeButtonLabel));
    await tester.pumpAndSettle();
  }
  return localizations;
}

void main() {
  testWidgets('LifeOSApp keeps pt-BR delegates on an English device', (
    tester,
  ) async {
    final context = await _pumpApp(tester);
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));

    expect(tester.binding.platformDispatcher.locale, const Locale('en', 'US'));
    expect(app.locale, const Locale('pt', 'BR'));
    expect(app.supportedLocales, const [Locale('pt', 'BR')]);
    expect(Localizations.localeOf(context), const Locale('pt', 'BR'));
    expect(
      MaterialLocalizations.of(context),
      isA<GlobalMaterialLocalizations>(),
    );
    expect(WidgetsLocalizations.of(context), isA<GlobalWidgetsLocalizations>());
    expect(
      CupertinoLocalizations.of(context),
      isA<GlobalCupertinoLocalizations>(),
    );
    expect(MaterialLocalizations.of(context).cancelButtonLabel, 'Cancelar');
    expect(tester.takeException(), isNull);
  });

  testWidgets('date picker inherits Portuguese calendar and native labels', (
    tester,
  ) async {
    await _pumpApp(tester);
    final localizations = await _openDatePicker(tester);

    expect(find.text('Cancelar'), findsOneWidget);
    expect(find.text(localizations.datePickerHelpText), findsOneWidget);
    expect(localizations.datePickerHelpText, 'Selecione a data');
    final monthLabel = localizations.formatMonthYear(DateTime(2026, 9, 8));
    expect(monthLabel.toLowerCase(), contains('setembro'));
    expect(find.text(monthLabel), findsOneWidget);
    expect(find.text('Cancel'), findsNothing);
    expect(find.text('Select date'), findsNothing);

    await tester.tap(find.text(localizations.cancelButtonLabel));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('date input reads 08/09/2026 as September 8, not August 9', (
    tester,
  ) async {
    DateTime? selected;
    await _pumpApp(tester, onDateSelected: (date) => selected = date);
    final localizations = await _openDatePicker(tester, inputMode: true);

    expect(localizations.dateHelpText, 'dd/mm/aaaa');
    expect(localizations.formatCompactDate(DateTime(2026, 9, 8)), '08/09/2026');
    final input = tester.widget<TextField>(find.byType(TextField));
    expect(input.decoration?.hintText, localizations.dateHelpText);
    expect(input.decoration?.labelText, localizations.dateInputLabel);
    expect(find.text('Enter Date'), findsNothing);

    await tester.enterText(find.byType(TextField), '08/09/2026');
    await tester.tap(find.text(localizations.okButtonLabel));
    await tester.pumpAndSettle();

    expect(selected, DateTime(2026, 9, 8));
    expect(selected, isNot(DateTime(2026, 8, 9)));
    expect(find.byType(DatePickerDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('date input validates format and range in Portuguese', (
    tester,
  ) async {
    DateTime? selected;
    await _pumpApp(tester, onDateSelected: (date) => selected = date);
    final localizations = await _openDatePicker(tester, inputMode: true);

    await tester.enterText(find.byType(TextField), 'not-a-date');
    await tester.tap(find.text(localizations.okButtonLabel));
    await tester.pumpAndSettle();
    expect(find.text(localizations.invalidDateFormatLabel), findsOneWidget);
    expect(localizations.invalidDateFormatLabel, 'Formato inv\u00e1lido.');
    expect(selected, isNull);

    await tester.enterText(find.byType(TextField), '08/09/2024');
    await tester.tap(find.text(localizations.okButtonLabel));
    await tester.pumpAndSettle();
    expect(find.text(localizations.dateOutOfRangeLabel), findsOneWidget);
    expect(localizations.dateOutOfRangeLabel, 'Fora de alcance.');
    expect(selected, isNull);

    await tester.tap(find.text(localizations.cancelButtonLabel));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
