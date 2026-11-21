import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/features/tasks/data/services/local_task_reminder.dart';
import 'package:life_os/features/tasks/presentation/local_task_reminder_screen.dart';

class _Reminder implements TaskReminder {
  int? minuteOfDay;

  @override
  Future<bool> create(int minuteOfDay) async {
    this.minuteOfDay = minuteOfDay;
    return true;
  }

  @override
  Future<void> remove() async {
    minuteOfDay = null;
  }

  @override
  Future<TaskReminderStatus> status() async =>
      (minuteOfDay: minuteOfDay, needsRecovery: false);
}

void main() {
  testWidgets(
    'Portuguese reminder accepts a 24-hour time on a 12-hour device',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final reminder = _Reminder();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [localTaskReminderProvider.overrideWithValue(reminder)],
          child: MaterialApp(
            locale: const Locale('pt', 'BR'),
            supportedLocales: const [Locale('pt', 'BR')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(alwaysUse24HourFormat: false),
              child: child!,
            ),
            home: const LocalTaskReminderScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Agendar lembrete'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Mudar para o modo de entrada de texto'));
      await tester.pumpAndSettle();
      final fields = find.byType(TextFormField);
      await tester.enterText(fields.at(0), '19');
      await tester.enterText(fields.at(1), '30');
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      expect(reminder.minuteOfDay, 19 * 60 + 30);
    },
  );
}
