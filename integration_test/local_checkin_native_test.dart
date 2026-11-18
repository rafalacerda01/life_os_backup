import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:life_os/core/database/database_encryption.dart';
import 'package:life_os/core/database/local_profile_bootstrap_journal.dart';
import 'package:life_os/features/checkin/presentation/checkin_screen.dart';
import 'package:life_os/main_local.dart' as app;
import 'package:path_provider/path_provider.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;
  final report = <String, Object?>{'module': 'checkin'};
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
    'native local Check-in: real sliders, daily edit, history and preserved modules',
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
        await tester.pumpWidget(app.LocalFirstDevelopmentApp(session: session));
        await tester.pumpAndSettle();
        await navigate('Check-in');
        check(
          find.byType(CheckInScreen).evaluate().length == 1,
          'local-checkin-navigation',
        );
        check(tester.takeException() == null, 'no-startup-ui-error');
        Future<void> submit() async {
          await tester.tap(find.text('Registrar Métricas'));
          await tester.pumpAndSettle();
          await waitFor(
            () async => (await db.select(db.checkInTable).get()).length == 1,
            'check-in committed',
          );
        }

        Future<void> slider(int index, double fraction) async {
          final finder = find.byType(Slider).at(index);
          await tester.ensureVisible(finder);
          final rect = tester.getRect(finder);
          final x = fraction == 0
              ? rect.left + 12
              : fraction == 1
              ? rect.right - 12
              : rect.center.dx;
          await tester.tapAt(Offset(x, rect.center.dy));
          await tester.pumpAndSettle();
        }

        if (scenario == 'seed') {
          check(
            (await db.select(db.checkInTable).get()).isEmpty,
            'fresh-checkin-table',
          );
          for (var i = 0; i < 3; i++) {
            await slider(i, 1);
          }
          await submit();
          final initial = (await db.select(db.checkInTable).get()).single;
          check(
            initial.energy == 5 &&
                initial.focus == 5 &&
                initial.motivation == 5,
            'real-sliders-initial-save',
          );
          for (var i = 0; i < 3; i++) {
            await slider(i, 0);
          }
          await submit();
          final edited = (await db.select(db.checkInTable).get()).single;
          check(
            edited.id == initial.id &&
                edited.energy == 1 &&
                edited.focus == 1 &&
                edited.motivation == 1,
            'daily-edit-replaces-exact-day',
          );
          await tester.tap(find.byKey(const ValueKey('checkin-open-history')));
          await tester.pumpAndSettle();
          check(
            find.text(edited.id).evaluate().length == 1 &&
                find.text('1.0 / 1.0 / 1.0').evaluate().length == 1,
            'history-shows-edited-metrics',
          );
          await tester.tap(find.byKey(ValueKey('checkin-delete-${edited.id}')));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Excluir'));
          await tester.pumpAndSettle();
          check(
            (await db.select(db.checkInTable).get()).isEmpty &&
                find.text('Sem check-ins registrados.').evaluate().length == 1,
            'confirmed-local-ui-deletion',
          );
          final sheet = tester.getRect(find.byType(BottomSheet));
          await tester.tapAt(Offset(sheet.center.dx, sheet.top - 20));
          await tester.pumpAndSettle();
          await slider(0, 1);
          await slider(1, 0);
          await slider(2, .5);
          await submit();
        } else {
          await waitFor(
            () => find
                .byKey(const ValueKey('checkin-history'))
                .evaluate()
                .isNotEmpty,
            'reopened check-in history',
          );
          check(
            find.text('Último registro: 5.0 / 1.0 / 3.0').evaluate().length ==
                1,
            'checkin-ui-reopened',
          );
        }
        final checkin = (await db.select(db.checkInTable).get()).single;
        report['checkInId'] = checkin.id;
        report['checkinFingerprint'] = sha256
            .convert(utf8.encode(jsonEncode(checkin.toJson())))
            .toString();
        check(
          checkin.energy == 5 &&
              checkin.focus == 1 &&
              checkin.motivation == 3 &&
              !checkin.isSynced,
          'persistent-daily-metrics-never-uploaded',
        );
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
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
