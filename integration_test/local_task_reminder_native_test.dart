import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/database_encryption.dart';
import 'package:life_os/core/database/local_database_identity.dart';
import 'package:life_os/core/services/native_notification_registry.dart';
import 'package:life_os/core/services/notification_service.dart';
import 'package:life_os/core/services/owned_notification_service.dart';
import 'package:life_os/features/tasks/data/services/local_task_reminder.dart';
import 'package:life_os/features/tasks/presentation/local_task_reminder_screen.dart';
import 'package:life_os/main_local.dart' as app;
import 'package:path_provider/path_provider.dart';

const _retainedTask = 'SYNTHETIC-TASK-REMINDER-RETAIN';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;
  final report = <String, Object?>{'module': 'task-reminder'};
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
    'owned reminder survives interruption and can be removed without touching a different owner',
    (tester) async {
      Future<void> waitFor(
        FutureOr<bool> Function() condition,
        String label, {
        Duration timeout = const Duration(seconds: 20),
      }) async {
        final clock = Stopwatch()..start();
        while (!await condition()) {
          if (clock.elapsed > timeout) fail('State did not arrive: $label');
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.pumpAndSettle();
      }

      Future<void> tap(Finder finder) async {
        await tester.ensureVisible(finder);
        await tester.tap(finder);
        await tester.pumpAndSettle();
      }

      final scenario = await app.localLabChannel.invokeMethod<String>(
        'scenario',
      );
      final audit = (await app.localLabChannel.invokeMapMethod<String, Object?>(
        'audit',
      ))!;
      report.addAll({'scenario': scenario, 'audit': audit});
      check(
        const {'seed', 'reopen', 'deliver'}.contains(scenario),
        'known-scenario',
      );
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
      final directory = await getApplicationDocumentsDirectory();
      final file = identity.fileIn(directory);
      final foreign = LocalDatabaseIdentity(
        'local-v1-976801d2-bf2e-4c07-b3e8-bf4f20895562',
      );
      report['profileId'] = identity.uid;
      try {
        check(
          db.isLocalOnly && identity.isLocalInstallation,
          'owned-by-local-installation',
        );
        if (scenario == 'seed') {
          expect(await db.select(db.taskTable).get(), isEmpty);
          await db
              .into(db.taskTable)
              .insert(
                TaskTableCompanion.insert(
                  id: _retainedTask,
                  title: _retainedTask,
                  priority: 'medium',
                  date: DateTime.now(),
                ),
              );
        }
        check(
          (await db.select(db.taskTable).get()).single.id == _retainedTask,
          'synthetic-task-preserved',
        );
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
        final profile = find.text('Perfil e ajustes');
        await waitFor(() => profile.evaluate().isNotEmpty, 'home opened');
        await tap(profile);
        final item = find.text('Lembrete de tarefas');
        await waitFor(() => item.evaluate().length == 1, 'profile opened');
        await tap(item);
        final screen = find.byType(LocalTaskReminderScreen);
        check(screen.evaluate().length == 1, 'profile-opens-local-reminder');
        final container = ProviderScope.containerOf(tester.element(screen));
        final service = container.read(localTaskReminderProvider);
        final registry = await NativeNotificationRegistry.openInstallation();
        final native = NotificationService.instance;
        final schedule = find.text('Agendar lembrete');
        final remove = find.text('Remover meu lembrete');

        if (scenario == 'seed') {
          await waitFor(
            () => schedule.evaluate().isNotEmpty,
            'unscheduled reminder UI',
          );
          check(
            (await service.status()).minuteOfDay == null &&
                registry.records(identity).isEmpty,
            'default-has-no-alarm',
          );
          await tap(schedule);
          await tap(find.text('OK'));
          if (audit['notificationsPermission'] == false) {
            await app.localLabChannel.invokeMethod<void>(
              'requestSyntheticInput',
              'SYNTHETIC-NOTIFY-ALLOW',
            );
          }
          await waitFor(
            () async =>
                (await service.status()).minuteOfDay == 9 * 60 &&
                remove.evaluate().isNotEmpty,
            'daily alarm and UI exist',
          );
          final other = OwnedNotificationService.forLocalInstallation(
            identity: foreign,
            native: native,
            isCurrent: () => true,
          );
          final now = DateTime.now();
          check(
            await other.scheduleLocalTaskReminder(
              id: LocalTaskReminder.logicalId,
              scheduledDate: DateTime(now.year, now.month, now.day + 1, 8),
              payload: 'synthetic-foreign-reminder',
            ),
            'separate-owner-sentinel-scheduled',
          );
        }

        final status = await service.status();
        check(
          status.minuteOfDay == 540 && !status.needsRecovery,
          'daily-clock-retained',
        );
        final owned = registry
            .records(identity)
            .singleWhere((row) => row.state == 'ACTIVE');
        final otherRow = registry.records(foreign).single;
        final pending = await native.pendingNotificationRequests();
        check(
          owned.logicalId == otherRow.logicalId &&
              owned.id != otherRow.id &&
              owned.owner != otherRow.owner,
          'native-ids-distinguish-owners',
        );
        check(
          pending
                  .where(
                    (item) =>
                        item.id == owned.id &&
                        registry.matches(owned, item.payload) &&
                        item.title == 'Life OS' &&
                        item.body == 'Revise suas tarefas no Life OS.',
                  )
                  .length ==
              1,
          'os-stores-one-generic-local-reminder',
        );
        check(
          pending.any(
            (item) =>
                item.id == otherRow.id &&
                registry.matches(otherRow, item.payload) &&
                registry.originalPayload(otherRow, item.payload) ==
                    'synthetic-foreign-reminder',
          ),
          'other-owner-retained',
        );
        report['nativeId'] = owned.id;
        report['foreignNativeId'] = otherRow.id;

        if (scenario == 'deliver') {
          await waitFor(() => remove.evaluate().isNotEmpty, 'removal control');
          await tap(remove);
          await waitFor(
            () async =>
                (await service.status()).minuteOfDay == null &&
                schedule.evaluate().isNotEmpty,
            'removal confirmed in UI and OS',
          );
          check(
            registry.records(identity).single.state == 'RETIRED',
            'ui-cancels-only-previous-alarm',
          );
          final now = DateTime.now().add(const Duration(minutes: 2));
          check(
            await service.create(now.hour * 60 + now.minute),
            'nearby-real-android-alarm',
          );
          final urgent = registry
              .records(identity)
              .singleWhere((row) => row.state == 'ACTIVE');
          await waitFor(
            () async => (await native.activeNotificationRequests()).any(
              (item) =>
                  item.id == urgent.id &&
                  item.tag == urgent.tag &&
                  item.title == 'Life OS',
            ),
            'real alarm delivered by Android',
            timeout: const Duration(seconds: 160),
          );
          check(
            (await native.activeNotificationRequests()).any(
              (item) => item.id == urgent.id && item.tag == urgent.tag,
            ),
            'native-notification-delivered',
          );
          await service.remove();
          check(
            (await native.activeNotificationRequests()).every(
                  (item) => item.id != urgent.id,
                ) &&
                (await native.pendingNotificationRequests()).every(
                  (item) => item.id != urgent.id && item.id != owned.id,
                ),
            'active-and-repeating-alarm-removed',
          );
          check(
            (await native.pendingNotificationRequests()).any(
              (item) =>
                  item.id == otherRow.id &&
                  registry.matches(otherRow, item.payload),
            ),
            'cancellation-preserves-other-owner',
          );
        }

        final after = (await app.localLabChannel
            .invokeMapMethod<String, Object?>('audit'))!;
        check(
          after['notificationsPermission'] == true &&
              after['firebaseApps'] == 0 &&
              (after['forbiddenPluginsRegistered'] as List).isEmpty,
          'notifications-authorized-without-firebase',
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
        report['uiTextOnFailure'] = tester.allWidgets
            .whereType<Text>()
            .map((widget) => widget.data ?? '')
            .take(60)
            .toList();
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
