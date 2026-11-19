import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/database_encryption.dart';
import 'package:life_os/features/settings/data/local_profile_settings.dart';
import 'package:life_os/main_local.dart' as app;
import 'package:path_provider/path_provider.dart';

const _name = 'SYNTHETIC-PROFILE-15';
const _task = 'SYNTHETIC-PROFILE-KEEP';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;
  final report = <String, Object?>{'module': 'profile'};
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
    'profile preferences and device PIN gate with the native Android prompt',
    (tester) async {
      Future<void> waitFor(
        FutureOr<bool> Function() condition,
        String label,
      ) async {
        final timer = Stopwatch()..start();
        while (!await condition()) {
          if (timer.elapsed > const Duration(seconds: 25))
            fail('State did not arrive: $label');
          await tester.pump(const Duration(milliseconds: 70));
        }
        await tester.pumpAndSettle();
      }

      Future<void> tap(Finder finder) async {
        await tester.ensureVisible(finder);
        await tester.tap(finder);
        await tester.pumpAndSettle();
      }

      Future<void> signal(String request) async {
        await app.localLabChannel.invokeMethod<void>(
          'requestSyntheticInput',
          request,
        );
      }

      final scenario = await app.localLabChannel.invokeMethod<String>(
        'scenario',
      );
      final audit = (await app.localLabChannel.invokeMapMethod<String, Object?>(
        'audit',
      ))!;
      report.addAll({'scenario': scenario, 'audit': audit});
      check(
        const {
          'seed',
          'seed-after-name',
          'seed-after-pin',
          'reopen',
        }.contains(scenario),
        'known-scenario',
      );
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
      final identity = db.identity!;
      final store = LocalProfileSettingsStore(identity);
      final directory = await getApplicationDocumentsDirectory();
      final file = identity.fileIn(directory);
      report['profileId'] = identity.uid;
      try {
        final initial = await store.read();
        check(
          db.isLocalOnly && identity.isLocalInstallation,
          'installation-owned-profile',
        );
        if (scenario == 'seed') {
          check(
            initial.displayName.isEmpty && !initial.requireDeviceUnlock,
            'lock-optional-by-default',
          );
          check(
            (await db.select(db.taskTable).get()).isEmpty,
            'fresh-synthetic-database',
          );
          await db
              .into(db.taskTable)
              .insert(
                TaskTableCompanion.insert(
                  id: _task,
                  title: _task,
                  priority: 'medium',
                  date: DateTime.now(),
                ),
              );
        } else if (scenario == 'seed-after-name' ||
            scenario == 'seed-after-pin') {
          check(
            initial.displayName == _name &&
                initial.requireDeviceUnlock == (scenario == 'seed-after-pin'),
            'preserved-name-and-expected-lock',
          );
          check(
            (await db.select(db.taskTable).get()).single.id == _task,
            'preserved-original-synthetic-task',
          );
        } else {
          check(
            initial.displayName == _name && initial.requireDeviceUnlock,
            'preferences-persisted-before-ui',
          );
        }

        await tester.pumpWidget(app.LocalFirstDevelopmentApp(session: session));
        await tester.pumpAndSettle();
        final lock = find.text('Life OS bloqueado');
        final navigation = find.byType(NavigationBar);
        final unlock = find.text('Desbloquear');
        final profile = find.text('Perfil e ajustes');
        final lockSwitch = find.widgetWithText(
          SwitchListTile,
          'Bloqueio do dispositivo',
        );

        Future<void> openProfile() async {
          await tap(
            find.descendant(of: navigation, matching: find.text('Início')),
          );
          await waitFor(() => profile.evaluate().isNotEmpty, 'home route');
          await tap(profile);
          await waitFor(() => lockSwitch.evaluate().isNotEmpty, 'profile UI');
        }

        if (scenario == 'seed-after-pin') {
          // The earlier run persisted the opt-in before inspecting the switch.
          // Prove this persisted setting gates startup, then use the authorized
          // Android flow to disable and re-enable the synthetic preference.
          await waitFor(
            () => lock.hitTestable().evaluate().isNotEmpty,
            'retained enrollment gates startup',
          );
          check(
            navigation.hitTestable().evaluate().isEmpty,
            'prior-activation-protects-startup',
          );
          await tap(unlock);
          await signal('SYNTHETIC-AUTH-PIN');
          await waitFor(
            () => lock.evaluate().isEmpty,
            'PIN unlocks prior enrollment',
          );
          await openProfile();
          await tap(lockSwitch);
          await signal('SYNTHETIC-AUTH-PIN');
          await waitFor(
            () async =>
                !(await store.read()).requireDeviceUnlock &&
                !tester.widget<SwitchListTile>(lockSwitch).value &&
                tester.widget<SwitchListTile>(lockSwitch).onChanged != null,
            'authorized disable persisted and reflected in UI',
          );
          check(
            !(await store.read()).requireDeviceUnlock,
            'pin-authorizes-disabling-lock',
          );
          await tap(find.byType(BackButton));
        }

        if (scenario != 'reopen') {
          await waitFor(
            () => navigation.hitTestable().evaluate().isNotEmpty,
            'offline app startup',
          );
          check(lock.evaluate().isEmpty, 'initial-app-visible');
          await openProfile();
          check(
            !tester.widget<SwitchListTile>(lockSwitch).value,
            'optional-switch-off',
          );
          if (scenario == 'seed') {
            await tap(find.text('Nome de exibição'));
            final input = find.descendant(
              of: find.byKey(const Key('local-profile-name')),
              matching: find.byType(EditableText),
            );
            await tap(input);
            await signal(_name);
            await waitFor(
              () => tester.widget<EditableText>(input).controller.text == _name,
              'native profile name input',
            );
            await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
            await tester.pumpAndSettle();
            await tap(find.text('Salvar'));
            await waitFor(
              () async => (await store.read()).displayName == _name,
              'native name write',
            );
          }
          await tap(find.byType(BackButton));
          await waitFor(
            () => find.textContaining(_name).evaluate().isNotEmpty,
            'updated home greeting',
          );
          check(
            find.textContaining(_name).evaluate().length == 1,
            'home-uses-saved-display-name',
          );

          await tap(profile);
          await waitFor(
            () => lockSwitch.evaluate().isNotEmpty,
            'profile options',
          );
          await tap(lockSwitch);
          await signal('SYNTHETIC-AUTH-CANCEL');
          await waitFor(
            () => find
                .text('O bloqueio do Android não foi confirmado.')
                .evaluate()
                .isNotEmpty,
            'cancelled Android confirmation',
          );
          check(
            !(await store.read()).requireDeviceUnlock,
            'cancel-does-not-enable-lock',
          );
          await tap(lockSwitch);
          await signal('SYNTHETIC-AUTH-PIN');
          await waitFor(
            () async =>
                (await store.read()).requireDeviceUnlock &&
                lockSwitch.evaluate().isNotEmpty &&
                tester.widget<SwitchListTile>(lockSwitch).value &&
                tester.widget<SwitchListTile>(lockSwitch).onChanged != null,
            'Android PIN activation reflected in secure storage and UI',
          );
          check(
            tester.widget<SwitchListTile>(lockSwitch).value,
            'device-pin-enables-lock',
          );
          check(lock.evaluate().isEmpty, 'verified-enrollment-stays-unlocked');
          await signal('SYNTHETIC-BACKGROUND');
          await waitFor(
            () => lock.hitTestable().evaluate().isNotEmpty,
            'lock after OS background',
          );
          check(
            lockSwitch.hitTestable().evaluate().isEmpty,
            'background-lock-hides-profile',
          );
        } else {
          await waitFor(
            () => lock.hitTestable().evaluate().isNotEmpty,
            'locked startup',
          );
          check(
            navigation.hitTestable().evaluate().isEmpty,
            'startup-hides-local-navigation',
          );
        }

        await tap(unlock);
        await signal('SYNTHETIC-AUTH-CANCEL');
        await waitFor(
          () => find
              .text('O bloqueio do Android não foi confirmado.')
              .hitTestable()
              .evaluate()
              .isNotEmpty,
          'cancelled unlock',
        );
        check(
          lock.hitTestable().evaluate().length == 1,
          'cancel-does-not-unlock',
        );
        await tap(unlock);
        await signal('SYNTHETIC-AUTH-PIN');
        await waitFor(
          () => lock.evaluate().isEmpty,
          'successful Android PIN unlock',
        );
        check(lock.evaluate().isEmpty, 'device-pin-unlocks-app');
        if (scenario == 'reopen') await openProfile();
        check(
          tester.widget<SwitchListTile>(lockSwitch).value,
          'unlocked-profile-reflects-persisted-lock',
        );
        await tap(lockSwitch);
        await signal('SYNTHETIC-AUTH-CANCEL');
        await waitFor(
          () => find
              .text('O bloqueio do Android não foi confirmado.')
              .evaluate()
              .isNotEmpty,
          'cancelled lock disable',
        );
        check(
          (await store.read()).requireDeviceUnlock,
          'cancel-does-not-disable-lock',
        );

        final saved = await store.read();
        check(
          saved.displayName == _name && saved.requireDeviceUnlock,
          'secure-profile-settings-retained',
        );
        check(
          (await db.select(db.taskTable).get()).single.id == _task,
          'encrypted-task-retained',
        );
        check(
          (await db.select(db.syncQueueTable).get()).isEmpty,
          'no-remote-queue',
        );
        check(
          !DatabaseEncryptionBootstrap.hasPlaintextHeader(file),
          'encrypted-database',
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
        final key = await secure.read(key: identity.keyAlias);
        check(key != null && key.isNotEmpty, 'keystore-backed-key-readable');
        report['keyFingerprint'] = sha256.convert(utf8.encode(key!)).toString();
        final after = (await app.localLabChannel
            .invokeMapMethod<String, Object?>('audit'))!;
        check(
          after['firebaseApps'] == 0 &&
              (after['forbiddenPluginsRegistered'] as List).isEmpty,
          'no-late-native-firebase-or-billing',
        );
        check(tester.takeException() == null, 'no-unhandled-ui-error');
      } catch (error, stack) {
        report['bodyError'] = error.toString();
        report['bodyStack'] = stack.toString();
        report['lifecycleOnFailure'] =
            WidgetsBinding.instance.lifecycleState?.name;
        rethrow;
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await session.dispose();
        report['databaseHash'] = sha256
            .convert(await file.readAsBytes())
            .toString();
      }
    },
    timeout: const Timeout(Duration(seconds: 240)),
  );
}
