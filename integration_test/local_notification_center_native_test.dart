import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/database_encryption.dart';
import 'package:life_os/core/services/notification_service.dart';
import 'package:life_os/features/notifications/presentation/screens/local_notification_center_screen.dart';
import 'package:life_os/features/study/presentation/study_screen.dart';
import 'package:life_os/main_local.dart' as app;
import 'package:path_provider/path_provider.dart';

const _examId = 'exam_synthetic-central-17';
const _habitId = 'habit_synthetic-central-17';
const _medicationId = 'health_med_synthetic-central-17';
const _examTitle = 'Prova de SYNTHETIC-CENTRAL-EXAM';
const _habitTitle = 'Hábito: SYNTHETIC-CENTRAL-HABIT';
const _medicationTitle = 'Medicamento: SYNTHETIC-CENTRAL-TREATMENT';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;
  final report = <String, Object?>{'module': 'notification-center'};
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
        .map((entry) => entry.toString())
        .toList();
    await app.localLabChannel.invokeMethod('saveReport', jsonEncode(report));
  });

  testWidgets(
    'offline notification center preserves interaction after reopen',
    (tester) async {
      Future<void> waitFor(
        FutureOr<bool> Function() ready,
        String label,
      ) async {
        final clock = Stopwatch()..start();
        while (!await ready()) {
          if (clock.elapsed > const Duration(seconds: 25))
            fail('Missing: $label');
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.pumpAndSettle();
      }

      Future<void> tap(Finder finder) async {
        await tester.ensureVisible(finder);
        await tester.tap(finder);
        await tester.pumpAndSettle();
      }

      Future<void> cardAction(String title, String action) async {
        final card = find.ancestor(
          of: find.text(title),
          matching: find.byType(Card),
        );
        await tap(
          find.descendant(
            of: card,
            matching: find.byTooltip('Ações da notificação'),
          ),
        );
        await tap(find.text(action));
      }

      final scenario = await app.localLabChannel.invokeMethod<String>(
        'scenario',
      );
      final audit = (await app.localLabChannel.invokeMapMethod<String, Object?>(
        'audit',
      ))!;
      report.addAll({'scenario': scenario, 'audit': audit});
      check({'seed', 'resume', 'reopen'}.contains(scenario), 'known-scenario');
      check(
        audit['package'] == 'com.rafalacerda.lifeos.localdev' &&
            audit['internetPermission'] == false,
        'isolated-package-no-internet',
      );
      check(
        audit['firebaseApps'] == 0 &&
            (audit['forbiddenPluginsRegistered'] as List).isEmpty,
        'no-native-firebase-or-billing',
      );

      final session = await app.prepareLocalDevelopmentSession();
      final db = session.requirePrepared();
      final identity = db.identity!;
      final file = identity.fileIn(await getApplicationDocumentsDirectory());
      report['profileId'] = identity.uid;
      try {
        check(
          db.isLocalOnly && identity.isLocalInstallation,
          'local-installation',
        );
        final native = NotificationService.instance;
        await native.init();
        final alarms = await native.pendingNotificationRequests();
        check(alarms.length == 1, 'prior-owner-alarm-retained');
        report['retainedNativeAlarmId'] = alarms.single.id;
        if (scenario == 'seed') {
          check(
            (await db.notificationDao.getAllNotifications()).isEmpty,
            'no-prior-central-cards',
          );
          await _seed(db);
        } else if (scenario == 'resume') {
          final held = await db.notificationDao.getAllNotifications();
          check(
            held.length == 3 &&
                held.any((row) => row.id == _examId && row.isRead) &&
                held.any(
                  (row) => row.id == _medicationId && !row.isCompleted,
                ) &&
                held.any((row) => row.id == _habitId) &&
                (await db.select(db.notificationDismissals).get()).isEmpty,
            'retained-partial-seed-matches',
          );
        }

        await tester.pumpWidget(app.LocalFirstDevelopmentApp(session: session));
        await tester.pumpAndSettle();
        final navigation = find.byType(NavigationBar);
        await waitFor(
          () => navigation.hitTestable().evaluate().isNotEmpty,
          'app startup',
        );
        await tap(
          find.descendant(of: navigation, matching: find.text('Início')),
        );
        final entry = find.text('Notificações');
        await waitFor(() => entry.evaluate().length == 1, 'home center link');
        await tap(entry);
        check(
          find.byType(LocalNotificationCenterScreen).evaluate().length == 1,
          'home-opens-local-center',
        );
        await waitFor(
          () => find.text(_examTitle).evaluate().isNotEmpty,
          'exam derived',
        );
        final cards = await db.notificationDao.getAllNotifications();
        check(
          cards.length == (scenario == 'reopen' ? 2 : 3),
          'expected-card-count',
        );
        check(cards.any((card) => card.id == _examId), 'exam-derived');
        check(
          cards.any((card) => card.id == _medicationId),
          'medication-derived',
        );

        if (scenario != 'reopen') {
          check(cards.any((card) => card.id == _habitId), 'habit-derived');
          await tap(find.text(_examTitle));
          await waitFor(
            () => find.byType(StudyScreen).evaluate().length == 1,
            'Studies opens',
          );
          check(
            find.byType(StudyScreen).evaluate().length == 1,
            'card-navigates-to-studies',
          );
          check(
            await tester.binding.handlePopRoute(),
            'system-back-route-handled',
          );
          await tester.pumpAndSettle();
          await waitFor(
            () => find.text(_medicationTitle).evaluate().isNotEmpty,
            'return to center',
          );
          await cardAction(_medicationTitle, 'Concluir');
          await waitFor(
            () async =>
                (await db.notificationDao.getNotificationById(
                  _medicationId,
                ))?.isCompleted ==
                true,
            'complete medication',
          );
          await cardAction(_habitTitle, 'Dispensar');
          await waitFor(
            () async =>
                await db.notificationDao.getNotificationById(_habitId) == null,
            'dismiss habit',
          );
          await tap(find.byTooltip('Atualizar notificações'));
          await waitFor(
            () => find.text(_examTitle).evaluate().isNotEmpty,
            'refresh center',
          );
          check(
            find.text(_habitTitle).evaluate().isEmpty,
            'refresh-does-not-resurrect-dismissed-card',
          );
        }

        check(
          (await db.notificationDao.getNotificationById(_examId))?.isRead ==
              true,
          'read-state-retained',
        );
        check(
          (await db.notificationDao.getNotificationById(
                _medicationId,
              ))?.isCompleted ==
              true,
          'completed-state-retained',
        );
        check(
          await db.notificationDao.getNotificationById(_habitId) == null &&
              (await db.select(db.notificationDismissals).get())
                      .single
                      .notificationId ==
                  _habitId,
          'dismissal-retained',
        );
        check(
          (await db.select(db.syncQueueTable).get()).isEmpty,
          'no-remote-queue',
        );
        check(
          (await db.select(db.taskTable).get()).any(
            (row) => row.id == 'SYNTHETIC-TASK-REMINDER-RETAIN',
          ),
          'prior-task-retained',
        );
        final after = await native.pendingNotificationRequests();
        check(
          after.length == 1 &&
              after.single.id == alarms.single.id &&
              after.single.payload == alarms.single.payload,
          'central-does-not-touch-native-alarm',
        );
        check(
          (await db.customSelect('PRAGMA integrity_check').getSingle())
                      .data
                      .values
                      .single ==
                  'ok' &&
              !DatabaseEncryptionBootstrap.hasPlaintextHeader(file),
          'encrypted-sqlite-integrity',
        );
        const secure = FlutterSecureStorage(
          aOptions: AndroidOptions(
            encryptedSharedPreferences: true,
            resetOnError: false,
            migrateOnAlgorithmChange: false,
          ),
        );
        final key = await secure.read(key: identity.keyAlias);
        check(key != null && key.isNotEmpty, 'native-key-readable');
        report['keyFingerprint'] = sha256.convert(utf8.encode(key!)).toString();
        check(tester.takeException() == null, 'no-unhandled-ui-error');
      } catch (error, stack) {
        report['bodyError'] = error.toString();
        report['bodyStack'] = stack.toString();
        rethrow;
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await session.dispose();
        report['databaseHash'] = sha256
            .convert(await file.readAsBytes())
            .toString();
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

Future<void> _seed(AppDatabase db) async {
  final now = DateTime.now();
  const fixture = 'synthetic-central-17';
  await db.transaction(() async {
    await db
        .into(db.subjects)
        .insert(
          SubjectsCompanion.insert(
            id: fixture,
            title: 'SYNTHETIC-CENTRAL-EXAM',
            cardsToReview: 0,
            streakDays: 0,
            progress: 0,
            hasExam: true,
            examDate: Value(now.millisecondsSinceEpoch),
          ),
        );
    await db
        .into(db.medications)
        .insert(
          MedicationsCompanion.insert(
            firestoreId: fixture,
            name: 'SYNTHETIC-CENTRAL-TREATMENT',
            startDate: now,
          ),
        );
    await db
        .into(db.habits)
        .insert(
          HabitsCompanion.insert(
            id: fixture,
            title: 'SYNTHETIC-CENTRAL-HABIT',
            completedDates: '[]',
          ),
        );
  });
}
