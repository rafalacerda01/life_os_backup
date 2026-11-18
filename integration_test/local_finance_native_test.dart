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
import 'package:life_os/features/finance/presentation/finance_screen.dart';
import 'package:life_os/features/finance/presentation/providers/finance_provider.dart';
import 'package:life_os/features/premium/domain/services/quota_service.dart';
import 'package:life_os/main_local.dart' as app;
import 'package:path_provider/path_provider.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;
  final report = <String, Object?>{'module': 'finance'};
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
    'native local finance: real input, navigation and preserved Tasks',
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

      try {
        check(db.isLocalOnly, 'local-only-database');
        final task = (await db.select(db.taskTable).get()).single;
        report['taskId'] = task.id;
        check(
          task.title == 'SYNTHETIC-ANDROID-PERSIST' && task.isCompleted,
          'prior-task-preserved',
        );
        await tester.pumpWidget(app.LocalFirstDevelopmentApp(session: session));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Finanças').last);
        await tester.pumpAndSettle();
        check(
          find.byType(FinanceScreen).evaluate().length == 1,
          'local-finance-navigation',
        );
        check(tester.takeException() == null, 'no-startup-ui-error');
        final container = ProviderScope.containerOf(
          tester.element(find.byType(FinanceScreen)),
        );
        final repository = container.read(financeRepositoryProvider);
        if (scenario == 'seed') {
          check(
            (await db.select(db.transactions).get()).isEmpty,
            'fresh-finance-table',
          );
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
              'Android finance input',
            );
            await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
            await tester.pumpAndSettle();
          }

          Future<void> create(
            String title,
            String amount, {
            bool income = false,
          }) async {
            await tester.tap(find.byType(FloatingActionButton));
            await tester.pumpAndSettle();
            final titleField = find.byWidgetPredicate(
              (widget) =>
                  widget is TextField &&
                  widget.decoration?.hintText == 'Ex: Mercado',
            );
            final amountField = find.byWidgetPredicate(
              (widget) =>
                  widget is TextField &&
                  widget.decoration?.hintText == r'R$ 0,00',
            );
            await nativeText(titleField, title);
            await nativeText(amountField, amount);
            if (income) {
              await tester.ensureVisible(find.text('Entrada'));
              await tester.tap(find.text('Entrada'));
            }
            final category = find.byKey(
              const ValueKey('create-category-Alimentação'),
            );
            await tester.ensureVisible(category);
            await tester.tap(category);
            await tester.pumpAndSettle();
            final confirm = find.text('Confirmar lançamento');
            await tester.ensureVisible(confirm);
            await tester.tap(confirm);
            await tester.pumpAndSettle();
            await waitFor(
              () async => (await db.select(db.transactions).get()).any(
                (row) => row.title == title,
              ),
              'committed finance create',
            );
          }

          await create('SYNTHETIC-FINANCE-INCOME', '100,50', income: true);
          await create('SYNTHETIC-FINANCE-EXPENSE', '25,50');
          final summary = calculateFinanceSummary(
            await db.select(db.transactions).get(),
          );
          check(
            summary.income == 100.5 &&
                summary.expense == 25.5 &&
                summary.balance == 75,
            'income-expense-and-summary',
          );
          await tester.drag(
            find.byType(CustomScrollView),
            const Offset(0, -450),
          );
          await tester.pumpAndSettle();
          final incomeTitle = find.text('SYNTHETIC-FINANCE-INCOME');
          await waitFor(() => incomeTitle.evaluate().isNotEmpty, 'income card');
          await tester.ensureVisible(incomeTitle);
          final row = find
              .ancestor(of: incomeTitle, matching: find.byType(Row))
              .first;
          await tester.tap(
            find.descendant(
              of: row,
              matching: find.byTooltip('Excluir transação'),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('Excluir'));
          await tester.pumpAndSettle();
          await waitFor(
            () async => (await db.select(db.transactions).get()).length == 1,
            'committed finance delete',
          );
          check(
            (await db.select(db.transactions).get()).single.title ==
                'SYNTHETIC-FINANCE-EXPENSE',
            'correct-ui-deletion',
          );
          for (final title in [
            'SYNTHETIC-FINANCE-QUOTA2',
            'SYNTHETIC-FINANCE-QUOTA3',
          ]) {
            await repository.addTransaction(
              title: title,
              amount: 1,
              type: 'expense',
              category: 'Outros',
            );
          }
          var refused = false;
          try {
            await repository.addTransaction(
              title: 'SYNTHETIC-FINANCE-FORBIDDEN4',
              amount: 1,
              type: 'expense',
              category: 'Outros',
            );
          } on PlanQuotaExceeded {
            refused = true;
          }
          check(
            refused && (await db.select(db.transactions).get()).length == 3,
            'native-finance-free-limit',
          );
          final temporary = (await db.select(db.transactions).get())
              .where((row) => row.title.startsWith('SYNTHETIC-FINANCE-QUOTA'))
              .toList();
          for (final row in temporary) {
            await repository.deleteTransaction(row.id);
          }
        } else {
          await tester.drag(
            find.byType(CustomScrollView),
            const Offset(0, -450),
          );
          await tester.pumpAndSettle();
          await waitFor(
            () => find.text('SYNTHETIC-FINANCE-EXPENSE').evaluate().isNotEmpty,
            'reopened finance card',
          );
          check(
            find.text('SYNTHETIC-FINANCE-EXPENSE').evaluate().length == 1,
            'finance-ui-reopened-expense',
          );
        }
        final transaction = (await db.select(db.transactions).get()).single;
        report['transactionId'] = transaction.id;
        check(
          transaction.title == 'SYNTHETIC-FINANCE-EXPENSE' &&
              transaction.amount == 25.5 &&
              transaction.type == 'expense',
          'persistent-expense',
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
        await tester.tap(find.text('Tarefas').last);
        await tester.pumpAndSettle();
        await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
        await tester.pumpAndSettle();
        await waitFor(
          () => find.text('SYNTHETIC-ANDROID-PERSIST').evaluate().isNotEmpty,
          'task after finance navigation',
        );
        check(
          find.text('SYNTHETIC-ANDROID-PERSIST').evaluate().length == 1,
          'task-navigation-preserves-content',
        );
        check(
          (await db.select(db.taskTable).get()).single == task,
          'prior-task-id-unchanged',
        );
        check(tester.takeException() == null, 'no-unhandled-ui-error');
      } catch (error, stack) {
        report['bodyError'] = error.toString();
        report['bodyStack'] = stack.toString();
        report['uiTextOnFailure'] = tester.allWidgets
            .whereType<Text>()
            .map((widget) => widget.data ?? '')
            .take(80)
            .toList();
        report['editingOnFailure'] = tester.allWidgets
            .whereType<EditableText>()
            .map((widget) => widget.controller.text)
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
