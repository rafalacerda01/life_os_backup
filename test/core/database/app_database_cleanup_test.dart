import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

// Observe actual SQLite pragmas and delegate to the real executor. These tests
// prove commit configuration and ordering, not physical power-loss durability.
class _CleanupInterceptor extends QueryInterceptor {
  _CleanupInterceptor(this.raw);

  final sqlite.Database raw;
  final events = <String>[];
  bool armed = false;
  int deleteCalls = 0;
  int? failDeleteAt;
  bool failCommit = false;
  bool failRestore = false;
  QueryExecutor? exclusive;
  Future<void> Function()? afterCommit;
  Completer<void>? readSubmitted;

  int get synchronous =>
      raw.select('PRAGMA synchronous').single.values.single as int;

  @override
  QueryExecutor beginExclusive(QueryExecutor parent) {
    final result = super.beginExclusive(parent);
    if (armed) {
      exclusive = result;
      events.add('exclusive');
    }
    return result;
  }

  @override
  TransactionExecutor beginTransaction(QueryExecutor parent) {
    if (armed) events.add('begin:$synchronous');
    return super.beginTransaction(parent);
  }

  @override
  Future<void> runCustom(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    if (armed && failRestore && statement == 'PRAGMA synchronous = NORMAL') {
      throw StateError('TEST_RESTORE_FAILURE');
    }
    await super.runCustom(executor, statement, args);
    if (armed) events.add(statement);
  }

  @override
  Future<int> runDelete(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    if (armed) {
      events.add('delete:$synchronous');
      deleteCalls++;
      if (deleteCalls == failDeleteAt) throw StateError('TEST_DELETE_FAILURE');
    }
    return super.runDelete(executor, statement, args);
  }

  @override
  Future<void> commitTransaction(TransactionExecutor inner) async {
    if (armed) {
      events.add('commit-start:$synchronous');
      if (failCommit) throw StateError('TEST_COMMIT_FAILURE');
    }
    await super.commitTransaction(inner);
    if (armed) {
      events.add('commit-done:$synchronous');
      await afterCommit?.call();
    }
  }

  @override
  Future<void> rollbackTransaction(TransactionExecutor inner) async {
    await super.rollbackTransaction(inner);
    if (armed) events.add('rollback:$synchronous');
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    if (armed && statement == 'PRAGMA synchronous') {
      readSubmitted?.complete();
      readSubmitted = null;
    }
    final result = await super.runSelect(executor, statement, args);
    if (armed && statement == 'PRAGMA synchronous') events.add('read-done');
    return result;
  }

  @override
  Future<void> close(QueryExecutor inner) async {
    if (armed && identical(inner, exclusive))
      events.add('release:$synchronous');
    await super.close(inner);
  }
}

void main() {
  late Directory directory;
  late sqlite.Database raw;
  late _CleanupInterceptor interceptor;
  late AppDatabase db;

  Future<int> synchronous() async =>
      (await db.customSelect('PRAGMA synchronous').getSingle()).read<int>(
        'synchronous',
      );

  Future<Map<String, int>> counts() async {
    final result = <String, int>{};
    for (final table in db.allTables) {
      result[table.actualTableName] =
          (await db
                  .customSelect(
                    'SELECT COUNT(*) AS count FROM "${table.actualTableName}"',
                  )
                  .getSingle())
              .read<int>('count');
    }
    return result;
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('life_os_cleanup_');
    raw = sqlite.sqlite3.open('${directory.path}/cleanup.sqlite');
    raw.execute('PRAGMA journal_mode = WAL');
    raw.execute('PRAGMA synchronous = NORMAL');
    raw.execute('PRAGMA foreign_keys = ON');
    interceptor = _CleanupInterceptor(raw);
    db = AppDatabase(
      executor: NativeDatabase.opened(raw).interceptWith(interceptor),
    );
    await db
        .into(db.healthEntries)
        .insert(
          HealthEntriesCompanion.insert(
            docId: '2026-09-02',
            date: DateTime(2026, 9, 2),
          ),
        );
    await db
        .into(db.taskTable)
        .insert(
          TaskTableCompanion.insert(
            id: 'task-a',
            title: 'Test task',
            priority: 'normal',
            date: DateTime(2026, 9, 2),
          ),
        );
    await db
        .into(db.subjects)
        .insert(
          SubjectsCompanion.insert(
            id: 'subject-a',
            title: 'Test subject',
            cardsToReview: 1,
            streakDays: 0,
            progress: 0,
            hasExam: false,
          ),
        );
    await db
        .into(db.flashcards)
        .insert(
          FlashcardsCompanion.insert(
            id: 'card-a',
            subjectId: 'subject-a',
            question: 'Question',
            answer: 'Answer',
          ),
        );
    await db.insertSyncItem(
      ownerUid: 'user-a',
      collection: 'tasks',
      docId: 'task-a',
      operationType: 'create',
      payloadJson: '{}',
    );
    interceptor.armed = true;
  });

  tearDown(() async {
    await db.close();
    await directory.delete(recursive: true);
  });

  test(
    'cleanup clears all tables and restores NORMAL after a FULL WAL commit',
    () async {
      expect(raw.select('PRAGMA journal_mode').single.values.single, 'wal');
      expect(await synchronous(), 1);
      expect((await counts()).values.where((count) => count > 0), hasLength(5));
      interceptor.events.clear();

      await db.clearAllData();

      expect(interceptor.events, <String>[
        'exclusive',
        'PRAGMA synchronous = FULL',
        'PRAGMA foreign_keys = OFF',
        'begin:2',
        for (final _ in db.allTables) 'delete:2',
        'commit-start:2',
        'commit-done:2',
        'PRAGMA foreign_keys = ON',
        'PRAGMA synchronous = NORMAL',
        'release:1',
      ]);
      expect((await counts()).values, everyElement(0));
      expect(await synchronous(), 1);
      expect(raw.select('PRAGMA foreign_keys').single.values.single, 1);
      expect(raw.select('PRAGMA journal_mode').single.values.single, 'wal');
      await db.clearAllData();
      expect((await counts()).values, everyElement(0));
      expect(await synchronous(), 1);
    },
  );

  test(
    'delete failure propagates, rolls back earlier deletes and restores NORMAL',
    () async {
      final before = await counts();
      interceptor.failDeleteAt = 2;

      await expectLater(
        db.clearAllData(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'TEST_DELETE_FAILURE',
          ),
        ),
      );

      expect((await counts()), before);
      expect(interceptor.events, contains('rollback:2'));
      expect(interceptor.events, isNot(contains('commit-done:2')));
      expect(await synchronous(), 1);
      expect(raw.select('PRAGMA foreign_keys').single.values.single, 1);
      interceptor.failDeleteAt = null;
      await db.clearAllData();
      expect((await counts()).values, everyElement(0));
    },
  );

  test(
    'commit failure propagates and restores NORMAL after rollback',
    () async {
      final before = await counts();
      interceptor.failCommit = true;

      await expectLater(
        db.clearAllData(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'TEST_COMMIT_FAILURE',
          ),
        ),
      );

      expect(await counts(), before);
      expect(interceptor.events, contains('commit-start:2'));
      expect(interceptor.events, contains('rollback:2'));
      expect(await synchronous(), 1);
    },
  );

  test('restore failure is not reported as successful cleanup', () async {
    interceptor.failRestore = true;

    await expectLater(
      db.clearAllData(),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'TEST_RESTORE_FAILURE',
        ),
      ),
    );

    expect((await counts()).values, everyElement(0));
    expect(interceptor.events, contains('commit-done:2'));
    expect(await synchronous(), 2);
    interceptor.failRestore = false;
    await db.clearAllData();
    expect(await synchronous(), 1);
  });

  test('simultaneous delete and restore failures still fail closed', () async {
    final before = await counts();
    interceptor.failDeleteAt = 2;
    interceptor.failRestore = true;

    await expectLater(db.clearAllData(), throwsA(isA<StateError>()));

    expect(await counts(), before);
    expect(interceptor.events, contains('rollback:2'));
    expect(await synchronous(), 2);
  });

  test(
    'concurrent read waits through post-commit restoration inside exclusivity',
    () async {
      final committed = Completer<void>();
      final allowRestore = Completer<void>();
      final submitted = Completer<void>();
      interceptor.afterCommit = () async {
        committed.complete();
        await allowRestore.future;
      };
      final cleanup = db.clearAllData();
      await committed.future;
      expect(interceptor.synchronous, 2);

      // Submit after the transaction has committed: only exclusively(), not the
      // transaction lock, can keep this read behind pragma restoration.
      interceptor.readSubmitted = submitted;
      final concurrentRead = synchronous();
      try {
        await submitted.future;
        expect(interceptor.events, isNot(contains('release:1')));
      } finally {
        allowRestore.complete();
      }
      await cleanup;
      expect(await concurrentRead, 1);
      expect(
        interceptor.events.indexOf('read-done'),
        greaterThan(interceptor.events.indexOf('release:1')),
      );
    },
  );
}
