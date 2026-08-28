import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android registra ActionBroadcastReceiver exatamente uma vez', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final occurrences = RegExp(
      'com\\.dexterous\\.flutterlocalnotifications\\.'
      'ActionBroadcastReceiver',
    ).allMatches(manifest);

    expect(occurrences, hasLength(1));
    expect(
      manifest,
      contains(
        'android:exported="false" '
        'android:name="com.dexterous.flutterlocalnotifications.'
        'ActionBroadcastReceiver"',
      ),
    );
  });

  test('implementação permanece foreground-only sem callback background', () {
    final service = File(
      'lib/core/services/notification_service.dart',
    ).readAsStringSync();
    final appDelegate = File('ios/Runner/AppDelegate.swift').readAsStringSync();

    expect(
      service,
      isNot(contains('onDidReceiveBackgroundNotificationResponse:')),
    );
    expect(service, isNot(contains("@pragma('vm:entry-point')")));
    expect(appDelegate, isNot(contains('setPluginRegistrantCallback')));
  });

  test('Feito usa categoria neutra e actions foreground', () {
    final service = File(
      'lib/core/services/notification_service.dart',
    ).readAsStringSync();

    expect(
      service,
      contains("cycleReminderDoneActionId = 'cycle_reminder_done'"),
    );
    expect(service, contains("'life_os_pill_reminder_actions_v1'"));
    expect(
      RegExp(
        r'cycleReminderDoneActionId,[\s\S]*?showsUserInterface: true',
      ).hasMatch(service),
      isTrue,
    );
    expect(
      RegExp(
        r'cycleReminderDoneActionId,[\s\S]*?DarwinNotificationActionOption\.foreground',
      ).hasMatch(service),
      isTrue,
    );
    expect(
      service,
      isNot(contains('onDidReceiveBackgroundNotificationResponse:')),
    );
  });
}
