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
import 'package:life_os/features/tasks/presentation/providers/tasks_provider.dart';
import 'package:life_os/features/tasks/presentation/tasks_screen.dart';
import 'package:life_os/main_local.dart' as app;
import 'package:path_provider/path_provider.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;
  final report = <String, Object?>{};
  final checks = <String, bool>{};
  void check(bool value, String name) {
    checks[name] = value;
    expect(value, true, reason: name);
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
    'native local tasks: UI, encryption, Free and reopen without Firebase',
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
      check(
        audit['firebaseApps'] == 0 &&
            (audit['forbiddenPluginsRegistered'] as List).isEmpty,
        'no-native-firebase-or-billing',
      );
      check(audit['internetPermission'] == false, 'android-denies-internet');
      check(const ['seed', 'reopen'].contains(scenario), 'known-scenario');
      final session = await app.prepareLocalDevelopmentSession();
      final db = session.requirePrepared();
      report['profileId'] = session.currentLocalId;
      Future<void> waitForState(
        FutureOr<bool> Function() condition,
        String name,
      ) async {
        final clock = Stopwatch()..start();
        while (!await condition()) {
          if (clock.elapsed > const Duration(seconds: 10))
            fail('State did not arrive: $name');
          await tester.pump(const Duration(milliseconds: 50));
        }
        await tester.pumpAndSettle();
      }

      try {
        await tester.pumpWidget(app.LocalFirstDevelopmentApp(session: session));
        await tester.pumpAndSettle();
        check(tester.takeException() == null, 'local-screen-started');
        check(db.isLocalOnly, 'local-only-database');
        final directory = await getApplicationDocumentsDirectory();
        check(
          !DatabaseEncryptionBootstrap.hasPlaintextHeader(
            db.identity!.fileIn(directory),
          ),
          'personal-database-encrypted',
        );

        if (scenario == 'seed') {
          check(
            (await db.select(db.taskTable).get()).isEmpty,
            'fresh-synthetic-profile',
          );
          Future<void> createInUi(String title) async {
            await tester.tap(find.byTooltip('Nova tarefa'));
            await tester.pumpAndSettle();
            await tester.tap(find.byType(TextField));
            await tester.pumpAndSettle();
            // Actual Android input events from the isolated ADB runner avoid
            // competing with the real IME through TestTextInput injection.
            await app.localLabChannel.invokeMethod(
              'requestSyntheticInput',
              title,
            );
            await waitForState(
              () =>
                  tester
                      .widget<TextField>(find.byType(TextField))
                      .controller!
                      .text ==
                  title,
              'Android input delivered',
            );
            await tester.tap(find.text('Adicionar à Rotina'));
            await tester.pumpAndSettle();
            await waitForState(
              () => find.text(title).evaluate().isNotEmpty,
              'visible created task',
            );
            expect(find.text(title), findsOneWidget);
            await tester.ensureVisible(find.text(title));
            await tester.pumpAndSettle();
          }

          await createInUi('SYNTHETIC-ANDROID-PERSIST');
          await tester.tap(find.text('SYNTHETIC-ANDROID-PERSIST'));
          await tester.pumpAndSettle();
          await waitForState(
            () async =>
                (await db.select(db.taskTable).get()).single.isCompleted,
            'committed toggle',
          );
          check(
            (await db.select(db.taskTable).get()).single.isCompleted,
            'ui-toggle-persisted',
          );
          await createInUi('SYNTHETIC-ANDROID-DELETE');
          final deletingTitle = find.text('SYNTHETIC-ANDROID-DELETE');
          await tester.ensureVisible(deletingTitle);
          await tester.pumpAndSettle();
          final deletingRow = find
              .ancestor(of: deletingTitle, matching: find.byType(Row))
              .first;
          await tester.tap(
            find.descendant(
              of: deletingRow,
              matching: find.byTooltip('Excluir tarefa'),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('Excluir'));
          await tester.pumpAndSettle();
          await waitForState(() async {
            final rows = await db.select(db.taskTable).get();
            return rows.length == 1 &&
                rows.single.title == 'SYNTHETIC-ANDROID-PERSIST';
          }, 'committed deletion');
          check(
            (await db.select(db.taskTable).get()).single.title ==
                'SYNTHETIC-ANDROID-PERSIST',
            'ui-delete-is-local-and-correct',
          );
          final context = tester.element(find.byType(TasksScreen));
          final repo = ProviderScope.containerOf(
            context,
          ).read(tasksRepositoryProvider);
          await repo.addTask('SYNTHETIC-QUOTA-2', 'medium');
          await repo.addTask('SYNTHETIC-QUOTA-3', 'medium');
          var refused = false;
          try {
            await repo.addTask('SYNTHETIC-FORBIDDEN-4', 'medium');
          } catch (error) {
            refused = error.toString().contains('limite permitido');
          }
          check(
            refused && (await db.select(db.taskTable).get()).length == 3,
            'native-atomic-free-limit',
          );
          final temporary = (await db.select(db.taskTable).get())
              .where((task) => task.title.startsWith('SYNTHETIC-QUOTA-'))
              .toList();
          for (final task in temporary) {
            await repo.deleteTask(task.id);
          }
        } else {
          await tester.drag(
            find.byType(CustomScrollView),
            const Offset(0, -400),
          );
          await tester.pumpAndSettle();
          check(
            find.text('SYNTHETIC-ANDROID-PERSIST').evaluate().length == 1,
            'ui-reopened-content',
          );
        }
        final tasks = await db.select(db.taskTable).get();
        check(
          tasks.length == 1 &&
              tasks.single.title == 'SYNTHETIC-ANDROID-PERSIST' &&
              tasks.single.isCompleted,
          'persistent-task-and-status',
        );
        report['taskId'] = tasks.single.id;
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
            .map((widget) => widget.data ?? '')
            .take(60)
            .toList();
        report['editingOnFailure'] = tester.allWidgets
            .whereType<EditableText>()
            .map((widget) => widget.controller.text)
            .toList();
        report['taskRowsOnFailure'] = (await db.select(db.taskTable).get())
            .map(
              (task) => {
                'id': task.id,
                'title': task.title,
                'completed': task.isCompleted,
              },
            )
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
    timeout: const Timeout(Duration(seconds: 75)),
  );
}
