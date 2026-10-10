import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

Map<String, dynamic> fixture() =>
    jsonDecode(
          File(
            'test/core/database/fixtures/app_database_v9.json',
          ).readAsStringSync(),
        )
        as Map<String, dynamic>;

sqlite.Database createV9() {
  final schema = fixture();
  expect(schema['schemaVersion'], 9);
  expect(schema['sourceHead'], '3d95a5ad5facd4599f764b73b10637270a41a1a7');
  final raw = sqlite.sqlite3.openInMemory();
  raw.execute('PRAGMA foreign_keys = OFF');
  final tables = (schema['tables'] as Map).cast<String, String>();
  expect(tables, hasLength(14));
  for (final sql in tables.values) {
    raw.execute(sql);
  }
  final indexes = (schema['indexes'] as Map).cast<String, String>();
  expect(indexes, hasLength(7));
  for (final sql in indexes.values) {
    raw.execute(sql);
  }
  raw.execute('PRAGMA user_version = 9');

  // Populate EVERY preexisting table, including nullable fields. SQL fixtures
  // are independent of the target v10 model and retain byte-exact UTF-8 payloads.
  for (final table in tables.keys.where((name) => name != 'sync_queue_table')) {
    final columns = raw.select('PRAGMA table_info("$table")');
    final values = <Object?>[];
    for (final column in columns) {
      final name = column['name'] as String;
      final type = column['type'] as String;
      Object value = type == 'TEXT'
          ? 'v9-$table-$name-á'
          : type == 'REAL'
          ? 2.5
          : 1;
      if (name == 'id' && type == 'TEXT') value = 'v9-$table';
      if (table == 'flashcards' && name == 'subject_id') value = 'v9-subjects';
      if (table == 'health_entries') {
        if (name == 'doc_id') value = '2026-08-21';
        if (name == 'water_intake_ml') value = 1250;
        if (name == 'menstrual_cycle_json')
          value = ' {"cycleLength":28,"nota":"á"} \r\n';
      }
      values.add(value);
    }
    final names = columns.map((c) => '"${c['name']}"').join(',');
    raw.execute(
      'INSERT INTO "$table" ($names) VALUES (${List.filled(values.length, '?').join(',')})',
      values,
    );
  }
  final rows = [
    [
      'user-a',
      'pending',
      7,
      0,
      ' { "waterIntakeMl" : 1500, "nota":"água" } \r\n',
    ],
    ['user-a', 'succeeded', 4, 1, '{"waterIntakeMl":1250}\n'],
    ['user-a', 'rejected', 9, 0, '{ "waterIntakeMl":1000,"nota":"rejeição" }'],
    ['user-b', 'pending', 3, 0, '{"waterIntakeMl":250,"nota":"outro UID"}'],
    [null, 'pending', 0, 0, ' {"waterIntakeMl":750} '],
  ];
  for (var i = 0; i < rows.length; i++) {
    final row = rows[i];
    raw.execute(
      '''INSERT INTO sync_queue_table
      (id, owner_uid, collection, doc_id, operation_type, payload_json,
       created_at, is_synced, status, last_error_code, attempt_count, last_attempt_at)
      VALUES (?, ?, 'health_info', '2026-08-21', 'update', ?, 123456789, ?, ?, 'KEEP_ERROR', ?, 987654321)''',
      [i + 101, row[0], row[4], row[3], row[1], row[2]],
    );
  }
  raw.execute('PRAGMA foreign_keys = ON');
  expect(raw.select('PRAGMA foreign_key_check'), isEmpty);
  return raw;
}

Map<String, List<Map<String, Object?>>> contents(sqlite.Database raw) => {
  for (final name in (fixture()['tables'] as Map).keys)
    name as String: [
      for (final row in raw.select('SELECT * FROM "$name" ORDER BY rowid'))
        Map<String, Object?>.from(row),
    ],
  'sqlite_sequence': [
    for (final row in raw.select('SELECT * FROM sqlite_sequence ORDER BY name'))
      Map<String, Object?>.from(row),
  ],
};
List<String> payloadBytes(sqlite.Database raw) => raw
    .select(
      'SELECT hex(CAST(payload_json AS BLOB)) AS bytes FROM sync_queue_table ORDER BY id',
    )
    .map((row) => row['bytes'] as String)
    .toList();
int version(sqlite.Database raw) =>
    raw.select('PRAGMA user_version').single['user_version'] as int;
Map<String, String> schema(sqlite.Database raw) => {
  for (final row in raw.select(
    "SELECT name, sql FROM sqlite_master WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%' ORDER BY name",
  ))
    row['name'] as String: row['sql'] as String,
};

class _MigrationFailure extends QueryInterceptor {
  _MigrationFailure({this.failCommit = false});
  final bool failCommit;
  bool firstTableCreated = false;
  // NativeDatabase migrations use a BeforeOpenRunner rather than the normal
  // outer executor. Wrap that exact runner so failures hit real migration SQL.
  @override
  Future<bool> ensureOpen(QueryExecutor executor, QueryExecutorUser user) =>
      executor.ensureOpen(_MigrationUser(user, this));
  @override
  Future<void> runCustom(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    if (!failCommit &&
        statement.contains('CREATE TABLE') &&
        statement.contains('"water_v2_intents"')) {
      expect(firstTableCreated, isTrue);
      throw StateError('TEST_SECOND_TABLE_FAILURE');
    }
    await super.runCustom(executor, statement, args);
    if (statement.contains('CREATE TABLE') &&
        statement.contains('"water_v2_daily_states"'))
      firstTableCreated = true;
  }

  @override
  Future<void> commitTransaction(TransactionExecutor inner) async {
    if (failCommit) {
      expect(firstTableCreated, isTrue);
      throw StateError('TEST_MIGRATION_COMMIT_FAILURE');
    }
    await super.commitTransaction(inner);
  }
}

class _MigrationUser implements QueryExecutorUser {
  _MigrationUser(this.user, this.interceptor);
  final QueryExecutorUser user;
  final QueryInterceptor interceptor;
  @override
  int get schemaVersion => user.schemaVersion;
  @override
  Future<void> beforeOpen(QueryExecutor executor, OpeningDetails details) =>
      user.beforeOpen(executor.interceptWith(interceptor), details);
}

void main() {
  test(
    'new database creates schema 10 with 16 tables, empty V2 and all original indexes',
    () async {
      final raw = sqlite.sqlite3.openInMemory();
      final db = AppDatabase(
        executor: NativeDatabase.opened(raw, closeUnderlyingOnClose: false),
      );
      addTearDown(raw.dispose);
      addTearDown(db.close);
      expect(await db.select(db.waterV2DailyStates).get(), isEmpty);
      expect(await db.select(db.waterV2Intents).get(), isEmpty);
      expect(version(raw), 10);
      expect(db.allTables, hasLength(16));
      for (final entry in (fixture()['tables'] as Map).entries) {
        expect(schema(raw)[entry.key], entry.value);
      }
      for (final entry in (fixture()['indexes'] as Map).entries) {
        expect(schema(raw)[entry.key], entry.value);
      }
    },
  );

  test(
    'real v9 to v10 preserves every old row, schema, queue state and payload bytes',
    () async {
      final raw = createV9();
      final before = contents(raw);
      final beforeSchema = schema(raw);
      final bytes = payloadBytes(raw);
      expect(version(raw), 9);
      expect(beforeSchema, hasLength(21));
      final db = AppDatabase(
        executor: NativeDatabase.opened(raw, closeUnderlyingOnClose: false),
      );
      addTearDown(raw.dispose);
      addTearDown(db.close);
      expect(await db.select(db.waterV2Intents).get(), isEmpty);
      expect(await db.select(db.waterV2DailyStates).get(), isEmpty);
      expect(version(raw), 10);
      expect(db.allTables, hasLength(16));
      expect(contents(raw), before);
      expect(payloadBytes(raw), bytes);
      for (final entry in beforeSchema.entries) {
        expect(schema(raw)[entry.key], entry.value);
      }
      expect(schema(raw), hasLength(23));
      final rows = await db.select(db.syncQueueTable).get();
      expect(rows.map((r) => r.status), [
        'pending',
        'succeeded',
        'rejected',
        'pending',
        'pending',
      ]);
      expect(rows.map((r) => r.ownerUid), [
        'user-a',
        'user-a',
        'user-a',
        'user-b',
        null,
      ]);
      expect(rows.map((r) => r.attemptCount), [7, 4, 9, 3, 0]);
      expect(rows.every((r) => r.lastErrorCode == 'KEEP_ERROR'), isTrue);
      expect(rows.map((r) => r.id), [101, 102, 103, 104, 105]);
      final health = await db.select(db.healthEntries).getSingle();
      expect(health.waterIntakeMl, 1250);
      expect(health.hasTakenPillToday, isTrue);
      expect(health.menstrualCycleJson, ' {"cycleLength":28,"nota":"á"} \r\n');
      expect(await db.getPendingSyncItems('user-a'), hasLength(1));
      expect(await db.hasRejectedSyncItems('user-a'), isTrue);
      expect(await db.select(db.medications).get(), hasLength(1));
      expect(await db.select(db.flashcards).get(), hasLength(1));
      expect(await db.select(db.notificationsTable).get(), hasLength(1));
      expect(raw.select('PRAGMA foreign_key_check'), isEmpty);
    },
  );

  for (final commitFailure in [false, true]) {
    test(
      'migration failure ${commitFailure ? 'at commit' : 'on second CREATE'} rolls back and v9 can reopen',
      () async {
        final raw = createV9();
        final before = contents(raw);
        final beforeSchema = schema(raw);
        final bytes = payloadBytes(raw);
        final failure = _MigrationFailure(failCommit: commitFailure);
        final failed = AppDatabase(
          executor: NativeDatabase.opened(
            raw,
            closeUnderlyingOnClose: false,
          ).interceptWith(failure),
        );
        addTearDown(raw.dispose);
        addTearDown(failed.close);
        await expectLater(
          failed.select(failed.waterV2Intents).get(),
          throwsStateError,
        );
        expect(version(raw), 9);
        expect(contents(raw), before);
        expect(payloadBytes(raw), bytes);
        expect(schema(raw), beforeSchema);
        await failed.close();
        final reopened = AppDatabase(
          executor: NativeDatabase.opened(raw, closeUnderlyingOnClose: false),
        );
        addTearDown(reopened.close);
        expect(await reopened.select(reopened.waterV2Intents).get(), isEmpty);
        expect(version(raw), 10);
        expect(contents(raw), before);
        expect(payloadBytes(raw), bytes);
      },
    );
  }
}
