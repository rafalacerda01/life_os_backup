import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:life_os/features/health/data/models/health_model.dart';
import 'package:life_os/features/health/presentation/cycle/cycle_health_screen.dart';
import 'package:life_os/features/health/presentation/cycle/cycle_reminder_preferences.dart';
import 'package:life_os/features/health/presentation/health_screen.dart';
import 'package:life_os/features/health/presentation/providers/health_provider.dart';
import 'package:life_os/features/premium/domain/services/plan_limits.dart';
import 'package:life_os/features/premium/presentation/plan_limits_provider.dart';

void main() {
  final current = DateTime.now();
  final now = DateTime(current.year, current.month, current.day, 12);

  HealthModel healthWithCycle({
    required bool enabled,
    DateTime? lastPeriodStart,
    String? rawLastPeriodStart,
    bool omitLastPeriodStart = false,
  }) {
    final menstrualCycle = <String, dynamic>{
      'isEnabled': enabled,
      'cycleLengthDays': 28,
      'periodLengthDays': 5,
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
  }) {
    return ProviderScope(
      overrides: [
        healthStreamProvider.overrideWith((ref) => Stream.value(health)),
        medicationsStreamProvider.overrideWith((ref) => Stream.value(const [])),
        planLimitsProvider.overrideWithValue(PlanLimits.free),
        cycleReminderUserIdProvider.overrideWith((ref) => Stream.value(null)),
      ],
      child: child,
    );
  }

  Future<void> pumpCycleScreen(
    WidgetTester tester,
    HealthModel health, {
    Size? size,
    double textScaleFactor = 1,
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
    expect(find.text('Próxima menstruação estimada'), findsNothing);
    expect(find.textContaining('Dia 0'), findsNothing);
  });

  testWidgets('ciclo desativado não apresenta previsão como ativa', (
    tester,
  ) async {
    await pumpCycleScreen(tester, healthWithCycle(enabled: false));

    expect(
      find.text('Acompanhamento desativado. Configure quando desejar.'),
      findsOneWidget,
    );
    expect(find.text('Próxima menstruação estimada'), findsNothing);
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
      expect(find.text('Próxima menstruação estimada'), findsNothing);
      expect(find.textContaining('Por volta de'), findsNothing);
    }
  });

  testWidgets('data futura não produz previsão válida', (tester) async {
    final futureDate = DateTime.now().add(const Duration(days: 3));
    final health = healthWithCycle(enabled: true, lastPeriodStart: futureDate);

    await pumpCycleScreen(tester, health);

    expect(find.text('Data inválida'), findsOneWidget);
    expect(find.textContaining('Dia 0'), findsNothing);
    expect(find.text('Próxima menstruação estimada'), findsNothing);
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

    expect(find.text('ESTADO ATUAL'), findsOneWidget);
    expect(find.text('Dia 4'), findsOneWidget);
    expect(
      find.text('${health.cyclePhaseInfo['name']} · estimativa'),
      findsOneWidget,
    );
    expect(find.text('Próxima menstruação estimada'), findsOneWidget);
    expect(find.text('Registros disponíveis'), findsOneWidget);
    expect(find.text('Radiante'), findsOneWidget);
    expect(find.text('1500 ml hoje'), findsOneWidget);
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

    expect(find.text('Configurar'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
