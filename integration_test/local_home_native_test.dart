import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:intl/intl.dart';
import 'package:life_os/core/database/database_encryption.dart';
import 'package:life_os/core/database/local_profile_bootstrap_journal.dart';
import 'package:life_os/features/analytics/presentation/local_analytics.dart';
import 'package:life_os/features/dashboard/presentation/providers/dashboard_provider.dart';
import 'package:life_os/features/home/presentation/screens/home_screen.dart';
import 'package:life_os/features/tasks/presentation/tasks_screen.dart';
import 'package:life_os/main_local.dart' as app;
import 'package:path_provider/path_provider.dart';

String _fingerprint(Object data) =>
    sha256.convert(utf8.encode(jsonEncode(data))).toString();

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;
  final report = <String, Object?>{'module': 'home'};
  final checks = <String, bool>{};

  void check(bool value, String label) {
    checks[label] = value;
    expect(value, isTrue, reason: label);
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
    'home and analytics read actual offline data without mutating the bank',
    (tester) async {
      final scenario = await app.localLabChannel.invokeMethod<String>(
        'scenario',
      );
      final audit = (await app.localLabChannel.invokeMapMethod<String, Object?>(
        'audit',
      ))!;
      report['scenario'] = scenario;
      report['audit'] = audit;
      check(const {'seed', 'reopen'}.contains(scenario), 'known-scenario');
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
          await tester.pump(const Duration(milliseconds: 60));
        }
        await tester.pumpAndSettle();
      }

      try {
        check(db.isLocalOnly, 'local-only-database');
        final task = (await db.select(db.taskTable).get()).single;
        final finance = (await db.select(db.transactions).get()).single;
        final habit = (await db.select(db.habits).get()).single;
        final checkIn = (await db.select(db.checkInTable).get()).single;
        final focus = (await db.select(db.focusLogs).get()).single;
        final dailyHealth = (await db.select(db.healthEntries).get()).single;
        final medication = (await db.select(db.medications).get()).single;
        final goal = (await db.select(db.waterV2Preferences).get()).single;
        final goals = (await db.select(db.goals).get())
          ..sort((a, b) => a.id.compareTo(b.id));
        final subjects = (await db.select(db.subjects).get())
          ..sort((a, b) => a.id.compareTo(b.id));
        final cards = (await db.select(db.flashcards).get())
          ..sort((a, b) => a.id.compareTo(b.id));
        final stats = (await db.select(db.studyStats).get()).single;
        report.addAll({
          'taskId': task.id,
          'transactionId': finance.id,
          'habitId': habit.id,
          'checkInId': checkIn.id,
          'goalsFingerprint': _fingerprint(
            goals.map((row) => row.toJson()).toList(),
          ),
          'checkinFingerprint': _fingerprint(checkIn.toJson()),
          'studyFingerprint': _fingerprint({
            'subjects': subjects.map((row) => row.toJson()).toList(),
            'cards': cards.map((row) => row.toJson()).toList(),
            'stats': stats.toJson(),
          }),
          'focusFingerprint': _fingerprint(focus.toJson()),
          'healthFingerprint': _fingerprint({
            'daily': dailyHealth.toJson(),
            'medicine': medication.toJson(),
            'goal': goal.toJson(),
          }),
        });
        await tester.pumpWidget(app.LocalFirstDevelopmentApp(session: session));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Início'));
        await waitFor(
          () => find.text('Resumo rápido').evaluate().isNotEmpty,
          'home loaded',
        );
        check(
          find.byType(HomeScreen).evaluate().length == 1,
          'native-home-route',
        );
        check(
          find.textContaining('Perfil local').evaluate().length == 1,
          'local-profile-greeting',
        );
        check(
          find.byTooltip('Notificações').evaluate().isEmpty &&
              find.text('PREMIUM').evaluate().isEmpty,
          'no-native-or-unverified-paid-controls',
        );
        final container = ProviderScope.containerOf(
          tester.element(find.byType(HomeScreen)),
        );
        final dashboard = container.read(dashboardStateProvider);
        check(
          dashboard.hasProductivityData &&
              dashboard.hasHealthData &&
              dashboard.hasFinancialData,
          'dashboard-uses-stored-modules',
        );
        check(
          dashboard.financeBalance == -finance.amount &&
              dashboard.transactionsCount == 1,
          'dashboard-real-finance',
        );
        check(
          dashboard.activeMedications == 1 &&
              dashboard.mood == dailyHealth.mood,
          'dashboard-real-health',
        );

        final summaries = find.text('Ver análises');
        await tester.ensureVisible(summaries);
        await tester.tap(summaries);
        await waitFor(
          () => find.text('Saldo dos lançamentos').evaluate().isNotEmpty,
          'analytics loaded',
        );
        check(
          find.byType(LocalAnalyticsScreen).evaluate().length == 1,
          'native-analytics-route',
        );
        check(
          find.text('1 de 1').evaluate().length == 1 && task.isCompleted,
          'analytics-real-task-completion',
        );
        check(
          find.text('2 de 7 registros possíveis').evaluate().length == 1,
          'analytics-real-habit-count',
        );
        check(
          find
                  .text('${dailyHealth.waterIntakeMl} ml de ${goal.goalMl} ml')
                  .evaluate()
                  .length ==
              1,
          'analytics-real-water-and-goal',
        );
        final formattedBalance = NumberFormat.currency(
          locale: 'pt_BR',
          symbol: 'R\$',
        ).format(-finance.amount);
        check(
          find.text(formattedBalance).evaluate().length == 1,
          'analytics-real-finance-balance',
        );
        check(
          find.textContaining('Companion').evaluate().isEmpty &&
              find.textContaining('50%').evaluate().isEmpty,
          'no-ai-entrypoint-or-sample-results',
        );

        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        final productivity = find.text('Produtividade').last;
        await tester.ensureVisible(productivity);
        await tester.tap(productivity);
        await tester.pumpAndSettle();
        check(
          find.byType(TasksScreen).evaluate().length == 1,
          'home-shortcut-opens-local-tasks',
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
        check(tester.takeException() == null, 'no-unhandled-ui-error');
      } catch (error, stack) {
        report['bodyError'] = error.toString();
        report['bodyStack'] = stack.toString();
        report['uiTextOnFailure'] = tester.allWidgets
            .whereType<Text>()
            .map((w) => w.data ?? '')
            .take(100)
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
