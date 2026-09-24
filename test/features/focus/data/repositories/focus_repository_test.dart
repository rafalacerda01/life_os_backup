import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:drift/native.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/services/sync_manager.dart';
import 'package:life_os/core/services/sync_queue_store.dart';
import 'package:life_os/core/services/sync_remote_data_source.dart';
import 'package:life_os/features/focus/data/repositories/focus_repository.dart';

class _FakeUser extends Fake implements User {
  @override
  final String uid;

  _FakeUser(this.uid);
}

class _FakeAuth extends Fake implements FirebaseAuth {
  @override
  User? currentUser = _FakeUser('user-a');
}

class _FakeRemote extends Fake implements SyncRemoteDataSource {}

class _RecordingSyncManager extends SyncManager {
  int calls = 0;
  Future<bool> Function()? onProcess;

  _RecordingSyncManager(AppDatabase db)
    : super(
        queueStore: AppDatabaseSyncQueueStore(db),
        remoteDataSource: _FakeRemote(),
        currentUserId: () => 'user-a',
      );

  @override
  Future<bool> processPendingItems() {
    calls++;
    return onProcess?.call() ?? Future.value(false);
  }
}

void main() {
  late AppDatabase db;
  late _FakeAuth auth;
  late _RecordingSyncManager syncManager;
  late FocusRepository repository;

  setUp(() {
    db = AppDatabase(executor: NativeDatabase.memory());
    auth = _FakeAuth();
    syncManager = _RecordingSyncManager(db);
    repository = FocusRepository(
      db,
      FakeFirebaseFirestore(),
      auth,
      syncManager,
    );
  });

  tearDown(() async => db.closeDatabase());

  test(
    'sessão autenticada salva local e enfileira payload mínimo por UID',
    () async {
      await repository.saveFocusSession('task-1', 'TASK', 1200);

      final logs = await db.select(db.focusLogs).get();
      final queue = await db.select(db.syncQueueTable).get();
      expect(logs, hasLength(1));
      expect(logs.single.targetId, 'task-1');
      expect(logs.single.durationSeconds, 1200);
      expect(queue, hasLength(1));
      final item = queue.single;
      expect(item.ownerUid, 'user-a');
      expect(item.collection, 'focus_logs');
      expect(item.operationType, 'create');
      expect(
        item.docId,
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );
      final payload = jsonDecode(item.payloadJson) as Map<String, dynamic>;
      expect(payload.keys.toSet(), {
        'targetId',
        'targetType',
        'durationSeconds',
        'timestamp',
      });
      expect(payload['targetId'], 'task-1');
      expect(payload['targetType'], 'TASK');
      expect(payload['durationSeconds'], 1200);
      expect(
        DateTime.parse(payload['timestamp'] as String).millisecondsSinceEpoch,
        logs.single.timestamp,
      );
      expect(syncManager.calls, 1);
    },
  );

  test('sem autenticação preserva log local sem owner artificial', () async {
    auth.currentUser = null;
    await repository.saveFocusSession('subject-1', 'SUBJECT', 600);

    expect(await db.select(db.focusLogs).get(), hasLength(1));
    expect(await db.select(db.syncQueueTable).get(), isEmpty);
    expect(syncManager.calls, 0);
  });

  test('falha no enqueue reverte também a inserção local', () async {
    await db.customStatement('''
      CREATE TRIGGER reject_focus_queue BEFORE INSERT ON sync_queue_table
      BEGIN SELECT RAISE(ABORT, 'test enqueue failure'); END;
    ''');

    await expectLater(
      repository.saveFocusSession('task-1', 'TASK', 1200),
      throwsA(isA<Exception>()),
    );
    expect(await db.select(db.focusLogs).get(), isEmpty);
    expect(await db.select(db.syncQueueTable).get(), isEmpty);
    expect(syncManager.calls, 0);
  });

  test('upload pendente não bloqueia a gravação offline', () async {
    final upload = Completer<bool>();
    syncManager.onProcess = () => upload.future;

    await repository.saveFocusSession('task-1', 'TASK', 1200);
    expect(syncManager.calls, 1);
    expect(await db.select(db.focusLogs).get(), hasLength(1));
    expect(await db.select(db.syncQueueTable).get(), hasLength(1));

    upload.complete(false);
  });
}

class FakeFirebaseFirestore extends Fake implements FirebaseFirestore {}
