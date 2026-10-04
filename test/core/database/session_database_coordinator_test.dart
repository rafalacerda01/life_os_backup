import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/local_database_identity.dart';
import 'package:life_os/core/database/local_mutation_gate.dart';
import 'package:life_os/core/database/session_database_coordinator.dart';
import 'package:life_os/core/database/user_database_factory.dart';
import 'package:life_os/core/db/user_db_key_manager.dart';

import '../db/fake_secure_storage.dart';

class _ObservedDatabase extends AppDatabase {
  _ObservedDatabase(LocalDatabaseIdentity identity, this.events)
    : super.forUser(identity: identity, executor: NativeDatabase.memory());
  final List<String> events;
  int closeCalls = 0;
  bool failClose = false;
  @override
  Future<void> closeDatabase() async {
    closeCalls++;
    if (failClose) throw StateError('close-failure');
    await super.closeDatabase();
    events.add('closed-${identity!.uid}');
  }
}

Future<void> _seed(AppDatabase db, String id) => db
    .into(db.taskTable)
    .insert(
      TaskTableCompanion.insert(
        id: id,
        title: id,
        priority: 'normal',
        date: DateTime(2026, 10, 4),
      ),
    )
    .then((_) {});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late String? uid;
  late List<String> events;
  late SessionDatabaseCoordinator coordinator;
  late List<_ObservedDatabase> opened;

  setUp(() {
    uid = null;
    events = [];
    opened = [];
    coordinator = SessionDatabaseCoordinator(
      currentUserId: () => uid,
      openDatabase: (identity) async {
        events.add('open-${identity.uid}');
        final db = _ObservedDatabase(identity, events);
        opened.add(db);
        return db;
      },
      onChanged: (snapshot) {
        if (snapshot.phase == SessionDatabasePhase.prepared)
          events.add('published-${snapshot.identity!.uid}');
      },
    );
  });
  tearDown(() async {
    for (final db in opened) {
      db.failClose = false;
    }
    await coordinator.dispose();
  });

  test('signed out is detached and never opens a database', () {
    expect(coordinator.snapshot.phase, SessionDatabasePhase.detached);
    expect(
      coordinator.requirePrepared,
      throwsA(isA<SessionDatabaseUnavailable>()),
    );
    expect(opened, isEmpty);
  });

  test('cold start opens only explicit A and prepares its gate', () async {
    uid = 'a';
    final db = await coordinator.prepare('a');
    expect(coordinator.requirePrepared(), same(db));
    expect(db.identity, LocalDatabaseIdentity('a'));
    await _seed(db, 'a-row');
    expect(events, ['open-a', 'published-a']);
  });

  test(
    'publication waits for preparation and rejects writes beforehand',
    () async {
      uid = 'a';
      final started = Completer<void>();
      final release = Completer<void>();
      final opening = coordinator.prepare(
        'a',
        beforePublish: () async {
          started.complete();
          await release.future;
        },
      );
      await started.future;
      expect(
        coordinator.requirePrepared,
        throwsA(isA<SessionDatabaseUnavailable>()),
      );
      await expectLater(
        _seed(opened.single, 'early'),
        throwsA(isA<LocalMutationUnavailable>()),
      );
      release.complete();
      await opening;
      expect(coordinator.snapshot.phase, SessionDatabasePhase.prepared);
    },
  );

  test('same UID concurrent prepare opens once', () async {
    uid = 'a';
    final result = await Future.wait([
      coordinator.prepare('a'),
      coordinator.prepare('a'),
    ]);
    expect(result[0], same(result[1]));
    expect(opened, hasLength(1));
  });

  test('A closes before B opens and publishes', () async {
    uid = 'a';
    await coordinator.prepare('a');
    uid = 'b';
    coordinator.observeSession(uid);
    expect(
      coordinator.requirePrepared,
      throwsA(isA<SessionDatabaseUnavailable>()),
    );
    final b = await coordinator.prepare('b');
    expect(events, [
      'open-a',
      'published-a',
      'closed-a',
      'open-b',
      'published-b',
    ]);
    expect(await b.select(b.taskTable).get(), isEmpty);
  });

  test(
    'UID changes while A opens: stale candidate closes and B wins',
    () async {
      await coordinator.dispose();
      final started = Completer<void>();
      final release = Completer<void>();
      coordinator = SessionDatabaseCoordinator(
        currentUserId: () => uid,
        openDatabase: (identity) async {
          final db = _ObservedDatabase(identity, events);
          opened.add(db);
          if (identity.uid == 'a') {
            started.complete();
            await release.future;
          }
          return db;
        },
      );
      uid = 'a';
      final a = coordinator.prepare('a');
      final rejected = expectLater(
        a,
        throwsA(isA<SessionDatabaseUnavailable>()),
      );
      await started.future;
      uid = 'b';
      final b = coordinator.prepare('b');
      release.complete();
      await rejected;
      await b;
      expect(coordinator.requirePrepared().identity!.uid, 'b');
      expect(opened.first.closeCalls, 1);
    },
  );

  test('close failure blocks opening B and remains retryable', () async {
    uid = 'a';
    final a = await coordinator.prepare('a') as _ObservedDatabase;
    a.failClose = true;
    uid = 'b';
    await expectLater(coordinator.prepare('b'), throwsStateError);
    expect(opened, hasLength(1));
    expect(
      coordinator.requirePrepared,
      throwsA(isA<SessionDatabaseUnavailable>()),
    );
    a.failClose = false;
    await coordinator.prepare('b');
    expect(events.indexOf('closed-a'), lessThan(events.indexOf('open-b')));
  });

  test(
    'detach seals immediately and drains late A writes before closing',
    () async {
      uid = 'a';
      final a = await coordinator.prepare('a');
      final started = Completer<void>();
      final release = Completer<void>();
      final mutation = a.localMutations.run(() async {
        started.complete();
        await release.future;
        await _seed(a, 'late');
      });
      final rejected = expectLater(
        mutation,
        throwsA(isA<LocalMutationUnavailable>()),
      );
      await started.future;
      uid = 'b';
      final detach = coordinator.detach(expectedUid: 'a');
      final b = coordinator.prepare('b');
      expect(events, isNot(contains('closed-a')));
      expect(opened, hasLength(1));
      release.complete();
      await rejected;
      await detach;
      final dbB = await b;
      expect(await dbB.select(dbB.taskTable).get(), isEmpty);
    },
  );

  test(
    'old inherited producer cannot capture or write through B gate',
    () async {
      uid = 'a';
      final a = await coordinator.prepare('a');
      final started = Completer<void>();
      final release = Completer<void>();
      Future<void>? late;
      await a.localMutations.run(() async {
        late = Future<void>(() async {
          started.complete();
          await release.future;
          await _seed(coordinator.requirePrepared(), 'wrong-owner');
        });
      });
      final rejected = expectLater(
        late!,
        throwsA(isA<LocalMutationUnavailable>()),
      );
      await started.future;
      uid = 'b';
      final b = await coordinator.prepare('b');
      release.complete();
      await rejected;
      expect(await b.select(b.taskTable).get(), isEmpty);
    },
  );

  test('stale detach A never detaches prepared B', () async {
    uid = 'a';
    await coordinator.prepare('a');
    uid = 'b';
    final b = await coordinator.prepare('b');
    await coordinator.detach(expectedUid: 'a');
    expect(coordinator.requirePrepared(), same(b));
  });

  test('dispose closes exactly once and rejects preparation', () async {
    uid = 'a';
    final db = await coordinator.prepare('a') as _ObservedDatabase;
    await Future.wait([coordinator.dispose(), coordinator.dispose()]);
    expect(db.closeCalls, 1);
    await expectLater(
      coordinator.prepare('a'),
      throwsA(isA<SessionDatabaseUnavailable>()),
    );
  });

  test(
    'real encrypted A logout relogin preserves file key rows and isolated B',
    () async {
      await coordinator.dispose();
      final directory = Directory.systemTemp.createTempSync(
        'session_encrypted_',
      );
      final storage = FakeSecureStorage();
      final keys = UserDbKeyManager(storage: storage);
      final factory = UserDatabaseFactory(
        keyManager: keys,
        directoryProvider: () async => directory,
      );
      final cleared = <String>[];
      coordinator = SessionDatabaseCoordinator(
        currentUserId: () => uid,
        openDatabase: factory.open,
        clearKeyCache: (identity) {
          cleared.add(identity.uid);
          keys.clearCache(identity);
        },
      );
      try {
        final legacy = File('${directory.path}/life_os.sqlite')
          ..writeAsStringSync('unowned');
        uid = 'a';
        final a = await coordinator.prepare('a');
        await _seed(a, 'a-row');
        final identityA = a.identity!;
        final keyA = storage.values[identityA.keyAlias];
        uid = null;
        await coordinator.detach(expectedUid: 'a');
        expect(identityA.fileIn(directory).existsSync(), isTrue);
        expect(storage.values[identityA.keyAlias], keyA);
        expect(cleared, ['a']);
        uid = 'b';
        final b = await coordinator.prepare('b');
        expect(await b.select(b.taskTable).get(), isEmpty);
        await _seed(b, 'b-row');
        uid = null;
        await coordinator.detach(expectedUid: 'b');
        final readsBefore = storage.reads[identityA.keyAlias]!;
        uid = 'a';
        final reopened = await coordinator.prepare('a');
        expect(
          (await reopened.select(reopened.taskTable).get()).single.id,
          'a-row',
        );
        expect(storage.reads[identityA.keyAlias], greaterThan(readsBefore));
        expect(storage.writes[identityA.keyAlias], 1);
        expect(legacy.readAsStringSync(), 'unowned');
        uid = 'b';
        final reopenedB = await coordinator.prepare('b');
        expect(
          (await reopenedB.select(reopenedB.taskTable).get()).single.id,
          'b-row',
        );
      } finally {
        await coordinator.dispose();
        directory.deleteSync(recursive: true);
      }
    },
  );
}
