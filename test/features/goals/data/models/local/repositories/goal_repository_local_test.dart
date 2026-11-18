import 'dart:async';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/database_provider.dart';
import 'package:life_os/core/database/database_sync_policy.dart';
import 'package:life_os/core/database/local_database_identity.dart';
import 'package:life_os/core/database/local_mutation_gate.dart';
import 'package:life_os/core/services/firebase_auth_provider.dart';
import 'package:life_os/core/services/sync_manager_provider.dart';
import 'package:life_os/features/goals/data/models/local/repositories/goal_repository.dart';
import 'package:life_os/features/goals/presentation/goals_provider.dart';
import 'package:life_os/features/premium/domain/services/quota_service.dart';

void main() {
  const uid = 'local-v1-123e4567-e89b-42d3-a456-426614174000';
  late AppDatabase db;
  late GoalRepository repository;
  setUp(() {
    db = AppDatabase.forUser(
      identity: LocalDatabaseIdentity(uid),
      executor: NativeDatabase.memory(),
      syncPolicy: DatabaseSyncPolicy.localOnly,
    );
    repository = GoalRepository.local(db);
  });
  tearDown(() => db.close());
  Future<Goal> create({String period = 'DIÁRIA', int target = 10}) async {
    await repository.createGoal('Meta local', period, target);
    return (await db.select(db.goals).get()).single;
  }

  Future<Goal> row(String id) =>
      (db.select(db.goals)..where((t) => t.id.equals(id))).getSingle();

  test(
    'stream, create, progress, reset and delete work with no Firebase user or queue',
    () async {
      final stream = StreamIterator(repository.getGoalsStream());
      try {
        expect(await stream.moveNext(), true);
        expect(stream.current, isEmpty);
        final goal = await create();
        expect(await stream.moveNext(), true);
        expect(stream.current.single.id, goal.id);
        await repository.updateGoalProgress(goal.id, 4);
        expect(await stream.moveNext(), true);
        expect(stream.current.single.currentValue, 4);
        await repository.resetGoalCycle(goal.id);
        expect(await stream.moveNext(), true);
        expect(stream.current.single.currentValue, 0);
        await repository.removeGoal(goal.id);
        expect(await stream.moveNext(), true);
        expect(stream.current, isEmpty);
        expect(await db.select(db.syncQueueTable).get(), isEmpty);
      } finally {
        await stream.cancel();
      }
    },
  );
  test('provider branches before Auth, Firestore and remote sync', () async {
    var reads = 0;
    Never remote() {
      reads++;
      throw StateError('REMOTE_MUST_NOT_BE_READ');
    }

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        firebaseAuthProvider.overrideWith((ref) => remote()),
        firebaseFirestoreProvider.overrideWith((ref) => remote()),
        syncManagerProvider.overrideWith((ref) => remote()),
      ],
    );
    try {
      final local = container.read(goalRepositoryProvider);
      await local.createGoal('provider', 'DIÁRIA', 3);
      await local.syncGoalsFromFirebaseToLocal();
      expect(await db.select(db.goals).get(), hasLength(1));
      expect(reads, 0);
      expect(await db.select(db.syncQueueTable).get(), isEmpty);
    } finally {
      container.dispose();
    }
  });
  test('remote pull cannot erase admitted local goals', () async {
    await create();
    final before = await db.select(db.goals).get();
    await repository.syncGoalsFromFirebaseToLocal();
    expect(await db.select(db.goals).get(), before);
  });
  test(
    'Free quota is atomic across concurrent creates and deletion releases a slot',
    () async {
      final results = await Future.wait(
        List.generate(8, (i) async {
          try {
            await repository.createGoal('concurrent-$i', 'DIÁRIA', 10);
            return true;
          } on PlanQuotaExceeded {
            return false;
          }
        }),
      );
      expect(results.where((e) => e), hasLength(3));
      final rows = await db.select(db.goals).get();
      expect(rows, hasLength(3));
      await repository.removeGoal(rows.first.id);
      await repository.createGoal('replacement', 'MENSAL', 2);
      expect(await db.select(db.goals).get(), hasLength(3));
      expect(await db.select(db.syncQueueTable).get(), isEmpty);
    },
  );
  test(
    'concurrent increments use the latest admitted progress and stop at target',
    () async {
      final goal = await create(target: 3);
      await Future.wait(
        List.generate(8, (_) => repository.changeLocalGoalProgress(goal.id, 1)),
      );
      expect((await row(goal.id)).currentValue, 3);
      await Future.wait(
        List.generate(
          8,
          (_) => repository.changeLocalGoalProgress(goal.id, -1),
        ),
      );
      expect((await row(goal.id)).currentValue, 0);
      await expectLater(
        repository.changeLocalGoalProgress(goal.id, 2),
        throwsArgumentError,
      );
    },
  );
  for (final period in ['DIÁRIA', 'SEMANAL', 'MENSAL']) {
    test(
      '$period expiry is rechecked; delayed reset cannot erase new cycle progress',
      () async {
        final goal = await create(period: period);
        final old = DateTime.now()
            .subtract(const Duration(days: 70))
            .millisecondsSinceEpoch;
        await (db.update(db.goals)..where((t) => t.id.equals(goal.id))).write(
          GoalsCompanion(currentValue: const Value(8), lastReset: Value(old)),
        );
        await repository.changeLocalGoalProgress(goal.id, 1);
        final fresh = await row(goal.id);
        expect(fresh.currentValue, 1);
        expect(fresh.lastReset, greaterThan(old));
        await Future.wait(
          List.generate(4, (_) => repository.resetExpiredGoalCycle(goal.id)),
        );
        expect(await row(goal.id), fresh);
        await (db.update(db.goals)..where((t) => t.id.equals(goal.id))).write(
          GoalsCompanion(lastReset: Value(old)),
        );
        await repository.resetExpiredGoalCycle(goal.id);
        expect((await row(goal.id)).currentValue, 0);
      },
    );
  }
  test('invalid inputs preserve local goal history', () async {
    await expectLater(
      repository.createGoal(' ', 'DIÁRIA', 1),
      throwsArgumentError,
    );
    await expectLater(
      repository.createGoal('invalid', 'OTHER', 1),
      throwsArgumentError,
    );
    await expectLater(
      repository.createGoal('invalid', 'DIÁRIA', 0),
      throwsArgumentError,
    );
    final goal = await create();
    await expectLater(
      repository.updateGoalProgress(goal.id, -1),
      throwsArgumentError,
    );
    await expectLater(
      repository.updateGoalProgress(goal.id, 11),
      throwsArgumentError,
    );
    expect(await row(goal.id), goal);
  });
  test(
    'detached session refuses reads, resets, progress changes and deletes',
    () async {
      String? current = uid;
      db.localMutations.bindSessionReader(() => current);
      db.localMutations.openPreparedSession();
      final goal = await create();
      current = null;
      db.localMutations.observeSession(null);
      for (final action in <Future<void> Function()>[
        () => repository.createGoal('late', 'DIÁRIA', 1),
        () => repository.changeLocalGoalProgress(goal.id, 1),
        () => repository.resetExpiredGoalCycle(goal.id),
        () => repository.updateGoalProgress(goal.id, 1),
        () => repository.resetGoalCycle(goal.id),
        () => repository.removeGoal(goal.id),
      ]) {
        await expectLater(action(), throwsA(isA<LocalMutationUnavailable>()));
      }
      await expectLater(
        repository.getGoalsStream().first,
        throwsA(isA<LocalMutationUnavailable>()),
      );
      current = uid;
      db.localMutations.openPreparedSession();
      expect(await row(goal.id), goal);
    },
  );
  test('local constructor refuses remote-enabled storage', () async {
    final remote = AppDatabase(executor: NativeDatabase.memory());
    try {
      expect(() => GoalRepository.local(remote), throwsArgumentError);
    } finally {
      await remote.close();
    }
  });
}
