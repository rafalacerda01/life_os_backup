import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:life_os/core/database/database_encryption.dart';
import 'package:life_os/core/database/local_profile_bootstrap_journal.dart';
import 'package:life_os/features/focus/presentation/providers/providers/focus_provider.dart';
import 'package:life_os/features/focus/presentation/providers/screens/focus_screen.dart';
import 'package:life_os/main_local.dart' as app;
import 'package:path_provider/path_provider.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;
  final report = <String, Object?>{'module': 'focus'};
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
    'native local Focus: real timer, pause, resume and preserved modules',
    (tester) async {
      final scenario = await app.localLabChannel.invokeMethod<String>(
        'scenario',
      );
      report['scenario'] = scenario;
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
        report['goalsFingerprint'] = sha256
            .convert(utf8.encode(goalsJson))
            .toString();
        check(
          priorGoals.length == 2 &&
              priorGoals.every((r) => r.currentValue == 1),
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
        await tester.pumpWidget(app.LocalFirstDevelopmentApp(session: session));
        await tester.pumpAndSettle();
        Future<void> tapVisible(Finder finder) async {
          await tester.ensureVisible(finder);
          await tester.tap(finder);
          await tester.pumpAndSettle();
        }

        await tapVisible(find.byKey(const ValueKey('productivity-focus-cta')));
        check(
          find.byType(FocusScreen).evaluate().length == 1,
          'task-shortcut-opens-real-focus',
        );
        final container = ProviderScope.containerOf(
          tester.element(find.byType(FocusScreen)),
        );
        FocusState state() => container.read(focusProvider);
        check(
          !state().isVerified && !state().isRunning,
          'initial-personal-timer',
        );
        check(tester.takeException() == null, 'no-startup-ui-error');

        if (scenario == 'seed') {
          check(
            (await db.select(db.focusLogs).get()).isEmpty,
            'fresh-focus-log',
          );
          await tapVisible(find.text('NENHUM ALVO SELECIONADO'));
          await tapVisible(find.text('SYNTHETIC-ANDROID-PERSIST'));
          check(
            state().activeTargetId == task.id,
            'selected-existing-task-through-ui',
          );
          await tapVisible(find.text('1m'));
          check(state().durationRemaining == 60, 'selected-real-minute');
          final elapsed = Stopwatch()..start();
          await tapVisible(find.byIcon(Icons.play_arrow_rounded));
          await waitFor(
            () => state().durationRemaining <= 58,
            'real countdown',
          );
          check(
            state().isRunning && !state().isVerified && state().targetLocked,
            'offline-unverified-countdown',
          );
          await tapVisible(find.byIcon(Icons.pause_rounded));
          final remaining = state().durationRemaining;
          await Future<void>.delayed(const Duration(milliseconds: 1300));
          await tester.pump();
          check(
            !state().isRunning &&
                remaining > 0 &&
                remaining < 60 &&
                state().durationRemaining == remaining,
            'pause-stops-real-time',
          );
          await tapVisible(find.byIcon(Icons.play_arrow_rounded));
          // Pop the timer while it is running. The provider belongs to the app session.
          Navigator.of(tester.element(find.byType(FocusScreen))).pop();
          await tester.pumpAndSettle();
          check(
            state().isRunning && find.byType(FocusScreen).evaluate().isEmpty,
            'navigation-keeps-timer-running',
          );
          await tapVisible(
            find.byKey(const ValueKey('productivity-focus-cta')),
          );
          check(
            state().isRunning && state().activeTargetId == task.id,
            'reopened-timer-retains-task',
          );
          final finishWait = Stopwatch()..start();
          while (!state().isBreak) {
            if (finishWait.elapsed > const Duration(seconds: 75)) {
              fail('Real timer did not complete');
            }
            await tester.pump(const Duration(milliseconds: 200));
          }
          check(
            elapsed.elapsed >= const Duration(seconds: 60),
            'real-minute-elapsed',
          );
          check(
            find.text('Hora de respirar').evaluate().length == 1 &&
                !state().saveFailed,
            'completed-once-and-entered-break',
          );
        }
        final logs = await db.select(db.focusLogs).get();
        check(
          logs.length == 1 &&
              logs.single.targetType == 'TASK' &&
              logs.single.targetId == task.id &&
              logs.single.durationSeconds == 60,
          'persisted-focus-log',
        );
        report['focusFingerprint'] = sha256
            .convert(utf8.encode(jsonEncode(logs.single.toJson())))
            .toString();
        Navigator.of(tester.element(find.byType(FocusScreen))).pop();
        await tester.pumpAndSettle();
        await navigate('Estudos');
        await waitFor(
          () => find.text('Estudar agora').evaluate().isNotEmpty,
          'study focus shortcut',
        );
        await tapVisible(find.text('Estudar agora'));
        check(
          find.byType(FocusScreen).evaluate().length == 1,
          'study-shortcut-opens-real-focus',
        );
        Navigator.of(tester.element(find.byType(FocusScreen))).pop();
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
          find.text('1 / 3').evaluate().length == 1,
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
