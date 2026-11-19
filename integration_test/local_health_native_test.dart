import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:life_os/core/database/database_encryption.dart';
import 'package:life_os/core/database/local_profile_bootstrap_journal.dart';
import 'package:life_os/features/health/presentation/health_screen.dart';
import 'package:life_os/features/health/presentation/cycle/cycle_health_screen.dart';
import 'package:life_os/main_local.dart' as app;
import 'package:path_provider/path_provider.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;
  final report = <String, Object?>{'module': 'health'};
  final checks = <String, bool>{};
  void check(bool value, String label) {
    checks[label] = value;
    expect(value, true, reason: label);
  }

  tearDownAll(() async {
    report['checks'] = checks;
    report['testResults'] = binding.results.map(
      (key, value) => MapEntry(key, value.toString()),
    );
    report['failureDetails'] = binding.failureMethodsDetails
        .map((e) => e.toString())
        .toList();
    await app.localLabChannel.invokeMethod('saveReport', jsonEncode(report));
  });
  testWidgets(
    'native local Health: input, hydration, medication, cycle and preserved modules',
    (tester) async {
      final actualScenario = await app.localLabChannel.invokeMethod<String>(
        'scenario',
      );
      final ownedRetry = actualScenario == 'seed-preserved-health';
      final scenario = ownedRetry ? 'seed' : actualScenario;
      report['scenario'] = scenario;
      report['actualScenario'] = actualScenario;
      final audit = (await app.localLabChannel.invokeMapMethod<String, Object?>(
        'audit',
      ))!;
      report['audit'] = audit;
      check(
        audit['package'] == 'com.rafalacerda.lifeos.localdev',
        'isolated-package',
      );
      check(audit['internetPermission'] == false, 'android-denies-internet');
      check(
        audit['firebaseApps'] == 0 &&
            (audit['forbiddenPluginsRegistered'] as List).isEmpty,
        'no-native-firebase-or-billing',
      );
      check(const ['seed', 'reopen'].contains(scenario), 'known-scenario');
      final session = await app.prepareLocalDevelopmentSession();
      final db = session.requirePrepared();
      report['profileId'] = session.currentLocalId;
      Future<void> waitFor(
        FutureOr<bool> Function() condition,
        String label,
      ) async {
        final watch = Stopwatch()..start();
        while (!await condition()) {
          if (watch.elapsed > const Duration(seconds: 12))
            fail('State did not arrive: $label');
          await tester.pump(const Duration(milliseconds: 50));
        }
        await tester.pumpAndSettle();
      }

      Future<void> navigate(String text) async {
        await tester.tap(find.text(text).last);
        await tester.pumpAndSettle();
      }

      try {
        check(db.isLocalOnly, 'local-only-database');
        final task = (await db.select(db.taskTable).get()).single;
        final finance = (await db.select(db.transactions).get()).single;
        final priorHabit = (await db.select(db.habits).get()).single;
        report['habitId'] = priorHabit.id;
        report['taskId'] = task.id;
        report['transactionId'] = finance.id;
        check(
          task.title == 'SYNTHETIC-ANDROID-PERSIST' && task.isCompleted,
          'prior-task-preserved',
        );
        check(
          finance.title == 'SYNTHETIC-FINANCE-EXPENSE' &&
              finance.amount == 25.5 &&
              finance.type == 'expense',
          'prior-finance-preserved',
        );
        check(
          priorHabit.title == 'SYNTHETIC-HABIT-PERSIST' &&
              (jsonDecode(priorHabit.completedDates) as List).length == 2,
          'prior-habit-preserved',
        );
        final priorGoals = await db.select(db.goals).get();
        priorGoals.sort((a, b) => a.id.compareTo(b.id));
        final goalsJson = jsonEncode(
          priorGoals.map((r) => r.toJson()).toList(),
        );
        report['goals'] = priorGoals.map((row) => row.toJson()).toList();
        report['dailyGoalLastResetDay'] = DateTime.fromMillisecondsSinceEpoch(
          priorGoals.singleWhere((row) => row.period == 'DIÁRIA').lastReset,
        ).toIso8601String().split('T').first;
        report['goalsFingerprint'] = sha256
            .convert(utf8.encode(goalsJson))
            .toString();
        check(
          priorGoals.length == 2 &&
              priorGoals.every(
                (r) =>
                    r.currentValue == 1 ||
                    (r.period == 'DIÁRIA' && r.currentValue == 0),
              ),
          'prior-goals-preserved',
        );
        final priorCheckin = (await db.select(db.checkInTable).get()).single;
        report['checkInId'] = priorCheckin.id;
        report['checkinFingerprint'] = sha256
            .convert(utf8.encode(jsonEncode(priorCheckin.toJson())))
            .toString();
        check(
          priorCheckin.energy == 5 &&
              priorCheckin.focus == 1 &&
              priorCheckin.motivation == 3,
          'prior-checkin-preserved',
        );
        final focus = (await db.select(db.focusLogs).get()).single;
        check(
          focus.targetId == task.id && focus.durationSeconds == 60,
          'prior-focus-preserved',
        );
        report['focusFingerprint'] = sha256
            .convert(utf8.encode(jsonEncode(focus.toJson())))
            .toString();
        await tester.pumpWidget(app.LocalFirstDevelopmentApp(session: session));
        await tester.pumpAndSettle();
        await navigate('Saúde');
        check(
          find.byType(HealthScreen).evaluate().length == 1,
          'local-health-navigation',
        );
        check(tester.takeException() == null, 'no-startup-ui-error');

        Future<void> tapVisible(Finder finder) async {
          await tester.ensureVisible(finder);
          await tester.tap(finder);
          await tester.pumpAndSettle();
        }

        Future<void> revealHealth(Finder finder) async {
          if (finder.evaluate().isEmpty) {
            final scroll = find
                .descendant(
                  of: find.byType(HealthScreen),
                  matching: find.byType(Scrollable),
                )
                .first;
            await tester.scrollUntilVisible(finder, 240, scrollable: scroll);
          }
          await tester.ensureVisible(finder);
          await tester.pumpAndSettle();
        }

        Future<void> openCycle() async {
          final tile = find.byKey(const ValueKey('cycle-health-summary-card'));
          await revealHealth(tile);
          await tapVisible(tile);
          check(
            find.byType(CycleHealthScreen).evaluate().length == 1,
            'real-cycle-navigation',
          );
        }

        if (scenario == 'seed') {
          final previousHealth = await db.select(db.healthEntries).get();
          final previousMedicine = await db.select(db.medications).get();
          final previousGoals = await db.select(db.waterV2Preferences).get();
          if (ownedRetry) {
            check(
              session.currentLocalId ==
                      'local-v1-4e240644-adf6-4a09-a738-24c46fe5aeaf' &&
                  previousHealth.length == 1 &&
                  previousHealth.single.mood == 'Focado' &&
                  previousHealth.single.waterIntakeMl == 500 &&
                  previousHealth.single.hasTakenPillToday &&
                  previousMedicine.length == 1 &&
                  previousMedicine.single.name == 'SYNTHETIC-HEALTH-KEEP' &&
                  previousGoals.length == 1 &&
                  previousGoals.single.ownerUid == session.currentLocalId,
              'initial-health-state-verified',
            );
            report['previousHealthFingerprint'] = sha256
                .convert(
                  utf8.encode(
                    jsonEncode({
                      'daily': previousHealth.single.toJson(),
                      'medicine': previousMedicine.single.toJson(),
                      'goal': previousGoals.single.toJson(),
                    }),
                  ),
                )
                .toString();
            report['previousHealthRows'] = {
              'daily': previousHealth.single.toJson(),
              'medicine': previousMedicine.single.toJson(),
              'goal': previousGoals.single.toJson(),
            };
          } else {
            check(
              previousHealth.isEmpty &&
                  previousMedicine.isEmpty &&
                  previousGoals.isEmpty,
              'initial-health-state-verified',
            );
          }
          await tapVisible(find.text('Focado').last);
          check(
            (await db.select(db.healthEntries).get()).single.mood == 'Focado',
            'selected-mood-through-ui',
          );
          final water = find.text('+250 ml');
          await revealHealth(water);
          await tapVisible(water);
          await tapVisible(water);
          check(
            (await db.select(db.healthEntries).get()).single.waterIntakeMl ==
                (ownedRetry ? 1000 : 500),
            'two-glasses-through-ui',
          );

          await tapVisible(find.text('Alterar meta diária'));
          final slider = find.byType(Slider);
          final rect = tester.getRect(slider);
          await tester.tapAt(
            Offset(
              rect.left + rect.width * (ownedRetry ? .55 : .75),
              rect.center.dy,
            ),
          );
          await tester.pumpAndSettle();
          final expectedGoal = tester.widget<Slider>(slider).value.round();
          await tapVisible(find.text('Salvar'));
          check(
            expectedGoal != (previousGoals.firstOrNull?.goalMl ?? 3000) &&
                (await db.select(db.waterV2Preferences).get()).single.goalMl ==
                    expectedGoal,
            'hydration-goal-saved-through-ui',
          );

          Future<void> addMedicine(String title) async {
            final add = find.byTooltip('Adicionar medicamento');
            await revealHealth(add);
            await tapVisible(add);
            final input = find.byWidgetPredicate(
              (widget) =>
                  widget is TextField &&
                  widget.decoration?.hintText == 'Ex.: Vitamina D',
            );
            await tapVisible(input);
            await app.localLabChannel.invokeMethod(
              'requestSyntheticInput',
              title,
            );
            await waitFor(
              () => tester.widget<TextField>(input).controller!.text == title,
              'Android medication input',
            );
            await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
            await tester.pumpAndSettle();
            expect(find.text('Horário do lembrete'), findsNothing);
            await tapVisible(find.text('Salvar'));
            await waitFor(
              () async => (await db.select(db.medications).get()).any(
                (row) => row.name == title,
              ),
              'medication persisted',
            );
          }

          if (!ownedRetry) await addMedicine('SYNTHETIC-HEALTH-KEEP');
          await addMedicine('SYNTHETIC-HEALTH-DELETE');
          check(
            (await db.select(db.medications).get()).length == 2,
            'two-medications-through-ui',
          );
          final temporary = (await db.select(db.medications).get()).singleWhere(
            (row) => row.name == 'SYNTHETIC-HEALTH-DELETE',
          );
          final delete = find.descendant(
            of: find.byKey(ValueKey(temporary.id)),
            matching: find.byTooltip('Excluir medicamento'),
          );
          await revealHealth(delete);
          await tapVisible(delete);
          await tapVisible(find.text('Excluir'));
          check(
            (await db.select(db.medications).get()).single.name ==
                'SYNTHETIC-HEALTH-KEEP',
            'confirmed-exact-medication-deletion',
          );
          await openCycle();
          await tapVisible(
            ownedRetry
                ? find.byTooltip('Configurar ciclo')
                : find.byKey(const ValueKey('cycle-configure-action')),
          );
          await tapVisible(find.text('Salvar'));
          final cycle =
              jsonDecode(
                    (await db.select(db.healthEntries).get())
                        .single
                        .menstrualCycleJson!,
                  )
                  as Map;
          check(
            cycle['isEnabled'] == true && cycle['cycleLengthDays'] == 28,
            'cycle-configured-through-ui',
          );
          final pill = find.byKey(const ValueKey('cycle-pill-daily-control'));
          if (ownedRetry) {
            await tapVisible(pill);
            await tapVisible(
              find.byKey(const ValueKey('cycle-pill-undo-confirm')),
            );
          }
          await tapVisible(pill);
          check(
            (await db.select(db.healthEntries).get()).single.hasTakenPillToday,
            'pill-marked-through-ui',
          );
          await tapVisible(pill);
          await tapVisible(
            find.byKey(const ValueKey('cycle-pill-undo-confirm')),
          );
          check(
            !(await db.select(db.healthEntries).get()).single.hasTakenPillToday,
            'pill-undo-through-ui',
          );
          await tapVisible(pill);
        } else {
          final recordedWater =
              (await db.select(db.healthEntries).get()).single.waterIntakeMl;
          await revealHealth(find.text('$recordedWater ml registrados'));
          check(
            find.text('$recordedWater ml registrados').evaluate().length == 1,
            'hydration-visible-after-reopen',
          );
          await revealHealth(find.text('SYNTHETIC-HEALTH-KEEP'));
          check(
            find.text('SYNTHETIC-HEALTH-KEEP').evaluate().length == 1,
            'medication-visible-after-reopen',
          );
          await openCycle();
          check(
            find.text('Tomada hoje').evaluate().length == 1,
            'pill-visible-after-reopen',
          );
        }
        final health = (await db.select(db.healthEntries).get()).single;
        final medicines = await db.select(db.medications).get();
        final goal = (await db.select(db.waterV2Preferences).get()).single;
        check(
          health.mood == 'Focado' &&
              const {500, 1000}.contains(health.waterIntakeMl) &&
              health.hasTakenPillToday &&
              (jsonDecode(health.menstrualCycleJson!) as Map)['isEnabled'] ==
                  true,
          'daily-health-record-persisted',
        );
        check(
          medicines.single.name == 'SYNTHETIC-HEALTH-KEEP' &&
              goal.goalMl != 3000 &&
              goal.ownerUid == session.currentLocalId &&
              goal.epoch == null &&
              goal.revision == 0,
          'medication-and-local-goal-persisted',
        );
        check(
          (await db.select(db.waterV2Intents).get()).isEmpty &&
              (await db.select(db.waterV2DailyStates).get()).isEmpty &&
              (await db.select(db.notificationsTable).get()).isEmpty,
          'no-water-v2-intents-or-reminders',
        );
        report['healthFingerprint'] = sha256
            .convert(
              utf8.encode(
                jsonEncode({
                  'daily': health.toJson(),
                  'medicine': medicines.single.toJson(),
                  'goal': goal.toJson(),
                }),
              ),
            )
            .toString();
        Navigator.of(tester.element(find.byType(CycleHealthScreen))).pop();
        await tester.pumpAndSettle();
        final subjects = await db.select(db.subjects).get();
        subjects.sort((a, b) => a.id.compareTo(b.id));
        final cards = await db.select(db.flashcards).get();
        cards.sort((a, b) => a.id.compareTo(b.id));
        final stats = (await db.select(db.studyStats).get()).single;
        check(
          subjects.length == 1 &&
              subjects.single.title == 'SYNTHETIC-STUDY-MAIN' &&
              subjects.single.cardsToReview == 1 &&
              cards.length == 2 &&
              cards.where((r) => r.lastReviewed != null).length == 1 &&
              stats.reviewQueue == 1 &&
              stats.progress == 0 &&
              stats.streak == 1,
          'persistent-study-and-review-history',
        );
        report['studyFingerprint'] = sha256
            .convert(
              utf8.encode(
                jsonEncode({
                  'subjects': subjects.map((r) => r.toJson()).toList(),
                  'cards': cards.map((r) => r.toJson()).toList(),
                  'stats': stats.toJson(),
                }),
              ),
            )
            .toString();
        check(
          (await db.select(db.syncQueueTable).get()).isEmpty,
          'no-remote-queue',
        );
        check(
          (await db.customSelect('PRAGMA integrity_check').getSingle())
                  .data
                  .values
                  .single ==
              'ok',
          'sqlite-integrity',
        );
        final directory = await getApplicationDocumentsDirectory();
        check(
          !DatabaseEncryptionBootstrap.hasPlaintextHeader(
            db.identity!.fileIn(directory),
          ),
          'personal-database-encrypted',
        );
        const secure = FlutterSecureStorage(
          aOptions: AndroidOptions(
            encryptedSharedPreferences: true,
            resetOnError: false,
            migrateOnAlgorithmChange: false,
          ),
        );
        final key = await secure.read(key: db.identity!.keyAlias);
        check(key != null && key.isNotEmpty, 'native-key-readable');
        report['keyFingerprint'] = sha256.convert(utf8.encode(key!)).toString();
        final journal =
            jsonDecode(
                  (await secure.read(
                    key: LocalProfileBootstrapJournal.storageKey,
                  ))!,
                )
                as Map;
        check(journal['phase'] == 'READY', 'bootstrap-journal-ready');
        final after = (await app.localLabChannel
            .invokeMapMethod<String, Object?>('audit'))!;
        check(
          after['firebaseApps'] == 0 &&
              (after['forbiddenPluginsRegistered'] as List).isEmpty,
          'no-late-firebase-or-billing',
        );
        await navigate('Tarefas');
        await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
        await tester.pumpAndSettle();
        await waitFor(
          () => find.text('SYNTHETIC-ANDROID-PERSIST').evaluate().isNotEmpty,
          'Tasks after Habits',
        );
        check(
          find.text('SYNTHETIC-ANDROID-PERSIST').evaluate().length == 1,
          'task-navigation-preserves-content',
        );
        await navigate('Finanças');
        await tester.drag(find.byType(CustomScrollView), const Offset(0, -450));
        await tester.pumpAndSettle();
        await waitFor(
          () => find.text('SYNTHETIC-FINANCE-EXPENSE').evaluate().isNotEmpty,
          'Finance after Habits',
        );
        check(
          find.text('SYNTHETIC-FINANCE-EXPENSE').evaluate().length == 1,
          'finance-navigation-preserves-content',
        );
        check(
          (await db.select(db.taskTable).get()).single == task,
          'prior-task-id-unchanged',
        );
        check(
          (await db.select(db.transactions).get()).single == finance,
          'prior-finance-id-unchanged',
        );
        await navigate('Hábitos');
        await waitFor(
          () => find.text('SYNTHETIC-HABIT-PERSIST').evaluate().isNotEmpty,
          'Habits after Goals',
        );
        check(
          find.text('SYNTHETIC-HABIT-PERSIST').evaluate().length == 1,
          'habit-navigation-preserves-content',
        );
        check(
          (await db.select(db.habits).get()).single == priorHabit,
          'prior-habit-id-unchanged',
        );
        await navigate('Metas');
        await waitFor(
          () => find.text('SYNTHETIC-GOAL-DAILY').evaluate().isNotEmpty,
          'Goals after Check-in',
        );
        check(
          find
                  .text(
                    '${priorGoals.singleWhere((row) => row.period == 'DIÁRIA').currentValue} / 3',
                  )
                  .evaluate()
                  .length ==
              1,
          'goal-navigation-preserves-content',
        );
        final afterGoals = await db.select(db.goals).get();
        afterGoals.sort((a, b) => a.id.compareTo(b.id));
        check(
          jsonEncode(afterGoals.map((r) => r.toJson()).toList()) == goalsJson,
          'prior-goal-history-unchanged',
        );
        await navigate('Check-in');
        await waitFor(
          () => find
              .text('Último registro: 5.0 / 1.0 / 3.0')
              .evaluate()
              .isNotEmpty,
          'Check-in after Study',
        );
        check(
          find.text('Último registro: 5.0 / 1.0 / 3.0').evaluate().length == 1,
          'checkin-navigation-preserves-content',
        );
        check(
          (await db.select(db.checkInTable).get()).single == priorCheckin,
          'prior-checkin-history-unchanged',
        );
        check(tester.takeException() == null, 'no-unhandled-ui-error');
      } catch (error, stack) {
        report['bodyError'] = error.toString();
        report['bodyStack'] = stack.toString();
        report['uiTextOnFailure'] = tester.allWidgets
            .whereType<Text>()
            .map((w) => w.data ?? '')
            .take(90)
            .toList();
        rethrow;
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await session.dispose();
        final directory = await getApplicationDocumentsDirectory();
        report['databaseHash'] = sha256
            .convert(await db.identity!.fileIn(directory).readAsBytes())
            .toString();
      }
    },
    timeout: const Timeout(Duration(seconds: 180)),
  );
}
