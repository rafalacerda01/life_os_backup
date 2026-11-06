// These tests execute the installed FlutterFire Dart/Pigeon path. The native
// reply is a strict adapter; Android/iOS SDK execution is not claimed.
// ignore_for_file: depend_on_referenced_packages, implementation_imports
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_firestore_platform_interface/src/pigeon/messages.pigeon.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/services/firebase_sdk_bootstrap.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const options = FirebaseOptions(
    apiKey: 'demo-key',
    appId: 'demo-app',
    messagingSenderId: 'demo',
    projectId: 'demo-life-os',
  );
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const readChannel = BasicMessageChannel<Object?>(
    'dev.flutter.pigeon.cloud_firestore_platform_interface.FirebaseFirestoreHostApi.documentReferenceGet',
    FirebaseFirestoreHostApi.codec,
  );
  const writeChannel = BasicMessageChannel<Object?>(
    'dev.flutter.pigeon.cloud_firestore_platform_interface.FirebaseFirestoreHostApi.documentReferenceSet',
    FirebaseFirestoreHostApi.codec,
  );
  int serial = 0;
  setUpAll(setupFirebaseCoreMocks);
  tearDown(() {
    messenger.setMockDecodedMessageHandler(readChannel, null);
    messenger.setMockDecodedMessageHandler(writeChannel, null);
  });
  Future<FirebaseApp> app() => Firebase.initializeApp(
    name: 'sdk-boundary-${serial++}',
    options: options,
  );
  test(
    'first native request carries memory settings before SDK IO; no global clear',
    () async {
      final instance = await app();
      int calls = 0;
      messenger.setMockDecodedMessageHandler(readChannel, (message) async {
        calls++;
        final args = message! as List<Object?>;
        final native = args[0]! as FirestorePigeonFirebaseApp;
        expect(native.appName, instance.name);
        expect(native.databaseURL, '(default)');
        expect(native.settings.persistenceEnabled, isFalse);
        return [
          PigeonDocumentSnapshot(
            path: 'users/A',
            data: {'value': 'server'},
            metadata: PigeonSnapshotMetadata(
              hasPendingWrites: false,
              isFromCache: false,
            ),
          ),
        ];
      });
      final store = configureFirestoreMemoryCache(instance);
      expect(calls, 0);
      expect(store, FirebaseFirestore.instanceFor(app: instance));
      expect(
        (await store
                .doc('users/A')
                .get(const GetOptions(source: Source.server)))
            .data(),
        {'value': 'server'},
      );
      expect(calls, 1);
    },
  );
  test('memory settings do not turn a dispatched write into an ACK', () async {
    final instance = await app(),
        reply = Completer<List<Object?>>(),
        entered = Completer<void>();
    bool acknowledged = false;
    messenger.setMockDecodedMessageHandler(writeChannel, (message) async {
      final native =
          (message! as List<Object?>)[0]! as FirestorePigeonFirebaseApp;
      expect(native.settings.persistenceEnabled, isFalse);
      entered.complete();
      return reply.future;
    });
    final store = configureFirestoreMemoryCache(instance);
    final pending = store
        .doc('users/A')
        .set({'intent': 'A'})
        .then((_) => acknowledged = true);
    await entered.future;
    expect(acknowledged, isFalse);
    reply.complete([null]);
    await pending;
    expect(acknowledged, isTrue);
  });
  test(
    'late settings cannot change the already captured native instance configuration',
    () async {
      final instance = await app(), settings = <bool?>[];
      messenger.setMockDecodedMessageHandler(readChannel, (message) async {
        settings.add(
          ((message! as List<Object?>)[0]! as FirestorePigeonFirebaseApp)
              .settings
              .persistenceEnabled,
        );
        return [
          PigeonDocumentSnapshot(
            path: 'users/A',
            metadata: PigeonSnapshotMetadata(
              hasPendingWrites: false,
              isFromCache: false,
            ),
          ),
        ];
      });
      final started = FirebaseFirestore.instanceFor(app: instance);
      await started.doc('users/A').get();
      configureFirestoreMemoryCache(instance);
      await started.doc('users/A').get();
      expect(settings, [
        null,
        null,
      ]); // Installed plugin caches pigeonApp at first IO.
    },
  );
}
