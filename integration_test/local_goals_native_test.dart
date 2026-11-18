import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:life_os/core/database/database_encryption.dart';
import 'package:life_os/core/database/local_profile_bootstrap_journal.dart';
import 'package:life_os/features/goals/presentation/goals_screen.dart';
import 'package:life_os/features/goals/presentation/goals_provider.dart';
import 'package:life_os/features/premium/domain/services/quota_service.dart';
import 'package:life_os/main_local.dart' as app;
import 'package:path_provider/path_provider.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;
  final report = <String, Object?>{'module': 'goals'};
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
    'native local Goals: Android input, three cycles, progress and preserved modules',
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
        await tester.pumpWidget(app.LocalFirstDevelopmentApp(session: session));
        await tester.pumpAndSettle();
        await navigate('Metas');
        check(
          find.byType(GoalsScreen).evaluate().length == 1,
          'local-goals-navigation',
        );
        check(tester.takeException() == null, 'no-startup-ui-error');
        final container = ProviderScope.containerOf(
          tester.element(find.byType(GoalsScreen)),
        );
        final repository = container.read(goalRepositoryProvider);
        Future<void> tab(String title) async {
          await tester.tap(find.text(title));
          await tester.pumpAndSettle();
        }

        Future<void> progress(String id, int delta) async {
          final button = find.byKey(
            ValueKey('goal-${delta == 1 ? 'plus' : 'minus'}-$id'),
          );
          await tester.ensureVisible(button);
          await tester.tap(button);
          await tester.pumpAndSettle();
        }

        if (scenario == 'seed') {
          check((await db.select(db.goals).get()).isEmpty, 'fresh-goals-table');
          Future<void> nativeText(Finder finder, String value) async {
            await tester.ensureVisible(finder);
            await tester.tap(finder);
            await tester.pumpAndSettle();
            await app.localLabChannel.invokeMethod(
              'requestSyntheticInput',
              value,
            );
            await waitFor(
              () => tester.widget<TextField>(finder).controller!.text == value,
              'Android goal input',
            );
            await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
            await tester.pumpAndSettle();
          }

          Future<void> create(String title, String target, String cycle) async {
            await tester.tap(find.byType(FloatingActionButton));
            await tester.pumpAndSettle();
            final titleField = find.byWidgetPredicate(
              (w) =>
                  w is TextField &&
                  w.decoration?.hintText == 'Ex.: Páginas lidas',
            );
            final targetField = find.byWidgetPredicate(
              (w) => w is TextField && w.decoration?.hintText == 'Ex.: 10',
            );
            await nativeText(titleField, title);
            await nativeText(targetField, target);
            if (cycle != 'Diária') {
              final dropdown = find.byType(DropdownButtonFormField<String>);
              await tester.ensureVisible(dropdown);
              await tester.tap(dropdown);
              await tester.pumpAndSettle();
              await tester.tap(find.text(cycle).last);
              await tester.pumpAndSettle();
            }
            await tester.ensureVisible(find.text('Criar meta'));
            await tester.tap(find.text('Criar meta'));
            await tester.pumpAndSettle();
            await waitFor(
              () async => (await db.select(db.goals).get()).any(
                (r) => r.title == title,
              ),
              'goal committed',
            );
          }

          await create('SYNTHETIC-GOAL-DAILY', '3', 'Diária');
          await create('SYNTHETIC-GOAL-WEEKLY', '2', 'Semanal');
          await create('SYNTHETIC-GOAL-MONTHLY', '5', 'Mensal');
          final rows = await db.select(db.goals).get();
          check(
            rows.length == 3 && rows.map((r) => r.period).toSet().length == 3,
            'real-ui-created-three-cycles',
          );
          final daily = rows.firstWhere((r) => r.period == 'DIÁRIA');
          final weekly = rows.firstWhere((r) => r.period == 'SEMANAL');
          final monthly = rows.firstWhere((r) => r.period == 'MENSAL');
          await progress(daily.id, 1);
          await progress(daily.id, 1);
          await progress(daily.id, -1);
          check(
            (await db.select(db.goals).get())
                    .firstWhere((r) => r.id == daily.id)
                    .currentValue ==
                1,
            'daily-ui-progress',
          );
          await tab('Semanais');
          await progress(weekly.id, 1);
          await progress(weekly.id, 1);
          check(
            find.text('2 / 2').evaluate().length == 1,
            'weekly-target-reached',
          );
          final delete = find.byKey(ValueKey('goal-delete-${weekly.id}'));
          await tester.ensureVisible(delete);
          await tester.tap(delete);
          await tester.pumpAndSettle();
          await tester.tap(find.text('Excluir'));
          await tester.pumpAndSettle();
          check(
            (await db.select(db.goals).get()).length == 2 &&
                !(await db.select(db.goals).get()).any(
                  (r) => r.id == weekly.id,
                ),
            'correct-weekly-ui-deletion',
          );
          await repository.createGoal('SYNTHETIC-GOAL-QUOTA', 'DIÁRIA', 1);
          var refused = false;
          try {
            await repository.createGoal(
              'SYNTHETIC-GOAL-FORBIDDEN',
              'DIÁRIA',
              1,
            );
          } on PlanQuotaExceeded {
            refused = true;
          }
          check(
            refused && (await db.select(db.goals).get()).length == 3,
            'native-goals-free-limit',
          );
          final temporary = (await db.select(db.goals).get()).singleWhere(
            (r) => r.title == 'SYNTHETIC-GOAL-QUOTA',
          );
          await repository.removeGoal(temporary.id);
          final old = DateTime.now()
              .subtract(const Duration(days: 70))
              .millisecondsSinceEpoch;
          await (db.update(
            db.goals,
          )..where((r) => r.id.equals(monthly.id))).write(
            monthly
                .toCompanion(false)
                .copyWith(currentValue: const Value(4), lastReset: Value(old)),
          );
          await tester.pumpAndSettle();
          await tab('Mensais');
          await waitFor(() async {
            final row = (await db.select(db.goals).get()).firstWhere(
              (r) => r.id == monthly.id,
            );
            return row.currentValue == 0 && row.lastReset > old;
          }, 'monthly expired cycle reset');
          check(
            find.text('0 / 5').evaluate().length == 1,
            'expired-monthly-cycle-reset',
          );
          await progress(monthly.id, 1);
          check(
            find.text('1 / 5').evaluate().length == 1,
            'monthly-ui-progress',
          );
        } else {
          await waitFor(
            () => find.text('SYNTHETIC-GOAL-DAILY').evaluate().isNotEmpty,
            'daily goal reopened',
          );
          check(find.text('1 / 3').evaluate().length == 1, 'daily-ui-reopened');
          await tab('Mensais');
          await waitFor(
            () => find.text('SYNTHETIC-GOAL-MONTHLY').evaluate().isNotEmpty,
            'monthly goal reopened',
          );
          check(
            find.text('1 / 5').evaluate().length == 1,
            'monthly-ui-reopened',
          );
        }
        final goals = await db.select(db.goals).get();
        goals.sort((a, b) => a.id.compareTo(b.id));
        check(
          goals.length == 2 &&
              goals.every((r) => r.currentValue == 1) &&
              goals.any((r) => r.period == 'DIÁRIA' && r.targetValue == 3) &&
              goals.any((r) => r.period == 'MENSAL' && r.targetValue == 5),
          'persistent-goals-and-progress',
        );
        report['goals'] = goals.map((r) => r.toJson()).toList();
        report['goalsFingerprint'] = sha256
            .convert(utf8.encode(jsonEncode(report['goals'])))
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
