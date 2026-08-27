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
}
