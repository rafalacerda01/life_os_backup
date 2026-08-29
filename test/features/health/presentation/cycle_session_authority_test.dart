import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/features/health/data/models/health_model.dart';
import 'package:life_os/features/health/data/repositories/health_repository.dart';
import 'package:life_os/features/health/presentation/cycle/cycle_reminder_preferences.dart';
import 'package:life_os/features/health/presentation/health_screen.dart';
import 'package:life_os/features/health/presentation/providers/health_provider.dart';

class _RecordingHealthRepository extends Fake implements HealthRepository {
  String activeUid = 'user-a';
  int settingsCalls = 0;
  int toggleCalls = 0;
  int pillCalls = 0;
  String? settingsExpectedUid;
  String? toggleExpectedUid;
  String? pillExpectedUid;

  bool _accepts(String expectedUid) => expectedUid == activeUid;

  @override
  Future<bool> updateCycleSettings(
    Map<String, dynamic> cycleData, {
    required String expectedUid,
  }) async {
    settingsCalls += 1;
    settingsExpectedUid = expectedUid;
    return _accepts(expectedUid);
  }

  @override
  Future<bool> toggleMenstrualCycleFeature(
    bool enable, {
    required String expectedUid,
  }) async {
    toggleCalls += 1;
    toggleExpectedUid = expectedUid;
    return _accepts(expectedUid);
  }

  @override
  Future<bool> updatePillStatus(
    bool taken, {
    required String expectedUid,
  }) async {
    pillCalls += 1;
    pillExpectedUid = expectedUid;
    return _accepts(expectedUid);
  }
}

void main() {
  late _RecordingHealthRepository repository;
  String? admittedUid;

  final today = DateTime.now();
  final health = HealthModel(
    mood: 'Neutro',
    waterIntakeMl: 0,
    hasTakenPillToday: false,
    menstrualCycle: <String, dynamic>{
      'isEnabled': true,
      'lastPeriodStart': DateTime(
        today.year,
        today.month,
        today.day,
      ).toIso8601String(),
      'cycleLengthDays': 28,
      'periodLengthDays': 5,
    },
    date: today,
  );

  Future<void> pumpDetails(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          healthRepositoryProvider.overrideWithValue(repository),
          cycleReminderUserIdReaderProvider.overrideWithValue(
            () => admittedUid,
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CycleHealthDetails(health: health),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  setUp(() {
    repository = _RecordingHealthRepository();
    admittedUid = 'user-a';
  });

  testWidgets('sessão A estável fornece expectedUid às mutações diretas', (
    tester,
  ) async {
    await pumpDetails(tester);

    await tester.tap(find.text('Registrar'));
    await tester.pump();
    await tester.tap(find.byTooltip('Desativar ciclo'));
    await tester.pump();

    expect(repository.pillCalls, 1);
    expect(repository.pillExpectedUid, 'user-a');
    expect(repository.toggleCalls, 1);
    expect(repository.toggleExpectedUid, 'user-a');
    expect(find.textContaining('Não foi possível'), findsNothing);
  });

  testWidgets('authority null rejeita antes de chamar repository', (
    tester,
  ) async {
    admittedUid = null;
    await pumpDetails(tester);

    await tester.tap(find.text('Registrar'));
    await tester.pump();

    expect(repository.pillCalls, 0);
    expect(find.text('Não foi possível atualizar o status.'), findsOneWidget);
  });

  testWidgets('callback antigo A não adota B para pill ou toggle', (
    tester,
  ) async {
    await pumpDetails(tester);
    admittedUid = 'user-b';
    repository.activeUid = 'user-b';

    await tester.tap(find.text('Registrar'));
    await tester.pump();
    await tester.tap(find.byTooltip('Desativar ciclo'));
    await tester.pump();

    expect(repository.pillExpectedUid, 'user-a');
    expect(repository.toggleExpectedUid, 'user-a');
    expect(find.text('Não foi possível desativar o ciclo.'), findsOneWidget);
  });

  testWidgets('dialog antigo A não salva em B nem informa sucesso', (
    tester,
  ) async {
    await pumpDetails(tester);
    await tester.tap(find.byTooltip('Configurar ciclo'));
    await tester.pumpAndSettle();

    admittedUid = 'user-b';
    repository.activeUid = 'user-b';
    await tester.tap(find.widgetWithText(ElevatedButton, 'Salvar'));
    await tester.pump();

    expect(repository.settingsCalls, 1);
    expect(repository.settingsExpectedUid, 'user-a');
    expect(find.text('Configuração do ciclo atualizada.'), findsNothing);
    expect(
      find.text('Não foi possível salvar a configuração.'),
      findsOneWidget,
    );
    expect(find.text('Configurar ciclo'), findsOneWidget);
  });
}
