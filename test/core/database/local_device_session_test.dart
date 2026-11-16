import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/local_database_identity.dart';
import 'package:life_os/core/database/local_device_session.dart';
import 'package:life_os/core/database/local_installation_identity_service.dart';
import 'package:life_os/core/database/session_database_coordinator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const id = 'local-v1-123e4567-e89b-42d3-a456-426614174000';

  late Directory directory;
  String? savedId;
  int openCount = 0;
  late LocalDeviceSession session;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('lifeos-session-');
    savedId = null;
    openCount = 0;
    session = LocalDeviceSession(
      identityService: LocalInstallationIdentityService(
        readSavedId: () async => savedId,
        writeSavedId: (value) async => savedId = value,
        documentsDirectory: () async => directory,
        newId: () => id,
      ),
      openDatabase: (identity) async {
        openCount++;
        return AppDatabase.forUser(
          identity: identity,
          executor: NativeDatabase.memory(),
        );
      },
    );
  });

  tearDown(() async {
    await session.dispose();
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  test('opens an explicit local database with no Firebase user', () async {
    final db = await session.open();

    expect(db.identity, LocalDatabaseIdentity(id));
    expect(session.currentLocalId, id);
    expect(session.requirePrepared(), same(db));
    expect(await db.customSelect('SELECT 1').get(), hasLength(1));
    expect(openCount, 1);
  });

  test('concurrent opens reuse the same prepared database', () async {
    final databases = await Future.wait([session.open(), session.open()]);

    expect(databases.first, same(databases.last));
    expect(openCount, 1);
  });

  test('does not open a new profile over a legacy encrypted database',
      () async {
    await File('${directory.path}/life_os_u_old.sqlite')
        .writeAsString('encrypted');

    await expectLater(session.open(), throwsA(isA<StateError>()));
    expect(session.currentLocalId, isNull);
    expect(openCount, 0);
  });

  test('disposed local session cannot reopen an existing database',
      () async {
    await session.open();
    await session.dispose();

    expect(session.currentLocalId, isNull);
    expect(session.requirePrepared, throwsA(isA<SessionDatabaseUnavailable>()));
    await expectLater(
      session.open(),
      throwsA(isA<SessionDatabaseUnavailable>()),
    );
  });
}
