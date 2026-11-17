import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/local_database_identity.dart';
import 'package:life_os/core/database/local_installation_identity_service.dart';

void main() {
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
  }) =>
      LocalInstallationIdentityService(
        readSavedId: reader ?? () async => savedId,
        writeSavedId: writer ??
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

  test('parallel startup resolves through a single local marker write',
      () async {
    final bootstrap = service();
    final results = await Future.wait([
      bootstrap.resolve(),
      bootstrap.resolve(),
      bootstrap.resolve(),
    ]);

    expect(results.every((item) => item.uid == id), isTrue);
    expect(writeCount, 1);
  });

  test('legacy UID-scoped database blocks silent identity reset', () async {
    await File('${directory.path}/life_os_u_legacy.sqlite')
        .writeAsString('legacy');

    await expectLater(
      service().resolve(),
      throwsA(isA<StateError>().having(
        (e) => e.message,
        'message',
        'LOCAL_PROFILE_MIGRATION_REQUIRED',
      )),
    );
    expect(savedId, isNull);
    expect(writeCount, 0);
  });

  test('orphan legacy WAL sidecar also blocks local provisioning', () async {
    await File('${directory.path}/life_os.sqlite-wal').writeAsString('old');

    await expectLater(
      service().resolve(),
      throwsA(isA<StateError>().having(
        (e) => e.message,
        'message',
        'LOCAL_PROFILE_MIGRATION_REQUIRED',
      )),
    );
    expect(savedId, isNull);
  });

  test('matching encrypted database and known sidecars remain usable',
      () async {
    savedId = id;
    final filename = LocalDatabaseIdentity(id).fileName;
    await File('${directory.path}/$filename').writeAsString('encrypted');
    await File('${directory.path}/$filename-wal').writeAsString('wal');

    final identity = await service().resolve();

    expect(identity.uid, id);
    expect(writeCount, 0);
  });

  test('another account database blocks accidental cross-profile access',
      () async {
    savedId = id;
    final otherName = LocalDatabaseIdentity(anotherId).fileName;
    await File('${directory.path}/$otherName').writeAsString('other');

    await expectLater(
      service().resolve(),
      throwsA(isA<StateError>().having(
        (e) => e.message,
        'message',
        'LOCAL_PROFILE_MIGRATION_REQUIRED',
      )),
    );
  });

  test('invalid or tampered local marker is rejected', () async {
    savedId = 'firebase-uid-not-allowed';
    await expectLater(
      service().resolve(),
      throwsA(isA<StateError>().having(
        (e) => e.message,
        'message',
        'LOCAL_PROFILE_ID_INVALID',
      )),
    );
  });

  test('identity generator cannot inject a UID or invalid value', () async {
    await expectLater(
      service(generator: () => '../other-user').resolve(),
      throwsA(isA<StateError>().having(
        (e) => e.message,
        'message',
        'LOCAL_PROFILE_GENERATOR_INVALID',
      )),
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
      throwsA(isA<StateError>().having(
        (e) => e.message,
        'message',
        'LOCAL_PROFILE_ID_NOT_PERSISTED',
      )),
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
      throwsA(isA<StateError>().having(
        (e) => e.message,
        'message',
        'LOCAL_PROFILE_MIGRATION_REQUIRED',
      )),
    );
    expect(checked, 1);
    expect(savedId, isNull);
    expect(writeCount, 0);
  });

  test('fresh-install guard is not reapplied to a persisted valid profile',
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
  });

}
