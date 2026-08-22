import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:life_os/core/database/app_database.dart';
import 'dart:convert';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(executor: NativeDatabase.memory());
  });

  tearDown(() async {
    await db.closeDatabase();
  });

  test(
    'transactionWithSync salva dado local e operação na fila atomicamente',
    () async {
      const habitId = 'habit-test-1';
      const title = 'Hábito de teste';
      final dates = <String>[];

      await db.transactionWithSync(
        ownerUid: 'user-123',
        localOperation: () async {
          await db
              .into(db.habits)
              .insert(
                HabitsCompanion.insert(
                  id: habitId,
                  title: title,
                  completedDates: jsonEncode(dates),
                ),
              );
        },
        collection: 'habits',
        docId: habitId,
        operationType: 'create',
        payloadJson: jsonEncode({'title': title, 'completedDates': dates}),
      );

      final habit = await (db.select(
        db.habits,
      )..where((table) => table.id.equals(habitId))).getSingle();

      expect(habit.id, habitId);
      expect(habit.title, title);
      expect(habit.completedDates, '[]');

      final pending = await db.getPendingSyncItems('user-123');

      expect(pending.length, 1);
      expect(pending.single.collection, 'habits');
      expect(pending.single.docId, habitId);
      expect(pending.single.operationType, 'create');
      expect(pending.single.ownerUid, 'user-123');
      expect(pending.single.status, SyncQueuePersistenceStatus.pending);
      expect(jsonDecode(pending.single.payloadJson), {
        'title': title,
        'completedDates': dates,
      });
      expect(pending.single.isSynced, false);
    },
  );

  test('falha na operação local não cria item na SyncQueue', () async {
    const habitId = 'habit-test-2';

    expect(
      () => db.transactionWithSync(
        ownerUid: 'user-123',
        localOperation: () async {
          throw StateError('Falha simulada');
        },
        collection: 'habits',
        docId: habitId,
        operationType: 'create',
        payloadJson: '{"title":"Falha"}',
      ),
      throwsA(isA<StateError>()),
    );

    final pending = await db.getPendingSyncItems('user-123');

    expect(pending, isEmpty);
  });

  test('enqueue exige ownerUid não vazio', () async {
    expect(
      () => db.transactionWithSync(
        ownerUid: '   ',
        localOperation: () async {},
        collection: 'habits',
        docId: 'habit-ownerless',
        operationType: 'create',
        payloadJson: '{}',
      ),
      throwsArgumentError,
    );
  });

  test('rejeição persiste código sem marcar item como sincronizado', () async {
    final id = await db.insertSyncItem(
      ownerUid: 'user-123',
      collection: 'tasks',
      docId: 'task-quota',
      operationType: 'create',
      payloadJson: '{}',
    );

    await db.markSyncItemRejected(id, 'user-123', 'TASK_QUOTA_EXCEEDED');

    final item = await db.getSyncItemById(id) as SyncQueueTableData;
    expect(item.status, SyncQueuePersistenceStatus.rejected);
    expect(item.isSynced, isFalse);
    expect(item.lastErrorCode, 'TASK_QUOTA_EXCEEDED');
    expect(item.attemptCount, 1);
    expect(item.lastAttemptAt, isNotNull);
    expect(await db.getPendingSyncItems('user-123'), isEmpty);
  });

  test('sucesso persiste succeeded e isSynced true', () async {
    final id = await db.insertSyncItem(
      ownerUid: 'user-123',
      collection: 'tasks',
      docId: 'task-success',
      operationType: 'create',
      payloadJson: '{}',
    );

    await db.markSyncItemAsSucceeded(id, 'user-123');

    final item = await db.getSyncItemById(id) as SyncQueueTableData;
    expect(item.status, SyncQueuePersistenceStatus.succeeded);
    expect(item.isSynced, isTrue);
    expect(item.lastErrorCode, isNull);
    expect(item.attemptCount, 1);
    expect(item.lastAttemptAt, isNotNull);
  });

  test('retryable permanece pendente e registra tentativa', () async {
    final id = await db.insertSyncItem(
      ownerUid: 'user-123',
      collection: 'health_info',
      docId: '2026-08-22',
      operationType: 'update',
      payloadJson: '{}',
    );

    await db.markSyncItemRetryableFailure(id, 'user-123', 'NETWORK_ERROR');

    final item = await db.getSyncItemById(id) as SyncQueueTableData;
    expect(item.status, SyncQueuePersistenceStatus.pending);
    expect(item.isSynced, isFalse);
    expect(item.lastErrorCode, 'NETWORK_ERROR');
    expect(item.attemptCount, 1);
    expect(await db.getPendingSyncItems('user-123'), hasLength(1));
  });
}
