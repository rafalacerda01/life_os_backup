import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:life_os/features/habits/data/models/habit_model.dart';
import 'package:life_os/features/habits/presentation/habits_screen.dart';
import 'package:life_os/features/habits/presentation/providers/habits_provider.dart';

void main() {
  setUpAll(() => initializeDateFormatting('pt_BR'));

  testWidgets('weekday initials stay Portuguese with English Intl and device', (
    tester,
  ) async {
    final platform = tester.binding.platformDispatcher;
    platform.localesTestValue = const [Locale('en', 'US')];
    addTearDown(platform.clearLocalesTestValue);

    await Intl.withLocale('en_US', () async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            habitsStreamProvider.overrideWith(
              (ref) => Stream.value([
                HabitModel(id: 'habit-1', title: 'Ler', completedDates: []),
              ]),
            ),
          ],
          child: const MaterialApp(home: HabitsScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(platform.locale, const Locale('en', 'US'));
      expect(Intl.getCurrentLocale(), 'en_US');
      expect(DateFormat('E').format(DateTime(2026, 8, 24)), 'Mon');

      final labels = tester
          .widgetList<Text>(
            find.descendant(
              of: find.byType(HabitsScreen),
              matching: find.byType(Text),
            ),
          )
          .map((text) => text.data)
          .where((text) => text?.length == 1)
          .toList();

      // Preserve the existing one-letter UI, ordered Monday through Sunday.
      expect(labels, ['S', 'T', 'Q', 'Q', 'S', 'S', 'D']);
      for (final englishInitial in ['M', 'W', 'F']) {
        expect(find.text(englishInitial), findsNothing);
      }
      expect(tester.takeException(), isNull);
    });
  });

  test('Portuguese weekday abbreviations preserve the Saturday accent', () {
    Intl.withLocale('en_US', () {
      final monday = DateTime(2026, 8, 24);
      final formatter = DateFormat('E', 'pt_BR');
      final abbreviations = List.generate(
        7,
        (index) => formatter.format(monday.add(Duration(days: index))),
      );

      // The screen intentionally displays only the initial of these labels.
      expect(abbreviations, [
        'seg.',
        'ter.',
        'qua.',
        'qui.',
        'sex.',
        's\u00e1b.',
        'dom.',
      ]);
    });
  });
}
