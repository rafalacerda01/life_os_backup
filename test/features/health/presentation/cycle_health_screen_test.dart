import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:life_os/features/health/data/models/health_model.dart';
import 'package:life_os/features/health/data/repositories/health_repository.dart';
import 'package:life_os/features/health/presentation/cycle/cycle_health_screen.dart';
import 'package:life_os/features/health/presentation/cycle/cycle_reminder_preferences.dart';
import 'package:life_os/features/health/presentation/health_screen.dart';
import 'package:life_os/features/health/presentation/providers/health_provider.dart';
import 'package:life_os/features/premium/domain/services/plan_limits.dart';
import 'package:life_os/features/premium/presentation/plan_limits_provider.dart';

class _RecordingHealthRepository extends Fake implements HealthRepository {
  _RecordingHealthRepository({this.onToggle});

  final FutureOr<void> Function(bool enabled)? onToggle;
  final List<bool> toggleValues = [];
  final List<String> toggleExpectedUids = [];
  final List<Map<String, dynamic>> settingsValues = [];
  bool settingsResult = true;

  @override
  Future<bool> toggleMenstrualCycleFeature(
    bool enable, {
    required String expectedUid,
  }) async {
    toggleValues.add(enable);
    toggleExpectedUids.add(expectedUid);
    await onToggle?.call(enable);
    return true;
  }

  @override
  Future<bool> updateCycleSettings(
    Map<String, dynamic> cycleData, {
    required String expectedUid,
  }) async {
    settingsValues.add(Map<String, dynamic>.from(cycleData));
    return settingsResult;
  }
}

class _ReplayHealthStream {
  _ReplayHealthStream(this.current);

  HealthModel current;
  final StreamController<HealthModel> _controller =
      StreamController<HealthModel>.broadcast();

  Stream<HealthModel> create() async* {
    yield current;
    yield* _controller.stream;
  }

  void add(HealthModel health) {
    current = health;
    _controller.add(health);
  }

  Future<void> close() => _controller.close();
}

class _StaticCycleReminderPreferencesNotifier
    extends CycleReminderPreferencesNotifier {
  _StaticCycleReminderPreferencesNotifier(this.preferences);

  final CycleReminderPreferences preferences;

  @override
  Future<CycleReminderPreferences?> build() async => preferences;
}

void main() {
  final current = DateTime.now();
  final now = DateTime(current.year, current.month, current.day, 12);

  HealthModel healthWithCycle({
    required bool enabled,
    DateTime? lastPeriodStart,
    String? rawLastPeriodStart,
    bool omitLastPeriodStart = false,
    int cycleLengthDays = 28,
    int periodLengthDays = 5,
  }) {
    final menstrualCycle = <String, dynamic>{
      'isEnabled': enabled,
      'cycleLengthDays': cycleLengthDays,
      'periodLengthDays': periodLengthDays,
    };
    if (!omitLastPeriodStart) {
      menstrualCycle['lastPeriodStart'] =
          rawLastPeriodStart ??
          (lastPeriodStart ?? DateTime.now()).toIso8601String();
    }

    return HealthModel(
      mood: 'Radiante',
      waterIntakeMl: 1500,
      hasTakenPillToday: false,
      menstrualCycle: menstrualCycle,
      date: now,
    );
  }

  Widget withHealthOverrides({
    required HealthModel health,
    required Widget child,
    HealthRepository? repository,
    String? admittedUid = 'user-a',
    Stream<HealthModel> Function()? healthStreamFactory,
    CycleReminderPreferences? reminderPreferences,
  }) {
    return ProviderScope(
      overrides: [
        healthStreamProvider.overrideWith(
          (ref) => healthStreamFactory?.call() ?? Stream.value(health),
        ),
        if (repository != null)
          healthRepositoryProvider.overrideWithValue(repository),
        medicationsStreamProvider.overrideWith((ref) => Stream.value(const [])),
        planLimitsProvider.overrideWithValue(PlanLimits.free),
        cycleReminderUserIdProvider.overrideWith((ref) => Stream.value(null)),
        cycleReminderUserIdReaderProvider.overrideWithValue(() => admittedUid),
        cyclePillTrackingVisibleProvider.overrideWithValue(false),
        if (reminderPreferences != null)
          cycleReminderPreferencesProvider.overrideWith(
            () => _StaticCycleReminderPreferencesNotifier(reminderPreferences),
          ),
      ],
      child: child,
    );
  }

  Future<void> pumpCycleScreen(
    WidgetTester tester,
    HealthModel health, {
    Size? size,
    double textScaleFactor = 1,
    HealthRepository? repository,
    String? admittedUid = 'user-a',
    Stream<HealthModel> Function()? healthStreamFactory,
    CycleReminderPreferences? reminderPreferences,
  }) async {
    if (size != null) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    await tester.pumpWidget(
      withHealthOverrides(
        health: health,
        repository: repository,
        admittedUid: admittedUid,
        healthStreamFactory: healthStreamFactory,
        reminderPreferences: reminderPreferences,
        child: MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: size ?? const Size(800, 1200),
              textScaler: TextScaler.linear(textScaleFactor),
            ),
            child: CycleHealthScreen(clock: () => now),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openCycleSettings(
    WidgetTester tester,
    HealthModel health,
    _RecordingHealthRepository repository,
  ) async {
    await pumpCycleScreen(tester, health, repository: repository);
    await tester.tap(find.byKey(const ValueKey('cycle-configure-action')));
    await tester.pumpAndSettle();
    expect(find.text('Configurar ciclo'), findsWidgets);
  }

  Future<void> submitCycleDurations(
    WidgetTester tester, {
    required String cycle,
    required String period,
  }) async {
    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(2));
    await tester.enterText(fields.at(0), cycle);
    await tester.enterText(fields.at(1), period);
    await tester.tap(find.widgetWithText(ElevatedButton, 'Salvar'));
    await tester.pumpAndSettle();
  }

  testWidgets('Health mostra card e navega para /health/cycle', (tester) async {
    final health = HealthModel(
      mood: 'Neutro',
      waterIntakeMl: 0,
      hasTakenPillToday: false,
      date: now,
    );
    final router = GoRouter(
      initialLocation: '/health',
      routes: [
        GoRoute(path: '/health', builder: (_, _) => const HealthScreen()),
        GoRoute(
          path: '/health/cycle',
          builder: (_, _) => const Scaffold(
            body: Center(child: Text('Destino Saúde do ciclo')),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      withHealthOverrides(
        health: health,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('cycle-health-summary-card')),
      300,
    );

    expect(find.text('Saúde do ciclo'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('cycle-health-summary-card')));
    await tester.pumpAndSettle();

    expect(find.text('Destino Saúde do ciclo'), findsOneWidget);
  });

  testWidgets('configuração válida 28 e 5 chega ao repository', (tester) async {
    final repository = _RecordingHealthRepository()..settingsResult = false;
    await openCycleSettings(tester, healthWithCycle(enabled: true), repository);

    await submitCycleDurations(tester, cycle: '28', period: '5');

    expect(repository.settingsValues, hasLength(1));
    expect(repository.settingsValues.single['cycleLengthDays'], 28);
    expect(repository.settingsValues.single['periodLengthDays'], 5);
  });

  testWidgets('limite mínimo 1 e 1 chega ao repository', (tester) async {
    final repository = _RecordingHealthRepository()..settingsResult = false;
    await openCycleSettings(tester, healthWithCycle(enabled: true), repository);

    await submitCycleDurations(tester, cycle: '1', period: '1');

    expect(repository.settingsValues, hasLength(1));
    expect(repository.settingsValues.single['cycleLengthDays'], 1);
    expect(repository.settingsValues.single['periodLengthDays'], 1);
  });

  testWidgets('limite máximo 120 chega ao repository', (tester) async {
    final repository = _RecordingHealthRepository()..settingsResult = false;
    await openCycleSettings(tester, healthWithCycle(enabled: true), repository);

    await submitCycleDurations(tester, cycle: '120', period: '120');

    expect(repository.settingsValues, hasLength(1));
    expect(repository.settingsValues.single['cycleLengthDays'], 120);
    expect(repository.settingsValues.single['periodLengthDays'], 120);
  });

  testWidgets('ciclo 121 é rejeitado na UI sem chamar repository', (
    tester,
  ) async {
    final repository = _RecordingHealthRepository();
    await openCycleSettings(tester, healthWithCycle(enabled: true), repository);

    await submitCycleDurations(tester, cycle: '121', period: '5');

    expect(repository.settingsValues, isEmpty);
    expect(find.text('O ciclo deve ter no máximo 120 dias.'), findsOneWidget);
  });

  testWidgets('ciclo 150 é rejeitado sem clamp silencioso', (tester) async {
    final repository = _RecordingHealthRepository();
    await openCycleSettings(tester, healthWithCycle(enabled: true), repository);

    await submitCycleDurations(tester, cycle: '150', period: '5');

    expect(repository.settingsValues, isEmpty);
    expect(find.text('O ciclo deve ter no máximo 120 dias.'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField).at(0)).controller?.text,
      '150',
    );
  });

  testWidgets('ciclo zero é rejeitado como duração inválida', (tester) async {
    final repository = _RecordingHealthRepository();
    await openCycleSettings(tester, healthWithCycle(enabled: true), repository);

    await submitCycleDurations(tester, cycle: '0', period: '1');

    expect(repository.settingsValues, isEmpty);
    expect(find.text('Informe uma duração de ciclo válida.'), findsOneWidget);
  });

  testWidgets('ciclo não numérico é rejeitado', (tester) async {
    final repository = _RecordingHealthRepository();
    await openCycleSettings(tester, healthWithCycle(enabled: true), repository);

    await submitCycleDurations(tester, cycle: 'abc', period: '1');

    expect(repository.settingsValues, isEmpty);
    expect(find.text('Informe uma duração de ciclo válida.'), findsOneWidget);
  });

  testWidgets('período zero é rejeitado', (tester) async {
    final repository = _RecordingHealthRepository();
    await openCycleSettings(tester, healthWithCycle(enabled: true), repository);

    await submitCycleDurations(tester, cycle: '28', period: '0');

    expect(repository.settingsValues, isEmpty);
    expect(
      find.text('Informe uma duração de menstruação válida.'),
      findsOneWidget,
    );
  });

  testWidgets('período maior que ciclo é rejeitado', (tester) async {
    final repository = _RecordingHealthRepository();
    await openCycleSettings(tester, healthWithCycle(enabled: true), repository);

    await submitCycleDurations(tester, cycle: '28', period: '29');

    expect(repository.settingsValues, isEmpty);
    expect(
      find.text('A menstruação não pode ser maior que o ciclo.'),
      findsOneWidget,
    );
  });

  testWidgets('cancelar configuração não produz mutação', (tester) async {
    final repository = _RecordingHealthRepository();
    await openCycleSettings(tester, healthWithCycle(enabled: true), repository);

    await tester.tap(find.widgetWithText(TextButton, 'Cancelar'));

    expect(repository.settingsValues, isEmpty);
  });

  testWidgets('primeira configuração mantém defaults 28 e 5', (tester) async {
    final repository = _RecordingHealthRepository();
    final emptyHealth = HealthModel(
      mood: '—',
      waterIntakeMl: 0,
      hasTakenPillToday: false,
      date: now,
    );
    await openCycleSettings(tester, emptyHealth, repository);

    final fields = find.byType(TextField);
    expect(tester.widget<TextField>(fields.at(0)).controller?.text, '28');
    expect(tester.widget<TextField>(fields.at(1)).controller?.text, '5');
    expect(repository.settingsValues, isEmpty);
  });

  testWidgets('configuração existente preserva valores sem alteração', (
    tester,
  ) async {
    final repository = _RecordingHealthRepository();
    await openCycleSettings(
      tester,
      healthWithCycle(enabled: true, cycleLengthDays: 35, periodLengthDays: 7),
      repository,
    );

    final fields = find.byType(TextField);
    expect(tester.widget<TextField>(fields.at(0)).controller?.text, '35');
    expect(tester.widget<TextField>(fields.at(1)).controller?.text, '7');
    expect(repository.settingsValues, isEmpty);
  });

  testWidgets('sem dados mostra estado vazio sem estimativa falsa', (
    tester,
  ) async {
    await pumpCycleScreen(
      tester,
      HealthModel(
        mood: '—',
        waterIntakeMl: 0,
        hasTakenPillToday: false,
        date: now,
      ),
    );

    expect(
      find.text('Configure para acompanhar estimativas e registros.'),
      findsOneWidget,
    );
    expect(find.text('Próxima menstruação'), findsNothing);
    expect(find.textContaining('Dia 0'), findsNothing);
  });

  testWidgets('ciclo desativado não apresenta previsão como ativa', (
    tester,
  ) async {
    await pumpCycleScreen(tester, healthWithCycle(enabled: false));

    expect(find.text('Acompanhamento pausado'), findsOneWidget);
    expect(find.text('Ativar acompanhamento'), findsOneWidget);
    expect(find.text('Próxima menstruação'), findsNothing);
    expect(find.textContaining('Por volta de'), findsNothing);
  });

  testWidgets('card não apresenta estimativa com configuração incompleta', (
    tester,
  ) async {
    final health = healthWithCycle(enabled: true, omitLastPeriodStart: true);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CycleHealthSummaryCard(health: health, onTap: () {}),
        ),
      ),
    );

    expect(
      find.text('Complete a configuração para gerar estimativas.'),
      findsOneWidget,
    );
    expect(find.textContaining('Estimativa: dia'), findsNothing);
    expect(
      find.text('Estimativa baseada nos dados registrados.'),
      findsNothing,
    );
  });

  testWidgets('data ausente ou malformada não produz Dia 0 nem previsão', (
    tester,
  ) async {
    for (final health in [
      healthWithCycle(enabled: true, omitLastPeriodStart: true),
      healthWithCycle(enabled: true, rawLastPeriodStart: 'data-invalida'),
    ]) {
      await pumpCycleScreen(tester, health);

      expect(find.text('Ciclo não configurado'), findsOneWidget);
      expect(find.textContaining('Dia 0'), findsNothing);
      expect(find.text('Próxima menstruação'), findsNothing);
      expect(find.textContaining('Por volta de'), findsNothing);
    }
  });

  testWidgets('data futura não produz previsão válida', (tester) async {
    final futureDate = DateTime.now().add(const Duration(days: 3));
    final health = healthWithCycle(enabled: true, lastPeriodStart: futureDate);

    await pumpCycleScreen(tester, health);

    expect(find.text('Data inválida'), findsOneWidget);
    expect(find.textContaining('Dia 0'), findsNothing);
    expect(find.text('Próxima menstruação'), findsNothing);
    expect(find.textContaining('Por volta de'), findsNothing);
    expect(estimatedNextPeriodDate(health, now), isNull);
  });

  testWidgets('ciclo ativo apresenta somente dados e estimativas existentes', (
    tester,
  ) async {
    final today = DateTime.now();
    final health = healthWithCycle(
      enabled: true,
      lastPeriodStart: DateTime(
        today.year,
        today.month,
        today.day,
      ).subtract(const Duration(days: 3)),
    );
    await pumpCycleScreen(tester, health);

    expect(find.text('SEU CICLO HOJE'), findsOneWidget);
    expect(find.text('Dia 4'), findsOneWidget);
    expect(
      find.text('${health.cyclePhaseInfo['name']} · estimativa'),
      findsOneWidget,
    );
    expect(find.text('Próxima menstruação'), findsOneWidget);
    expect(find.text('SUGESTÃO DO DIA'), findsOneWidget);
    expect(find.text('INSIGHT DO DIA'), findsNothing);
    expect(find.text('Duração do ciclo'), findsOneWidget);
    expect(find.text('Duração do período'), findsOneWidget);
    expect(find.text('Registros disponíveis'), findsNothing);
    expect(find.text('Radiante'), findsNothing);
    expect(find.text('1500 ml hoje'), findsNothing);
    expect(find.text('ROTINA PESSOAL'), findsOneWidget);
    expect(find.text('Crie uma rotina pessoal'), findsOneWidget);
  });

  testWidgets('tracking da pílula aparece uma vez dentro da rotina pessoal', (
    tester,
  ) async {
    await pumpCycleScreen(
      tester,
      healthWithCycle(enabled: true),
      reminderPreferences: CycleReminderPreferences(
        enabled: true,
        type: CycleReminderType.pill,
        hour: 21,
        minute: 0,
        frequency: CycleReminderFrequency.daily,
      ),
    );

    expect(find.text('ROTINA PESSOAL'), findsOneWidget);
    expect(find.text('Pílula'), findsOneWidget);
    expect(find.text('Registrar pílula'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('cycle-pill-daily-control')),
      findsOneWidget,
    );
  });

  testWidgets('linguagem é cautelosa e inclui disclaimer', (tester) async {
    await pumpCycleScreen(tester, healthWithCycle(enabled: true));

    expect(find.textContaining('estimativa'), findsWidgets);
    expect(find.textContaining('pode variar'), findsWidgets);
    expect(find.textContaining('Você vai menstruar'), findsNothing);
    expect(
      find.textContaining('Elas não substituem orientação médica.'),
      findsOneWidget,
    );
  });

  testWidgets(
    'hero não desativa e fluxo explícito converge para pausa e reativação',
    (tester) async {
      final activeHealth = healthWithCycle(enabled: true);
      final pausedHealth = healthWithCycle(enabled: false);
      final healthStream = _ReplayHealthStream(activeHealth);
      addTearDown(healthStream.close);
      final repository = _RecordingHealthRepository(
        onToggle: (enabled) {
          healthStream.add(enabled ? activeHealth : pausedHealth);
        },
      );

      await pumpCycleScreen(
        tester,
        activeHealth,
        repository: repository,
        healthStreamFactory: healthStream.create,
      );

      expect(find.byIcon(Icons.power_settings_new_rounded), findsNothing);
      await tester.tap(find.byKey(const ValueKey('cycle-hero-card')));
      await tester.pump();
      expect(repository.toggleValues, isEmpty);

      await tester.tap(find.byKey(const ValueKey('cycle-configure-action')));
      await tester.pumpAndSettle();
      expect(find.text('Configurar ciclo'), findsWidgets);
      expect(find.text('Desativar acompanhamento?'), findsNothing);

      await tester.ensureVisible(
        find.byKey(const ValueKey('cycle-deactivate-action')),
      );
      await tester.tap(find.byKey(const ValueKey('cycle-deactivate-action')));
      await tester.pumpAndSettle();
      expect(find.text('Desativar acompanhamento?'), findsOneWidget);
      expect(repository.toggleValues, isEmpty);

      await tester.tap(find.byKey(const ValueKey('cycle-deactivate-cancel')));
      await tester.pumpAndSettle();
      expect(repository.toggleValues, isEmpty);

      await tester.tap(find.byKey(const ValueKey('cycle-deactivate-action')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('cycle-deactivate-confirm')));
      await tester.pumpAndSettle();

      expect(repository.toggleValues, [false]);
      expect(repository.toggleExpectedUids, ['user-a']);

      expect(find.byKey(const ValueKey('cycle-paused-state')), findsOneWidget);
      expect(find.text('Acompanhamento pausado'), findsOneWidget);
      expect(
        find.textContaining('Seus dados continuam salvos.'),
        findsOneWidget,
      );
      expect(find.text('Ativar acompanhamento'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('cycle-reactivate-action')));
      await tester.pumpAndSettle();

      expect(repository.toggleValues, [false, true]);
      expect(repository.toggleExpectedUids, ['user-a', 'user-a']);
      expect(find.byKey(const ValueKey('cycle-hero-card')), findsOneWidget);
    },
  );

  testWidgets('enabled sem data pode cancelar desativação sem mutação', (
    tester,
  ) async {
    final repository = _RecordingHealthRepository();
    final enabledHealth = healthWithCycle(
      enabled: true,
      omitLastPeriodStart: true,
    );

    await pumpCycleScreen(tester, enabledHealth, repository: repository);
    await tester.tap(find.byKey(const ValueKey('cycle-configure-action')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('cycle-deactivate-action')),
    );
    await tester.tap(find.byKey(const ValueKey('cycle-deactivate-action')));
    await tester.pumpAndSettle();

    expect(find.text('Desativar acompanhamento?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('cycle-deactivate-cancel')));
    await tester.pumpAndSettle();

    expect(repository.toggleValues, isEmpty);
    expect(find.byKey(const ValueKey('cycle-setup-state')), findsOneWidget);
  });

  testWidgets('enabled com data inválida pode confirmar desativação', (
    tester,
  ) async {
    final activeHealth = healthWithCycle(
      enabled: true,
      rawLastPeriodStart: 'not-a-date',
    );
    final pausedHealth = healthWithCycle(
      enabled: false,
      rawLastPeriodStart: 'not-a-date',
    );
    final healthStream = _ReplayHealthStream(activeHealth);
    addTearDown(healthStream.close);
    final repository = _RecordingHealthRepository(
      onToggle: (enabled) {
        if (!enabled) healthStream.add(pausedHealth);
      },
    );

    await pumpCycleScreen(
      tester,
      activeHealth,
      repository: repository,
      healthStreamFactory: healthStream.create,
    );
    await tester.tap(find.byKey(const ValueKey('cycle-configure-action')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('cycle-deactivate-action')),
    );
    await tester.tap(find.byKey(const ValueKey('cycle-deactivate-action')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('cycle-deactivate-confirm')));
    await tester.pumpAndSettle();

    expect(repository.toggleValues, [false]);
    expect(repository.toggleExpectedUids, ['user-a']);
    expect(find.byKey(const ValueKey('cycle-paused-state')), findsOneWidget);
  });

  testWidgets('enabled com duração inválida mantém desativação disponível', (
    tester,
  ) async {
    final repository = _RecordingHealthRepository();
    final enabledHealth = healthWithCycle(
      enabled: true,
      cycleLengthDays: 0,
      periodLengthDays: 999,
    );

    await pumpCycleScreen(tester, enabledHealth, repository: repository);
    await tester.tap(find.byKey(const ValueKey('cycle-configure-action')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('cycle-deactivate-action')),
    );

    expect(
      find.byKey(const ValueKey('cycle-deactivate-action')),
      findsOneWidget,
    );
    expect(repository.toggleValues, isEmpty);
  });

  testWidgets('reativação sem data abre configuração sem mutação', (
    tester,
  ) async {
    final repository = _RecordingHealthRepository();
    final pausedHealth = healthWithCycle(
      enabled: false,
      omitLastPeriodStart: true,
    );

    await pumpCycleScreen(tester, pausedHealth, repository: repository);
    await tester.tap(find.byKey(const ValueKey('cycle-reactivate-action')));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Configurar ciclo'), findsWidgets);
    expect(repository.toggleValues, isEmpty);
    expect(repository.settingsValues, isEmpty);
  });

  testWidgets(
    'reativação com data inválida abre configuração sem inventar data',
    (tester) async {
      final repository = _RecordingHealthRepository();
      final pausedHealth = healthWithCycle(
        enabled: false,
        rawLastPeriodStart: 'not-a-date',
      );

      await pumpCycleScreen(tester, pausedHealth, repository: repository);
      await tester.tap(find.byKey(const ValueKey('cycle-reactivate-action')));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Configurar ciclo'), findsWidgets);
      expect(repository.toggleValues, isEmpty);
      expect(repository.settingsValues, isEmpty);
    },
  );

  testWidgets('layout compacto com fonte ampliada não gera overflow', (
    tester,
  ) async {
    await pumpCycleScreen(
      tester,
      healthWithCycle(enabled: true),
      size: const Size(320, 568),
      textScaleFactor: 1.3,
    );

    expect(find.text('Saúde do ciclo'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('estado vazio também é responsivo em tela compacta', (
    tester,
  ) async {
    await pumpCycleScreen(
      tester,
      HealthModel(
        mood: '—',
        waterIntakeMl: 0,
        hasTakenPillToday: false,
        date: now,
      ),
      size: const Size(320, 568),
      textScaleFactor: 1.3,
    );

    expect(find.text('Configurar ciclo'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mount e resume atualizam o stream diário com segurança', (
    tester,
  ) async {
    var currentTime = DateTime(2026, 8, 29, 23, 50);
    var streamBuilds = 0;
    final health = healthWithCycle(enabled: true);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          healthStreamProvider.overrideWith((ref) {
            streamBuilds += 1;
            return Stream.value(health);
          }),
          medicationsStreamProvider.overrideWith(
            (ref) => Stream.value(const []),
          ),
          planLimitsProvider.overrideWithValue(PlanLimits.free),
          cycleReminderUserIdProvider.overrideWith((ref) => Stream.value(null)),
          cycleReminderUserIdReaderProvider.overrideWithValue(() => 'user-a'),
          cyclePillTrackingVisibleProvider.overrideWithValue(false),
        ],
        child: MaterialApp(home: CycleHealthScreen(clock: () => currentTime)),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(streamBuilds, 1);

    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(streamBuilds, 2);

    await tester.pumpAndSettle();
    final initialBuilds = streamBuilds;

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(streamBuilds, initialBuilds);

    currentTime = DateTime(2026, 8, 30, 8);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(streamBuilds, initialBuilds + 1);
  });
}
