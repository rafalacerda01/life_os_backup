import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/features/health/presentation/cycle/cycle_reminder_preferences.dart';
import 'package:life_os/features/health/presentation/cycle/cycle_reminder_section.dart';

void main() {
  Future<void> pumpEditor(
    WidgetTester tester, {
    Future<void> Function(CycleReminderPreferences value)? onSave,
    Size size = const Size(800, 1000),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: CycleReminderEditor(
            timePicker: (_) async => const TimeOfDay(hour: 21, minute: 0),
            onSave: onSave ?? (_) async {},
          ),
        ),
      ),
    );
  }

  testWidgets('editor começa discreto e sem horário inferido', (tester) async {
    await pumpEditor(tester);

    expect(find.text('Escolher horário'), findsOneWidget);
    expect(find.text('Você tem um lembrete programado.'), findsOneWidget);
    expect(find.text('Horário do seu lembrete.'), findsNothing);
  });

  testWidgets('preview reflete Discreto, Informativo e Personalizado', (
    tester,
  ) async {
    Future<void> pumpPreview(CycleReminderPreview preview) {
      return tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: Center(child: preview)),
        ),
      );
    }

    await pumpPreview(
      const CycleReminderPreview(
        type: CycleReminderType.pill,
        privacyMode: CycleReminderPrivacyMode.discreet,
      ),
    );
    expect(find.text('Você tem um lembrete programado.'), findsOneWidget);

    await pumpPreview(
      const CycleReminderPreview(
        type: CycleReminderType.pill,
        privacyMode: CycleReminderPrivacyMode.informative,
      ),
    );
    expect(find.text('Lembrete de pílula'), findsOneWidget);
    expect(find.text('Horário do seu lembrete.'), findsOneWidget);

    await pumpPreview(
      const CycleReminderPreview(
        type: CycleReminderType.personal,
        privacyMode: CycleReminderPrivacyMode.custom,
        customTitle: 'Título privado',
        customBody: 'Mensagem privada',
      ),
    );
    expect(find.text('Título privado'), findsOneWidget);
    expect(find.text('Mensagem privada'), findsOneWidget);
  });

  testWidgets('salva somente após escolhas explícitas', (tester) async {
    CycleReminderPreferences? saved;
    await pumpEditor(tester, onSave: (value) async => saved = value);

    await tester.tap(find.text('Pílula'));
    await tester.tap(find.byKey(const ValueKey('cycle-reminder-time')));
    await tester.pump();
    await tester.tap(find.text('Diariamente'));
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('cycle-reminder-save')),
      300,
    );
    await tester.tap(find.byKey(const ValueKey('cycle-reminder-save')));
    await tester.pumpAndSettle();

    expect(saved?.type, CycleReminderType.pill);
    expect(saved?.hour, 21);
    expect(saved?.minute, 0);
    expect(saved?.frequency, CycleReminderFrequency.daily);
    expect(saved?.privacyMode, CycleReminderPrivacyMode.discreet);
  });

  testWidgets('dias específicos sem seleção mostra validação', (tester) async {
    await pumpEditor(tester);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Lembrete pessoal'));
    await tester.tap(find.byKey(const ValueKey('cycle-reminder-time')));
    await tester.pump();
    await tester.tap(find.text('Dias específicos'));
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('cycle-reminder-save')),
      300,
    );
    await tester.tap(find.byKey(const ValueKey('cycle-reminder-save')));
    await tester.pump();

    expect(find.text('Escolha pelo menos um dia da semana.'), findsOneWidget);
  });

  testWidgets('editor não gera overflow em layout compacto', (tester) async {
    await pumpEditor(tester, size: const Size(320, 568));

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('cycle-reminder-save')),
      300,
    );

    expect(find.text('Salvar'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
