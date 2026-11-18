import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/database_sync_policy.dart';
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
        assertFreshInstall: () async {},
      ),
      openDatabase: (identity) async {
        openCount++;
        return AppDatabase.forUser(
          identity: identity,
          executor: NativeDatabase.memory(),
          syncPolicy: DatabaseSyncPolicy.localOnly,
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

  test(
    'does not open a new profile over a legacy encrypted database',
    () async {
      await File(
        '${directory.path}/life_os_u_old.sqlite',
      ).writeAsString('encrypted');

      await expectLater(session.open(), throwsA(isA<StateError>()));
      expect(session.currentLocalId, isNull);
      expect(openCount, 0);
    },
  );

  test('disposed local session cannot reopen an existing database', () async {
    await session.open();
    await session.dispose();

    expect(session.currentLocalId, isNull);
    expect(session.requirePrepared, throwsA(isA<SessionDatabaseUnavailable>()));
    await expectLater(
      session.open(),
      throwsA(isA<SessionDatabaseUnavailable>()),
    );
  });
  LocalDeviceSession controlled(
    Future<AppDatabase> Function(LocalDatabaseIdentity) opener, {
    Future<String?> Function()? reader,
  }) => LocalDeviceSession(
    identityService: LocalInstallationIdentityService(
      readSavedId: reader ?? () async => savedId,
      writeSavedId: (value) async => savedId = value,
      documentsDirectory: () async => directory,
      newId: () => id,
      assertFreshInstall: () async {},
    ),
    openDatabase: opener,
  );

  test('all dispose callers await a pending close', () async {
    await session.dispose();
    final closeStarted = Completer<void>();
    final closing = Completer<void>();
    final database = _ControlledCloseDatabase(
      LocalDatabaseIdentity(id),
      () async {
        closeStarted.complete();
        await closing.future;
      },
    );
    session = controlled((_) async => database);
    await session.open();
    final first = session.dispose();
    await closeStarted.future;
    var secondCompleted = false;
    final second = session.dispose().then((_) => secondCompleted = true);
    try {
      await Future<void>.delayed(Duration.zero);
      expect(secondCompleted, isFalse);
    } finally {
      closing.complete();
      await Future.wait([first, second]);
    }
    expect(database.closeCount, 1);
  });

  test('rejects and closes an opener that grants remote access', () async {
    await session.dispose();
    final database = _RemoteCloseDatabase(LocalDatabaseIdentity(id));
    session = controlled((_) async => database);
    await expectLater(
      session.open(),
      throwsA(
        predicate(
          (Object? error) =>
              error.toString().contains('LOCAL_PROFILE_SYNC_POLICY_REQUIRED'),
        ),
      ),
    );
    expect(database.closedBySession, isTrue);
    expect(session.currentLocalId, isNull);
    expect(session.requirePrepared, throwsA(isA<SessionDatabaseUnavailable>()));
  });

  test(
    'dispose during identity resolution prevents database opening',
    () async {
      await session.dispose();
      final reading = Completer<void>();
      final marker = Completer<String?>();
      session = controlled(
        (identity) async {
          openCount++;
          return AppDatabase.forUser(
            identity: identity,
            executor: NativeDatabase.memory(),
            syncPolicy: DatabaseSyncPolicy.localOnly,
          );
        },
        reader: () {
          reading.complete();
          return marker.future;
        },
      );
      final opening = expectLater(
        session.open(),
        throwsA(isA<SessionDatabaseUnavailable>()),
      );
      await reading.future;
      await session.dispose();
      marker.complete(id);
      await opening;
      expect(openCount, 0);
      expect(session.currentLocalId, isNull);
    },
  );

  test('late candidate after dispose is closed without publication', () async {
    await session.dispose();
    final openingStarted = Completer<void>();
    final candidate = Completer<AppDatabase>();
    final database = _ControlledCloseDatabase(
      LocalDatabaseIdentity(id),
      () async {},
    );
    session = controlled((_) {
      openingStarted.complete();
      return candidate.future;
    });
    final opening = expectLater(
      session.open(),
      throwsA(isA<SessionDatabaseUnavailable>()),
    );
    await openingStarted.future;
    final disposing = session.dispose();
    candidate.complete(database);
    await opening;
    await disposing;
    expect(database.closeCount, 1);
    expect(session.currentLocalId, isNull);
    expect(session.requirePrepared, throwsA(isA<SessionDatabaseUnavailable>()));
  });

  test('concurrent opening failures reset state and allow retry', () async {
    await session.dispose();
    var failing = true;
    session = controlled((identity) async {
      openCount++;
      if (failing) throw StateError('OPEN_FAILED');
      return AppDatabase.forUser(
        identity: identity,
        executor: NativeDatabase.memory(),
        syncPolicy: DatabaseSyncPolicy.localOnly,
      );
    });
    await Future.wait([
      expectLater(session.open(), throwsA(anything)),
      expectLater(session.open(), throwsA(anything)),
    ]);
    expect(session.currentLocalId, isNull);
    expect(session.requirePrepared, throwsA(isA<SessionDatabaseUnavailable>()));
    failing = false;
    final database = await session.open();
    expect(session.requirePrepared(), same(database));
    expect(openCount, 2);
  });

  test('wrong identity candidate is closed and rejected', () async {
    await session.dispose();
    final database = _ControlledCloseDatabase(
      LocalDatabaseIdentity('local-v1-223e4567-e89b-42d3-a456-426614174000'),
      () async {},
    );
    session = controlled((_) async => database);
    await expectLater(
      session.open(),
      throwsA(isA<SessionDatabaseUnavailable>()),
    );
    expect(database.closeCount, 1);
    expect(session.currentLocalId, isNull);
    expect(session.requirePrepared, throwsA(isA<SessionDatabaseUnavailable>()));
  });

  test('cached identity cannot switch when the saved marker changes', () async {
    final database = await session.open();
    savedId = 'local-v1-123e4567-e89b-42d3-a456-426614174001';
    expect(await session.open(), same(database));
    expect(session.currentLocalId, id);
    expect(openCount, 1);
  });

  test(
    'all dispose callers observe close failure and session stays sealed',
    () async {
      await session.dispose();
      final database = _ControlledCloseDatabase(
        LocalDatabaseIdentity(id),
        () async {
          throw StateError('CLOSE_FAILED');
        },
      );
      session = controlled((_) async => database);
      await session.open();
      try {
        final first = session.dispose();
        final second = session.dispose();
        await Future.wait([
          expectLater(first, throwsA(isA<StateError>())),
          expectLater(second, throwsA(isA<StateError>())),
        ]);
        expect(database.closeCount, 1);
        expect(session.currentLocalId, isNull);
        expect(
          session.requirePrepared,
          throwsA(isA<SessionDatabaseUnavailable>()),
        );
        await expectLater(
          session.open(),
          throwsA(isA<SessionDatabaseUnavailable>()),
        );
        await expectLater(session.dispose(), throwsA(isA<StateError>()));
      } finally {
        // Release only the in-memory executor after the simulated close error.
        await database.close();
        session = controlled(
          (identity) async => AppDatabase.forUser(
            identity: identity,
            executor: NativeDatabase.memory(),
            syncPolicy: DatabaseSyncPolicy.localOnly,
          ),
        );
      }
    },
  );
}

class _ControlledCloseDatabase extends AppDatabase {
  _ControlledCloseDatabase(LocalDatabaseIdentity identity, this.onClose)
    : super.forUser(
        identity: identity,
        executor: NativeDatabase.memory(),
        syncPolicy: DatabaseSyncPolicy.localOnly,
      );
  final Future<void> Function() onClose;
  int closeCount = 0;
  @override
  Future<void> closeDatabase() async {
    closeCount++;
    await onClose();
    await super.closeDatabase();
  }
}

class _RemoteCloseDatabase extends AppDatabase {
  _RemoteCloseDatabase(LocalDatabaseIdentity identity)
    : super.forUser(identity: identity, executor: NativeDatabase.memory());
  bool closedBySession = false;
  @override
  Future<void> closeDatabase() async {
    closedBySession = true;
    await super.closeDatabase();
  }
}
