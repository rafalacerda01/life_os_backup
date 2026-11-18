import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/features/study/presentation/providers/study_provider.dart';
import 'package:life_os/features/premium/domain/services/quota_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:life_os/core/database/database_encryption.dart';
import 'package:life_os/core/database/local_profile_bootstrap_journal.dart';
import 'package:life_os/features/study/presentation/study_screen.dart';
import 'package:life_os/main_local.dart' as app;
import 'package:path_provider/path_provider.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;
  final report = <String, Object?>{'module': 'study'};
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
    'native local Study: Android input, flashcard review and preserved modules',
    (tester) async {
      final rawScenario = await app.localLabChannel.invokeMethod<String>(
        'scenario',
      );
      final scenario = rawScenario == 'seed-owned-retry' ? 'seed' : rawScenario;
      report['rawScenario'] = rawScenario;
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
      check(
        const ['seed', 'reopen', 'seed-owned-retry'].contains(rawScenario),
        'known-scenario',
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
        await navigate('Estudos');
        check(
          find.byType(StudyScreen).evaluate().length == 1,
          'local-study-navigation',
        );
        check(tester.takeException() == null, 'no-startup-ui-error');
        check(
          find.text('Estudar agora').evaluate().isEmpty,
          'no-unqualified-focus-entrypoint',
        );
        final container = ProviderScope.containerOf(
          tester.element(find.byType(StudyScreen)),
        );
        final repository = container.read(studyRepositoryProvider);
        Future<void> tapVisible(Finder finder) async {
          await tester.ensureVisible(finder);
          await tester.tap(finder);
          await tester.pumpAndSettle();
        }

        Future<void> nativeText(String label, String value) async {
          final finder = find.byWidgetPredicate(
            (w) => w is TextField && w.decoration?.labelText == label,
          );
          await tapVisible(finder);
          await app.localLabChannel.invokeMethod(
            'requestSyntheticInput',
            value,
          );
          await waitFor(
            () => tester.widget<TextField>(finder).controller!.text == value,
            'Android study input',
          );
          await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
          await tester.pumpAndSettle();
        }

        Future<void> createSubject(String title) async {
          await tester.tap(find.byTooltip('Adicionar disciplina'));
          await tester.pumpAndSettle();
          await nativeText('Nome da disciplina', title);
          await tapVisible(find.text('Adicionar Disciplina'));
          await waitFor(
            () async => (await db.select(db.subjects).get()).any(
              (r) => r.title == title,
            ),
            'subject committed',
          );
        }

        Future<void> createCard(String title, String question) async {
          await tapVisible(find.text('Adicionar novo flashcard'));
          await tapVisible(find.byType(DropdownButton<String>));
          await tester.tap(find.text(title).last);
          await tester.pumpAndSettle();
          await nativeText('Pergunta', question);
          await nativeText('Resposta', 'SYNTHETIC-STUDY-ANSWER');
          await tapVisible(find.text('Criar Flashcard'));
          await waitFor(
            () async => (await db.select(db.flashcards).get()).any(
              (r) => r.question == question,
            ),
            'card committed',
          );
        }

        if (rawScenario == 'seed-owned-retry') {
          final ownedSubjects = await db.select(db.subjects).get();
          final ownedCards = await db.select(db.flashcards).get();
          final ownedStats = await db.select(db.studyStats).get();
          final titles = ownedSubjects.map((r) => r.title).toSet();
          final questions = ownedCards.map((r) => r.question).toSet();
          if (session.currentLocalId !=
                  'local-v1-4e240644-adf6-4a09-a738-24c46fe5aeaf' ||
              ownedSubjects.length != 2 ||
              ownedCards.length != 2 ||
              ownedStats.length != 1 ||
              !titles.containsAll({
                'SYNTHETIC-STUDY-MAIN',
                'SYNTHETIC-STUDY-DELETE',
              }) ||
              !questions.containsAll({
                'SYNTHETIC-STUDY-QUESTION-ONE',
                'SYNTHETIC-STUDY-QUESTION-TWO',
              }) ||
              ownedCards.any(
                (r) =>
                    r.answer != 'SYNTHETIC-STUDY-ANSWER' ||
                    !ownedSubjects.any((s) => s.id == r.subjectId),
              ) ||
              ownedCards.where((r) => r.lastReviewed != null).length != 1 ||
              ownedStats.single.streak != 1 ||
              (ownedStats.single.progress - .05).abs() > .000001) {
            throw StateError('OWNED_SYNTHETIC_RETRY_STATE_MISMATCH');
          }
          final data = jsonEncode({
            'profileId': session.currentLocalId,
            'subjects': ownedSubjects.map((r) => r.toJson()).toList(),
            'cards': ownedCards.map((r) => r.toJson()).toList(),
            'stats': ownedStats.map((r) => r.toJson()).toList(),
          });
          final cache = await getTemporaryDirectory();
          final backup = File(
            '${cache.path}/study-owned-retry-${DateTime.now().microsecondsSinceEpoch}.json',
          );
          if (await backup.exists())
            throw StateError('RETRY_BACKUP_ALREADY_EXISTS');
          await backup.writeAsString(data, flush: true);
          final hash = sha256.convert(await backup.readAsBytes()).toString();
          if (hash != sha256.convert(utf8.encode(data)).toString())
            throw StateError('RETRY_BACKUP_MISMATCH');
          report['ownedRetryCheckpoint'] = {
            'path': backup.path,
            'sha256': hash,
            'subjectCount': ownedSubjects.length,
            'cardCount': ownedCards.length,
          };
          for (final row in ownedSubjects) {
            await repository.removeSubject(row.id);
          }
          await repository.resetDailyProgress(
            await repository.getStudyStatsStream().first,
          );
        }
        if (scenario == 'seed') {
          check(
            (await db.select(db.subjects).get()).isEmpty &&
                (await db.select(db.flashcards).get()).isEmpty,
            'empty-study-tables-before-round',
          );
          await createSubject('SYNTHETIC-STUDY-MAIN');
          await createSubject('SYNTHETIC-STUDY-DELETE');
          check(
            (await db.select(db.subjects).get()).length == 2,
            'real-ui-created-subjects',
          );
          await createCard(
            'SYNTHETIC-STUDY-MAIN',
            'SYNTHETIC-STUDY-QUESTION-ONE',
          );
          await createCard(
            'SYNTHETIC-STUDY-MAIN',
            'SYNTHETIC-STUDY-QUESTION-TWO',
          );
          check(
            (await db.select(db.flashcards).get()).length == 2,
            'real-ui-created-flashcards',
          );
          await tapVisible(find.text('Revisar agora'));
          await tapVisible(find.text('Ver resposta'));
          await waitFor(
            () => find.text('SYNTHETIC-STUDY-ANSWER').evaluate().isNotEmpty,
            'real answer revealed',
          );
          await tapVisible(find.text('Marcar como revisado'));
          await waitFor(
            () async =>
                (await db.select(db.flashcards).get())
                    .where((r) => r.lastReviewed != null)
                    .length ==
                1,
            'review committed',
          );
          check(
            (await db.select(db.studyStats).get()).single.reviewQueue == 1,
            'real-ui-reviewed-card',
          );
          await tester.tap(find.byType(BackButton));
          await tester.pumpAndSettle();
          await createCard(
            'SYNTHETIC-STUDY-DELETE',
            'SYNTHETIC-STUDY-DELETE-QUESTION',
          );
          final remove = (await db.select(db.subjects).get()).singleWhere(
            (r) => r.title == 'SYNTHETIC-STUDY-DELETE',
          );
          await tapVisible(find.byKey(ValueKey('subject-delete-${remove.id}')));
          await tester.tap(find.text('Excluir'));
          await tester.pumpAndSettle();
          check(
            (await db.select(db.subjects).get()).length == 1 &&
                (await db.select(db.flashcards).get()).length == 2 &&
                (await db.select(db.studyStats).get()).single.reviewQueue == 1,
            'correct-subject-cascade-and-due-count',
          );
          await repository.createSubject('SYNTHETIC-STUDY-QUOTA-TWO');
          await repository.createSubject('SYNTHETIC-STUDY-QUOTA-THREE');
          var refused = false;
          try {
            await repository.createSubject('SYNTHETIC-STUDY-FORBIDDEN');
          } on PlanQuotaExceeded {
            refused = true;
          }
          check(
            refused && (await db.select(db.subjects).get()).length == 3,
            'native-study-free-limit',
          );
          for (final row in (await db.select(db.subjects).get()).where(
            (r) => r.title.startsWith('SYNTHETIC-STUDY-QUOTA'),
          )) {
            await repository.removeSubject(row.id);
          }
          await tapVisible(find.text('Resetar progresso diário'));
          await tester.tap(find.text('Resetar'));
          await tester.pumpAndSettle();
          check(
            (await db.select(db.studyStats).get()).single.progress == 0 &&
                (await db.select(db.studyStats).get()).single.streak == 1,
            'real-ui-reset-preserves-streak',
          );
        } else {
          await tester.ensureVisible(find.text('SYNTHETIC-STUDY-MAIN'));
          await tester.pumpAndSettle();
          check(
            find.text('SYNTHETIC-STUDY-MAIN').evaluate().length == 1,
            'subject-ui-reopened',
          );
          await tapVisible(find.text('Revisar agora'));
          check(
            find.text('Ver resposta').evaluate().length == 1 &&
                (find
                        .text('SYNTHETIC-STUDY-QUESTION-ONE')
                        .evaluate()
                        .isNotEmpty ||
                    find
                        .text('SYNTHETIC-STUDY-QUESTION-TWO')
                        .evaluate()
                        .isNotEmpty),
            'due-flashcard-ui-reopened',
          );
          await tester.tap(find.byType(BackButton));
          await tester.pumpAndSettle();
        }
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
