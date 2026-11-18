import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:life_os/core/database/database_encryption.dart';
import 'package:life_os/core/database/local_profile_bootstrap_journal.dart';
import 'package:life_os/features/habits/presentation/habits_screen.dart';
import 'package:life_os/features/habits/presentation/providers/habits_provider.dart';
import 'package:life_os/features/premium/domain/services/quota_service.dart';
import 'package:life_os/main_local.dart' as app;
import 'package:path_provider/path_provider.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;
  final report = <String, Object?>{'module': 'habits'};
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
    'native local Habits: actual Android input, calendar, deletion and preserved modules',
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
        await tester.pumpWidget(app.LocalFirstDevelopmentApp(session: session));
        await tester.pumpAndSettle();
        await navigate('Hábitos');
        check(
          find.byType(HabitsScreen).evaluate().length == 1,
          'local-habits-navigation',
        );
        check(tester.takeException() == null, 'no-startup-ui-error');
        final container = ProviderScope.containerOf(
          tester.element(find.byType(HabitsScreen)),
        );
        final repository = container.read(habitsRepositoryProvider);
        if (scenario == 'seed') {
          check(
            (await db.select(db.habits).get()).isEmpty,
            'fresh-habits-table',
          );
          Future<void> create(String title) async {
            await tester.tap(find.byType(FloatingActionButton));
            await tester.pumpAndSettle();
            final field = find.byType(TextField);
            await tester.tap(field);
            await tester.pumpAndSettle();
            await app.localLabChannel.invokeMethod(
              'requestSyntheticInput',
              title,
            );
            await waitFor(
              () => tester.widget<TextField>(field).controller!.text == title,
              'Android habit title input',
            );
            await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
            await tester.pumpAndSettle();
            await tester.ensureVisible(find.text('Criar hábito'));
            await tester.tap(find.text('Criar hábito'));
            await tester.pumpAndSettle();
            await waitFor(
              () async => (await db.select(db.habits).get()).any(
                (r) => r.title == title,
              ),
              'habit committed',
            );
          }

          await create('SYNTHETIC-HABIT-PERSIST');
          await create('SYNTHETIC-HABIT-DELETE');
          check(
            (await db.select(db.habits).get()).length == 2,
            'real-ui-created-two-habits',
          );
          final row = (await db.select(db.habits).get()).firstWhere(
            (r) => r.title == 'SYNTHETIC-HABIT-PERSIST',
          );
          final today = find.byKey(ValueKey('habit-today-${row.id}'));
          await tester.ensureVisible(today);
          await tester.tap(today);
          await tester.pumpAndSettle();
          check(
            (jsonDecode(
                          (await db.select(db.habits).get())
                              .firstWhere((r) => r.id == row.id)
                              .completedDates,
                        )
                        as List)
                    .length ==
                1,
            'today-toggle-committed',
          );
          final now = DateTime.now();
          final monday = DateTime(
            now.year,
            now.month,
            now.day,
          ).subtract(Duration(days: now.weekday - 1));
          final other = monday.weekday == now.weekday
              ? monday.add(const Duration(days: 1))
              : monday;
          final day = other.toIso8601String().split('T').first;
          final week = find.byKey(ValueKey('habit-day-${row.id}-$day'));
          await tester.ensureVisible(week);
          await tester.tap(week);
          await tester.pumpAndSettle();
          check(
            (jsonDecode(
                          (await db.select(db.habits).get())
                              .firstWhere((r) => r.id == row.id)
                              .completedDates,
                        )
                        as List)
                    .length ==
                2,
            'week-matrix-toggle-committed',
          );
          final remove = (await db.select(db.habits).get()).firstWhere(
            (r) => r.title == 'SYNTHETIC-HABIT-DELETE',
          );
          final delete = find.byKey(ValueKey('habit-delete-${remove.id}'));
          await tester.ensureVisible(delete);
          await tester.tap(delete);
          await tester.pumpAndSettle();
          await tester.tap(find.text('Excluir'));
          await tester.pumpAndSettle();
          check(
            (await db.select(db.habits).get()).single.id == row.id,
            'correct-habit-ui-deletion',
          );
          await repository.addHabit('SYNTHETIC-HABIT-QUOTA-TWO');
          await repository.addHabit('SYNTHETIC-HABIT-QUOTA-THREE');
          var refused = false;
          try {
            await repository.addHabit('SYNTHETIC-HABIT-FORBIDDEN-FOUR');
          } on PlanQuotaExceeded {
            refused = true;
          }
          check(
            refused && (await db.select(db.habits).get()).length == 3,
            'native-habits-free-limit',
          );
          for (final temporary in (await db.select(db.habits).get()).where(
            (r) => r.title.startsWith('SYNTHETIC-HABIT-QUOTA'),
          )) {
            await repository.deleteHabit(temporary.id, temporary.title);
          }
        } else {
          final title = find.text('SYNTHETIC-HABIT-PERSIST');
          await waitFor(
            () => title.evaluate().isNotEmpty,
            'persisted habit card',
          );
          check(title.evaluate().length == 1, 'habit-ui-reopened');
        }
        final habit = (await db.select(db.habits).get()).single;
        final dates = List<String>.from(jsonDecode(habit.completedDates));
        report['habitId'] = habit.id;
        report['completedDates'] = dates;
        check(
          habit.title == 'SYNTHETIC-HABIT-PERSIST' &&
              dates.length == 2 &&
              dates.toSet().length == 2,
          'persistent-habit-and-history',
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
