import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/features/health/data/models/health_model.dart';
import 'package:life_os/features/health/presentation/cycle/cycle_reminder_preferences.dart';
import 'package:life_os/features/health/presentation/cycle/cycle_reminder_section.dart';

class _TestPreferencesNotifier extends CycleReminderPreferencesNotifier {
  _TestPreferencesNotifier(this.value);

  final CycleReminderPreferences? value;

  @override
  Future<CycleReminderPreferences?> build() async => value;
}

CycleReminderPreferences _preferences(
  CycleReminderType type, {
  bool enabled = true,
  int hour = 21,
  int minute = 0,
  CycleReminderFrequency frequency = CycleReminderFrequency.daily,
  Set<int> weekdays = const <int>{},
}) {
  return CycleReminderPreferences(
    enabled: enabled,
    type: type,
    hour: hour,
    minute: minute,
    frequency: frequency,
    weekdays: weekdays,
  );
}

HealthModel _health({bool taken = false}) => HealthModel(
  mood: 'Neutro',
  waterIntakeMl: 0,
  hasTakenPillToday: taken,
  date: DateTime(2026, 8, 29),
);

void main() {
  Future<void> pumpSection(
    WidgetTester tester,
    CycleReminderPreferences? preferences, {
    HealthModel? health,
    Size size = const Size(800, 1000),
    double textScaleFactor = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          cycleReminderUserIdReaderProvider.overrideWithValue(() => 'user-a'),
          cycleReminderPreferencesProvider.overrideWith(
            () => _TestPreferencesNotifier(preferences),
          ),
        ],
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: MediaQuery(
            data: MediaQueryData(
              size: size,
              textScaler: TextScaler.linear(textScaleFactor),
            ),
            child: Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: CycleReminderSection(health: health ?? _health()),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> pumpEditor(
    WidgetTester tester, {
    Future<void> Function(CycleReminderPreferences value)? onSave,
    Size size = const Size(800, 1000),
    bool useDefaultTimePicker = false,
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
            timePicker: useDefaultTimePicker
                ? null
                : (_) async => const TimeOfDay(hour: 21, minute: 0),
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

  testWidgets('tipo selecionado possui estado semântico e check visível', (
    tester,
  ) async {
    await pumpEditor(tester);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Pílula'));
    await tester.pump();

    final chip = tester.widget<ChoiceChip>(
      find.widgetWithText(ChoiceChip, 'Pílula'),
    );
    expect(chip.selected, isTrue);
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
  });

  testWidgets('picker padrão usa 24 horas e ações em português', (
    tester,
  ) async {
    await pumpEditor(tester, useDefaultTimePicker: true);

    await tester.tap(find.text('Escolher horário'));
    await tester.pumpAndSettle();

    final picker = find.byType(TimePickerDialog);
    expect(picker, findsOneWidget);
    expect(MediaQuery.alwaysUse24HourFormatOf(tester.element(picker)), isTrue);
    expect(find.text('Escolha o horário do lembrete'), findsOneWidget);
    expect(find.text('Cancelar'), findsOneWidget);
    expect(find.text('OK'), findsOneWidget);
    expect(find.text('AM'), findsNothing);
    expect(find.text('PM'), findsNothing);
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

  testWidgets('sem configuração mostra estado vazio e CTA contextual', (
    tester,
  ) async {
    await pumpSection(tester, null);

    expect(find.text('ROTINA PESSOAL'), findsOneWidget);
    expect(find.text('Crie uma rotina pessoal'), findsOneWidget);
    expect(find.text('Configurar lembrete'), findsOneWidget);
    expect(find.text('Registrar pílula'), findsNothing);
  });

  testWidgets('pílula mostra rotina, estado e tracking diário integrado', (
    tester,
  ) async {
    await pumpSection(tester, _preferences(CycleReminderType.pill));

    expect(find.text('Pílula'), findsOneWidget);
    expect(find.text('21:00'), findsOneWidget);
    expect(find.text('Todos os dias'), findsOneWidget);
    expect(find.text('Lembrete ativo'), findsOneWidget);
    expect(find.text('Registrar pílula'), findsOneWidget);
    expect(find.text('Ajustar'), findsOneWidget);
  });

  testWidgets('notificações pausadas não escondem tracking da pílula', (
    tester,
  ) async {
    await pumpSection(
      tester,
      _preferences(CycleReminderType.pill, enabled: false),
    );

    expect(find.text('Notificações pausadas'), findsOneWidget);
    expect(find.text('Registrar pílula'), findsOneWidget);
  });

  testWidgets('pílula tomada mantém microinteração no card de rotina', (
    tester,
  ) async {
    await pumpSection(
      tester,
      _preferences(CycleReminderType.pill),
      health: _health(taken: true),
    );

    expect(find.text('Tomada hoje'), findsOneWidget);
    expect(find.text('Registrar pílula'), findsNothing);
    expect(find.byIcon(Icons.auto_awesome_rounded), findsWidgets);
  });

  for (final type in <CycleReminderType>[
    CycleReminderType.otherContraceptive,
    CycleReminderType.personal,
  ]) {
    testWidgets('${type.name} não apresenta conclusão diária falsa', (
      tester,
    ) async {
      await pumpSection(tester, _preferences(type));

      expect(
        find.text(
          type == CycleReminderType.personal
              ? 'Lembrete pessoal'
              : 'Outro contraceptivo',
        ),
        findsOneWidget,
      );
      expect(find.text('Ajustar'), findsOneWidget);
      expect(find.text('Registrar pílula'), findsNothing);
      expect(find.text('Tomada hoje'), findsNothing);
      expect(find.text('Tomei'), findsNothing);
      expect(find.text('Concluído'), findsNothing);
    });
  }

  testWidgets('frequência específica usa texto humano', (tester) async {
    await pumpSection(
      tester,
      _preferences(
        CycleReminderType.personal,
        frequency: CycleReminderFrequency.specificWeekdays,
        weekdays: const <int>{1, 3, 5},
      ),
    );

    expect(find.text('Seg, Qua e Sex'), findsOneWidget);
    expect(find.text('specificWeekdays'), findsNothing);
  });

  testWidgets('rotina é responsiva em tela compacta e texto ampliado', (
    tester,
  ) async {
    await pumpSection(
      tester,
      _preferences(
        CycleReminderType.otherContraceptive,
        frequency: CycleReminderFrequency.specificWeekdays,
        weekdays: const <int>{1, 2, 3, 4, 5, 6, 7},
      ),
      size: const Size(320, 568),
      textScaleFactor: 1.35,
    );

    expect(find.text('Outro contraceptivo'), findsOneWidget);
    expect(tester.takeException(), isNull);
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

    expect(find.text('Salvar lembrete'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
