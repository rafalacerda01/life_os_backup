import 'dart:async';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/database_provider.dart';
import 'package:life_os/core/database/database_sync_policy.dart';
import 'package:life_os/core/database/local_database_identity.dart';
import 'package:life_os/core/database/local_mutation_gate.dart';
import 'package:life_os/core/runtime/app_runtime_mode.dart';
import 'package:life_os/core/services/firebase_auth_provider.dart';
import 'package:life_os/core/services/sync_manager_provider.dart';
import 'package:life_os/features/premium/domain/services/quota_service.dart';
import 'package:life_os/features/tasks/presentation/providers/tasks_provider.dart';

void main() {
  const uid = 'local-v1-123e4567-e89b-42d3-a456-426614174000';
  late AppDatabase db;
  late TasksRepository repository;
  setUp(() {
    db = AppDatabase.forUser(
      identity: LocalDatabaseIdentity(uid),
      executor: NativeDatabase.memory(),
      syncPolicy: DatabaseSyncPolicy.localOnly,
    );
    repository = TasksRepository.local(db);
  });
  tearDown(() => db.close());
  test('create, observe, toggle and delete require no Firebase user', () async {
    final stream = StreamIterator(repository.getTasksStream());
    try {
      expect(await stream.moveNext(), true);
      expect(stream.current, isEmpty);
      await repository.addTask('  tarefa local  ', 'medium');
      expect(await stream.moveNext(), true);
      final task = stream.current.single;
      expect(task.title, 'tarefa local');
      expect(task.isCompleted, false);
      await repository.toggleTaskStatus(task.id, false);
      expect(await stream.moveNext(), true);
      expect(stream.current.single.isCompleted, true);
      await repository.deleteTask(task.id);
      expect(await stream.moveNext(), true);
      expect(stream.current, isEmpty);
      expect(await db.select(db.syncQueueTable).get(), isEmpty);
    } finally {
      await stream.cancel();
    }
  });
  test(
    'provider and manual toggle do not consume Firebase or analytics',
    () async {
      var reads = 0;
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          appRuntimeModeProvider.overrideWithValue(AppRuntimeMode.localFirst),
          firebaseAuthProvider.overrideWith((ref) {
            reads++;
            throw StateError('MUST_NOT_READ_AUTH');
          }),
          firebaseFirestoreProvider.overrideWith((ref) {
            reads++;
            throw StateError('MUST_NOT_READ_FIRESTORE');
          }),
        ],
      );
      try {
        final local = container.read(tasksRepositoryProvider);
        await local.addTask('provedor local', 'high');
        final task = (await db.select(db.taskTable).get()).single;
        await container.read(manualTaskStatusToggleProvider)(task.id, false);
        expect((await db.select(db.taskTable).get()).single.isCompleted, true);
        expect(
          await container.read(syncManagerProvider).processPendingItems(),
          false,
        );
        expect(reads, 0);
        expect(await db.select(db.syncQueueTable).get(), isEmpty);
      } finally {
        container.dispose();
      }
    },
  );
  test('legacy pull method is inert in local mode', () async {
    await repository.addTask('preservada', 'low');
    await repository.syncTasksFromFirebaseToLocal();
    expect((await db.select(db.taskTable).get()).single.title, 'preservada');
    expect(await db.select(db.syncQueueTable).get(), isEmpty);
  });
  test(
    'Free quota is enforced inside the transaction, including completed tasks',
    () async {
      for (var i = 0; i < 3; i++) {
        await repository.addTask('task-$i', 'medium');
      }
      final first = (await db.select(db.taskTable).get()).first;
      await repository.toggleTaskStatus(first.id, false);
      await expectLater(
        repository.addTask('fourth', 'medium'),
        throwsA(isA<PlanQuotaExceeded>()),
      );
      expect(await db.select(db.taskTable).get(), hasLength(3));
      await repository.deleteTask(first.id);
      await repository.addTask('replacement', 'medium');
      expect(await db.select(db.taskTable).get(), hasLength(3));
      expect(await db.select(db.syncQueueTable).get(), isEmpty);
    },
  );
  test('concurrent creates cannot overrun the Free quota', () async {
    final outcomes = await Future.wait(
      List.generate(8, (i) async {
        try {
          await repository.addTask('concurrent-$i', 'medium');
          return true;
        } on PlanQuotaExceeded {
          return false;
        }
      }),
    );
    expect(outcomes.where((value) => value).length, 3);
    expect(await db.select(db.taskTable).get(), hasLength(3));
    expect(await db.select(db.syncQueueTable).get(), isEmpty);
  });
  test('bad local input does not partially create a row', () async {
    await expectLater(repository.addTask('  ', 'medium'), throwsArgumentError);
    await expectLater(
      repository.addTask('task', 'invalid'),
      throwsArgumentError,
    );
    expect(await db.select(db.taskTable).get(), isEmpty);
  });
  test(
    'detached session cannot admit a late create or status mutation',
    () async {
      String? current = uid;
      db.localMutations.bindSessionReader(() => current);
      db.localMutations.openPreparedSession();
      await repository.addTask('before detach', 'medium');
      final row = (await db.select(db.taskTable).get()).single;
      current = null;
      db.localMutations.observeSession(null);
      await expectLater(
        repository.addTask('late', 'medium'),
        throwsA(isA<LocalMutationUnavailable>()),
      );
      await expectLater(
        repository.toggleTaskStatus(row.id, false),
        throwsA(isA<LocalMutationUnavailable>()),
      );
    },
  );
  test(
    'local constructor cannot accept a legacy remote-enabled connection',
    () async {
      final remote = AppDatabase(executor: NativeDatabase.memory());
      try {
        expect(() => TasksRepository.local(remote), throwsArgumentError);
      } finally {
        await remote.close();
      }
    },
  );
}
