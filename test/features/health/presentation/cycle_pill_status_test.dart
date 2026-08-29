import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/features/health/data/models/health_model.dart';
import 'package:life_os/features/health/data/repositories/health_repository.dart';
import 'package:life_os/features/health/presentation/cycle/cycle_reminder_preferences.dart';
import 'package:life_os/features/health/presentation/health_screen.dart';
import 'package:life_os/features/health/presentation/providers/health_provider.dart';

class _TestPreferencesNotifier extends CycleReminderPreferencesNotifier {
  _TestPreferencesNotifier(this.initialValue);

  final CycleReminderPreferences? initialValue;

  @override
  Future<CycleReminderPreferences?> build() async => initialValue;

  void replace(CycleReminderPreferences? value) {
    state = AsyncData(value);
  }

  void setLoading() {
    state = const AsyncLoading();
  }

  void setError() {
    state = AsyncError(StateError('TEST_ERROR'), StackTrace.empty);
  }
}

class _RecordingHealthRepository extends Fake implements HealthRepository {
  bool result = true;
  bool shouldThrow = false;
  final List<bool> values = <bool>[];
  final List<String> expectedUids = <String>[];
  FutureOr<void> Function(bool value)? onSuccess;

  @override
  Future<bool> updatePillStatus(
    bool taken, {
    required String expectedUid,
  }) async {
    values.add(taken);
    expectedUids.add(expectedUid);
    if (shouldThrow) throw StateError('TEST_FAILURE');
    if (!result) return false;
    await onSuccess?.call(taken);
    return true;
  }
}

CycleReminderPreferences _preferences(
  CycleReminderType type, {
  bool enabled = true,
}) {
  return CycleReminderPreferences(
    enabled: enabled,
    type: type,
    hour: 16,
    minute: 35,
    frequency: CycleReminderFrequency.daily,
  );
}

HealthModel _health({required bool taken}) {
  final now = DateTime.now();
  return HealthModel(
    mood: 'Tranquilo',
    waterIntakeMl: 1200,
    hasTakenPillToday: taken,
    menstrualCycle: <String, dynamic>{
      'isEnabled': true,
      'lastPeriodStart': DateTime(
        now.year,
        now.month,
        now.day,
      ).toIso8601String(),
      'cycleLengthDays': 28,
      'periodLengthDays': 5,
    },
    date: now,
  );
}

void main() {
  Future<void> pumpStatus(
    WidgetTester tester, {
    required _TestPreferencesNotifier preferencesNotifier,
    required _RecordingHealthRepository repository,
    required ValueNotifier<HealthModel> health,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          healthRepositoryProvider.overrideWithValue(repository),
          cycleReminderUserIdReaderProvider.overrideWithValue(() => 'user-a'),
          cycleReminderPreferencesProvider.overrideWith(
            () => preferencesNotifier,
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<HealthModel>(
              valueListenable: health,
              builder: (context, value, child) => SingleChildScrollView(
                child: CycleHealthDetails(
                  health: value,
                  presentation: CycleHealthDetailsPresentation.dedicated,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final hiddenCase in <(String, CycleReminderPreferences?)>[
    ('sem preferência', null),
    ('outro contraceptivo', _preferences(CycleReminderType.otherContraceptive)),
    ('lembrete pessoal', _preferences(CycleReminderType.personal)),
  ]) {
    testWidgets('${hiddenCase.$1} não mostra tracking da pílula', (
      tester,
    ) async {
      final health = ValueNotifier<HealthModel>(_health(taken: false));
      addTearDown(health.dispose);

      await pumpStatus(
        tester,
        preferencesNotifier: _TestPreferencesNotifier(hiddenCase.$2),
        repository: _RecordingHealthRepository(),
        health: health,
      );

      expect(find.text('Registrar pílula'), findsNothing);
      expect(find.text('Tomada hoje'), findsNothing);
    });
  }

  testWidgets('tipo pílula mostra tracking mesmo com reminder desabilitado', (
    tester,
  ) async {
    final health = ValueNotifier<HealthModel>(_health(taken: false));
    addTearDown(health.dispose);

    await pumpStatus(
      tester,
      preferencesNotifier: _TestPreferencesNotifier(
        _preferences(CycleReminderType.pill, enabled: false),
      ),
      repository: _RecordingHealthRepository(),
      health: health,
    );

    expect(find.text('Registrar pílula'), findsOneWidget);
  });

  testWidgets('loading e erro de preferências escondem tracking fail-safe', (
    tester,
  ) async {
    final health = ValueNotifier<HealthModel>(_health(taken: false));
    addTearDown(health.dispose);
    final preferencesNotifier = _TestPreferencesNotifier(
      _preferences(CycleReminderType.pill),
    );

    await pumpStatus(
      tester,
      preferencesNotifier: preferencesNotifier,
      repository: _RecordingHealthRepository(),
      health: health,
    );
    expect(find.text('Registrar pílula'), findsOneWidget);

    preferencesNotifier.setLoading();
    await tester.pump();
    expect(find.text('Registrar pílula'), findsNothing);

    preferencesNotifier.setError();
    await tester.pump();
    expect(find.text('Registrar pílula'), findsNothing);
  });

  testWidgets('sucesso persistido troca Registrar por Tomada hoje', (
    tester,
  ) async {
    final health = ValueNotifier<HealthModel>(_health(taken: false));
    addTearDown(health.dispose);
    final repository = _RecordingHealthRepository()
      ..onSuccess = (value) => health.value = _health(taken: value);

    await pumpStatus(
      tester,
      preferencesNotifier: _TestPreferencesNotifier(
        _preferences(CycleReminderType.pill),
      ),
      repository: repository,
      health: health,
    );

    await tester.tap(find.text('Registrar pílula'));
    await tester.pumpAndSettle();

    expect(repository.values, [true]);
    expect(repository.expectedUids, ['user-a']);
    expect(find.text('Tomada hoje'), findsOneWidget);
    expect(find.byIcon(Icons.auto_awesome_rounded), findsWidgets);
  });

  testWidgets('falha de persistência mantém Registrar pílula', (tester) async {
    final health = ValueNotifier<HealthModel>(_health(taken: false));
    addTearDown(health.dispose);
    final repository = _RecordingHealthRepository()..result = false;

    await pumpStatus(
      tester,
      preferencesNotifier: _TestPreferencesNotifier(
        _preferences(CycleReminderType.pill),
      ),
      repository: repository,
      health: health,
    );

    await tester.tap(find.text('Registrar pílula'));
    await tester.pumpAndSettle();

    expect(find.text('Registrar pílula'), findsOneWidget);
    expect(find.text('Tomada hoje'), findsNothing);
    expect(find.text('Não foi possível atualizar o status.'), findsOneWidget);
  });

  testWidgets('exceção do repository não produz sucesso visual', (
    tester,
  ) async {
    final health = ValueNotifier<HealthModel>(_health(taken: false));
    addTearDown(health.dispose);
    final repository = _RecordingHealthRepository()..shouldThrow = true;

    await pumpStatus(
      tester,
      preferencesNotifier: _TestPreferencesNotifier(
        _preferences(CycleReminderType.pill),
      ),
      repository: repository,
      health: health,
    );

    await tester.tap(find.text('Registrar pílula'));
    await tester.pumpAndSettle();

    expect(find.text('Registrar pílula'), findsOneWidget);
    expect(find.text('Tomada hoje'), findsNothing);
    expect(find.text('Não foi possível atualizar o status.'), findsOneWidget);
  });

  testWidgets('estado concluído exige confirmação para desmarcar', (
    tester,
  ) async {
    final health = ValueNotifier<HealthModel>(_health(taken: true));
    addTearDown(health.dispose);
    final repository = _RecordingHealthRepository()
      ..onSuccess = (value) => health.value = _health(taken: value);

    await pumpStatus(
      tester,
      preferencesNotifier: _TestPreferencesNotifier(
        _preferences(CycleReminderType.pill),
      ),
      repository: repository,
      health: health,
    );

    await tester.tap(find.text('Tomada hoje'));
    await tester.pumpAndSettle();
    expect(find.text('Desmarcar registro de hoje?'), findsOneWidget);
    expect(repository.values, isEmpty);

    await tester.tap(find.byKey(const ValueKey('cycle-pill-undo-cancel')));
    await tester.pumpAndSettle();
    expect(repository.values, isEmpty);
    expect(find.text('Tomada hoje'), findsOneWidget);

    await tester.tap(find.text('Tomada hoje'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('cycle-pill-undo-confirm')));
    await tester.pumpAndSettle();

    expect(repository.values, [false]);
    expect(find.text('Registrar pílula'), findsOneWidget);
  });

  testWidgets('troca pill para other e volta reflete status atual', (
    tester,
  ) async {
    final health = ValueNotifier<HealthModel>(_health(taken: true));
    addTearDown(health.dispose);
    final preferencesNotifier = _TestPreferencesNotifier(
      _preferences(CycleReminderType.pill),
    );

    await pumpStatus(
      tester,
      preferencesNotifier: preferencesNotifier,
      repository: _RecordingHealthRepository(),
      health: health,
    );
    expect(find.text('Tomada hoje'), findsOneWidget);

    preferencesNotifier.replace(
      _preferences(CycleReminderType.otherContraceptive),
    );
    await tester.pumpAndSettle();
    expect(find.text('Tomada hoje'), findsNothing);

    preferencesNotifier.replace(_preferences(CycleReminderType.pill));
    await tester.pumpAndSettle();
    expect(find.text('Tomada hoje'), findsOneWidget);
  });
}
