import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/core/database/local_installation_storage_inspector.dart';
import 'package:life_os/core/database/local_installation_identity_provider.dart';
// Test fakes from the versions pinned in pubspec.lock.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/local_database_identity.dart';
import 'package:life_os/core/database/local_installation_identity_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const id = 'local-v1-123e4567-e89b-42d3-a456-426614174000';
  const anotherId = 'local-v1-123e4567-e89b-42d3-a456-426614174001';

  late Directory directory;
  String? savedId;
  int writeCount = 0;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('lifeos-local-id-');
    savedId = null;
    writeCount = 0;
  });

  tearDown(() async {
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  LocalInstallationIdentityService service({
    String Function()? generator,
    Future<String?> Function()? reader,
    Future<void> Function(String)? writer,
    Future<void> Function()? assertFreshInstall,
  }) => LocalInstallationIdentityService(
    readSavedId: reader ?? () async => savedId,
    writeSavedId:
        writer ??
        (value) async {
          savedId = value;
          writeCount++;
        },
    documentsDirectory: () async => directory,
    newId: generator ?? () => id,
    assertFreshInstall: assertFreshInstall ?? () async {},
  );

  test('fresh install creates a stable installation-scoped identity', () async {
    final first = await service().resolve();
    final second = await service(generator: () => anotherId).resolve();

    expect(first.uid, id);
    expect(second, first);
    expect(writeCount, 1);
    expect(first.fileName, startsWith('life_os_u_'));
  });

  test(
    'parallel startup resolves through a single local marker write',
    () async {
      final bootstrap = service();
      final results = await Future.wait([
        bootstrap.resolve(),
        bootstrap.resolve(),
        bootstrap.resolve(),
      ]);

      expect(results.every((item) => item.uid == id), isTrue);
      expect(writeCount, 1);
    },
  );

  test('legacy UID-scoped database blocks silent identity reset', () async {
    await File(
      '${directory.path}/life_os_u_legacy.sqlite',
    ).writeAsString('legacy');

    await expectLater(
      service().resolve(),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'LOCAL_PROFILE_MIGRATION_REQUIRED',
        ),
      ),
    );
    expect(savedId, isNull);
    expect(writeCount, 0);
  });

  test('orphan legacy WAL sidecar also blocks local provisioning', () async {
    await File('${directory.path}/life_os.sqlite-wal').writeAsString('old');

    await expectLater(
      service().resolve(),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'LOCAL_PROFILE_MIGRATION_REQUIRED',
        ),
      ),
    );
    expect(savedId, isNull);
  });

  test(
    'matching encrypted database and known sidecars remain usable',
    () async {
      savedId = id;
      final filename = LocalDatabaseIdentity(id).fileName;
      await File('${directory.path}/$filename').writeAsString('encrypted');
      await File('${directory.path}/$filename-wal').writeAsString('wal');

      final identity = await service().resolve();

      expect(identity.uid, id);
      expect(writeCount, 0);
    },
  );

  test(
    'another account database blocks accidental cross-profile access',
    () async {
      savedId = id;
      final otherName = LocalDatabaseIdentity(anotherId).fileName;
      await File('${directory.path}/$otherName').writeAsString('other');

      await expectLater(
        service().resolve(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'LOCAL_PROFILE_MIGRATION_REQUIRED',
          ),
        ),
      );
    },
  );

  test('invalid or tampered local marker is rejected', () async {
    savedId = 'firebase-uid-not-allowed';
    await expectLater(
      service().resolve(),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'LOCAL_PROFILE_ID_INVALID',
        ),
      ),
    );
  });

  test('identity generator cannot inject a UID or invalid value', () async {
    await expectLater(
      service(generator: () => '../other-user').resolve(),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'LOCAL_PROFILE_GENERATOR_INVALID',
        ),
      ),
    );
    expect(writeCount, 0);
  });

  test('failed persistence must not expose a prepared identity', () async {
    await expectLater(
      service(
        writer: (value) async {
          writeCount++;
          // Simulates storage failure to persist the marker.
        },
      ).resolve(),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'LOCAL_PROFILE_ID_NOT_PERSISTED',
        ),
      ),
    );
    expect(writeCount, 1);
    expect(savedId, isNull);
  });

  test('non-DB legacy data blocks local identity creation', () async {
    var checked = 0;
    final bootstrap = service(
      assertFreshInstall: () async {
        checked++;
        throw StateError('LOCAL_PROFILE_MIGRATION_REQUIRED');
      },
    );

    await expectLater(
      bootstrap.resolve(),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'LOCAL_PROFILE_MIGRATION_REQUIRED',
        ),
      ),
    );
    expect(checked, 1);
    expect(savedId, isNull);
    expect(writeCount, 0);
  });

  test(
    'fresh-install guard is not reapplied to a persisted valid profile',
    () async {
      savedId = id;
      var checked = 0;
      final resolved = await service(
        assertFreshInstall: () async {
          checked++;
          throw StateError('SHOULD_NOT_RUN_FOR_EXISTING_LOCAL_PROFILE');
        },
      ).resolve();

      expect(resolved.uid, id);
      expect(checked, 0);
      expect(writeCount, 0);
    },
  );

  for (final suffix in [
    '.plaintext-backup',
    '.encryption-candidate',
    '.unknown',
  ]) {
    test(
      'legacy life_os.sqlite$suffix blocks without modifying artifacts',
      () async {
        final artifact = File('${directory.path}/life_os.sqlite$suffix');
        await artifact.writeAsString('preserve-test-bytes');
        await expectLater(service().resolve(), throwsA(isA<StateError>()));
        expect(writeCount, 0);
        expect(savedId, isNull);
        expect(await artifact.readAsString(), 'preserve-test-bytes');
      },
    );
  }

  test('concurrent service instances reuse one persisted identity', () async {
    final identities = await Future.wait([
      service().resolve(),
      service(generator: () => anotherId).resolve(),
    ]);
    expect(identities.map((identity) => identity.uid), [id, id]);
    expect(writeCount, 1);
    expect(savedId, id);
  });

  test('guard read failure is cached and never writes a marker', () async {
    var checks = 0;
    final bootstrap = service(
      assertFreshInstall: () async {
        checks++;
        throw PlatformException(code: 'read-unavailable');
      },
    );
    for (var attempt = 0; attempt < 2; attempt++) {
      await expectLater(bootstrap.resolve(), throwsA(isA<PlatformException>()));
    }
    expect(checks, 1);
    expect(writeCount, 0);
  });

  _providerBoundaryTests(() => directory);
}

void _providerBoundaryTests(Directory Function() testDirectory) {
  group('provider boundary (mocked native stores)', () {
    const channel = MethodChannel(
      'plugins.it_nomads.com/flutter_secure_storage',
    );
    const onboardingKey = 'life_os_onboarding_completed_v1';
    late ProviderContainer container;
    late SharedPreferencesAsyncPlatform? previousPreferences;
    late Map<String, String> secureData;
    late List<MethodCall> calls;
    var failReads = false;

    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      previousPreferences = SharedPreferencesAsyncPlatform.instance;
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      secureData = {};
      calls = [];
      failReads = false;
      container = ProviderContainer(
        overrides: [
          localInstallationStorageInspectorProvider.overrideWithValue(
            LocalInstallationStorageInspector(
              documentsDirectory: () async => testDirectory(),
              supportDirectory: () async =>
                  Directory('${testDirectory().path}/files'),
            ),
          ),
        ],
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (failReads) throw PlatformException(code: 'read-failed');
            switch (call.method) {
              case 'read':
                return secureData[call.arguments['key']];
              case 'readAll':
                return Map<String, String>.of(secureData);
              case 'write':
                secureData[call.arguments['key'] as String] =
                    call.arguments['value'] as String;
                return null;
              default:
                fail('Unexpected storage operation: ${call.method}');
            }
          });
    });

    tearDown(() {
      container.dispose();
      SharedPreferencesAsyncPlatform.instance = previousPreferences;
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    LocalInstallationIdentityService provider() =>
        container.read(localInstallationIdentityServiceProvider);

    for (final key in [
      'auth_access_token',
      'db_encryption_key',
      LocalDatabaseIdentity('legacy-uid').keyAlias,
      'life_os_legacy_state',
    ]) {
      test('legacy secure alias $key blocks without writing', () async {
        secureData[key] = 'preserve-test-value';
        await expectLater(
          provider().assertFreshInstall(),
          throwsA(isA<StateError>()),
        );
        expect(secureData, {key: 'preserve-test-value'});
        expect(calls.map((call) => call.method), ['readAll']);
      });
    }

    for (final value in [true, false]) {
      test('persisted onboarding=$value blocks without writing', () async {
        SharedPreferencesAsyncPlatform.instance =
            InMemorySharedPreferencesAsync.withData({onboardingKey: value});
        await expectLater(
          provider().assertFreshInstall(),
          throwsA(isA<StateError>()),
        );
        expect(secureData, isEmpty);
        expect(calls.map((call) => call.method), ['readAll']);
      });
    }

    test('invalid onboarding type fails closed', () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData({onboardingKey: 'invalid'});
      await expectLater(
        provider().assertFreshInstall(),
        throwsA(isA<TypeError>()),
      );
      expect(secureData, isEmpty);
    });

    test('secure read failure cannot report a fresh installation', () async {
      failReads = true;
      await expectLater(
        provider().assertFreshInstall(),
        throwsA(isA<PlatformException>()),
      );
      expect(secureData, isEmpty);
    });

    test(
      'fresh provider uses UUID v4 and disables native reset and migration',
      () async {
        final callbacks = provider();
        final bootstrap = LocalInstallationIdentityService(
          readSavedId: callbacks.readSavedId,
          writeSavedId: callbacks.writeSavedId,
          documentsDirectory: () async => testDirectory(),
          newId: callbacks.newId,
          assertFreshInstall: callbacks.assertFreshInstall,
        );
        final identity = await bootstrap.resolve();
        expect(
          identity.uid,
          matches(
            RegExp(
              r'^local-v1-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
            ),
          ),
        );
        expect(secureData, {
          LocalInstallationIdentityService.storageKey: identity.uid,
        });
        expect(calls.map((call) => call.method), [
          'read',
          'readAll',
          'write',
          'read',
        ]);
        for (final call in calls) {
          final options = call.arguments['options'] as Map;
          // Pin the staged backend as well as the per-call safety flags.
          // This mock cannot prove effective options or native preservation.
          expect(options['encryptedSharedPreferences'], 'true');
          expect(options['resetOnError'], 'false');
          expect(options['migrateOnAlgorithmChange'], 'false');
        }
      },
    );
  });
}
