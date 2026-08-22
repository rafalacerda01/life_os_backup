import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

void main() {
  test('migration v7 para v8 preserva e quarentena SyncQueue legada', () async {
    final rawDatabase = sqlite3.sqlite3.openInMemory();
    rawDatabase.execute('''
      CREATE TABLE sync_queue_table (
        id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
        collection TEXT NOT NULL,
        doc_id TEXT NOT NULL,
        operation_type TEXT NOT NULL,
        payload_json TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        is_synced INTEGER NOT NULL DEFAULT 0 CHECK (is_synced IN (0, 1))
      )
    ''');
    rawDatabase.execute(
      '''
        INSERT INTO sync_queue_table (
          collection,
          doc_id,
          operation_type,
          payload_json,
          created_at,
          is_synced
        ) VALUES (?, ?, ?, ?, ?, ?)
      ''',
      ['tasks', 'legacy-pending', 'create', '{"title":"Local"}', 1, 0],
    );
    rawDatabase.execute(
      '''
        INSERT INTO sync_queue_table (
          collection,
          doc_id,
          operation_type,
          payload_json,
          created_at,
          is_synced
        ) VALUES (?, ?, ?, ?, ?, ?)
      ''',
      ['habits', 'legacy-succeeded', 'delete', '{}', 2, 1],
    );
    rawDatabase.execute('PRAGMA user_version = 7');

    final db = AppDatabase(executor: NativeDatabase.opened(rawDatabase));
    addTearDown(db.closeDatabase);

    final rows = await db.select(db.syncQueueTable).get();

    expect(rows, hasLength(2));
    expect(rows[0].docId, 'legacy-pending');
    expect(rows[0].payloadJson, '{"title":"Local"}');
    expect(rows[0].ownerUid, isNull);
    expect(rows[0].status, SyncQueuePersistenceStatus.pending);
    expect(rows[0].attemptCount, 0);
    expect(rows[1].docId, 'legacy-succeeded');
    expect(rows[1].ownerUid, isNull);
    expect(rows[1].status, SyncQueuePersistenceStatus.succeeded);
    expect(rows[1].isSynced, isTrue);

    expect(await db.getPendingSyncItems('current-user'), isEmpty);
  });
}
