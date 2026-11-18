import 'dart:async';
import 'dart:convert';
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
import 'package:life_os/features/settings/presentation/providers/analytics_provider.dart';
import 'package:life_os/features/habits/data/repositories/habits_repository.dart';
import 'package:life_os/features/habits/presentation/providers/habits_provider.dart';
import 'package:life_os/features/premium/domain/services/quota_service.dart';

void main() {
  const uid = 'local-v1-123e4567-e89b-42d3-a456-426614174000';
  late AppDatabase db;
  late HabitsRepository repository;
  setUp(() {
    db = AppDatabase.forUser(
      identity: LocalDatabaseIdentity(uid),
      executor: NativeDatabase.memory(),
      syncPolicy: DatabaseSyncPolicy.localOnly,
    );
    repository = HabitsRepository.local(db);
  });
  tearDown(() => db.close());

  test(
    'create, stream, today, dates and delete use no Firebase user or queue',
    () async {
      final stream = StreamIterator(repository.getHabitsStream());
      try {
        expect(await stream.moveNext(), true);
        expect(stream.current, isEmpty);
        await repository.addHabit('  Meditar local  ');
        expect(await stream.moveNext(), true);
        final habit = stream.current.single;
        expect(habit.title, 'Meditar local');
        await repository.toggleHabitToday(habit.id, []);
        expect(await stream.moveNext(), true);
        expect(stream.current.single.completedDates, [
          DateTime.now().toIso8601String().split('T').first,
        ]);
        await repository.updateHabitDates(habit.id, [
          '2026-11-17',
          '2026-11-16',
          '2026-11-17',
        ]);
        expect(await stream.moveNext(), true);
        expect(stream.current.single.completedDates, [
          '2026-11-16',
          '2026-11-17',
        ]);
        await repository.deleteHabit(habit.id, habit.title);
        expect(await stream.moveNext(), true);
        expect(stream.current, isEmpty);
        expect(await db.select(db.syncQueueTable).get(), isEmpty);
      } finally {
        await stream.cancel();
      }
    },
  );

  test(
    'repository and manual toggle providers never touch remote analytics or SDKs',
    () async {
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
          analyticsServiceProvider.overrideWith((ref) => remote()),
          analyticsSessionActiveProvider.overrideWith((ref) => remote()),
        ],
      );
      try {
        final local = container.read(habitsRepositoryProvider);
        await local.addHabit('provider');
        final row = (await db.select(db.habits).get()).single;
        await container.read(manualHabitTodayToggleProvider)(row.id, [], false);
        await local.syncHabitsFromFirebaseToLocal();
        expect(
          jsonDecode((await db.select(db.habits).get()).single.completedDates),
          hasLength(1),
        );
        expect(await db.select(db.syncQueueTable).get(), isEmpty);
        expect(reads, 0);
      } finally {
        container.dispose();
      }
    },
  );

  test('remote pull cannot erase local records', () async {
    await repository.addHabit('preserved');
    final before = await db.select(db.habits).get();
    await repository.syncHabitsFromFirebaseToLocal();
    expect(await db.select(db.habits).get(), before);
    expect(await db.select(db.syncQueueTable).get(), isEmpty);
  });

  test(
    'eight concurrent creates obey atomic Free quota; deletion frees one slot',
    () async {
      final result = await Future.wait(
        List.generate(8, (i) async {
          try {
            await repository.addHabit('concurrent-$i');
            return true;
          } on PlanQuotaExceeded {
            return false;
          }
        }),
      );
      expect(result.where((e) => e), hasLength(3));
      final rows = await db.select(db.habits).get();
      expect(rows, hasLength(3));
      await repository.deleteHabit(rows.first.id, rows.first.title);
      await repository.addHabit('replacement');
      expect(await db.select(db.habits).get(), hasLength(3));
      expect(await db.select(db.syncQueueTable).get(), isEmpty);
    },
  );

  test(
    'two concurrent toggles ignore stale UI dates and preserve other days',
    () async {
      await repository.addHabit('toggle');
      final row = (await db.select(db.habits).get()).single;
      await repository.updateHabitDates(row.id, ['2020-01-01']);
      await Future.wait(
        List.generate(2, (_) => repository.toggleHabitToday(row.id, [])),
      );
      expect(
        jsonDecode((await db.select(db.habits).get()).single.completedDates),
        ['2020-01-01'],
      );
    },
  );

  test(
    'concurrent week-day toggles preserve both days from stale UI snapshots',
    () async {
      await repository.addHabit('week');
      final row = (await db.select(db.habits).get()).single;
      await Future.wait([
        repository.toggleHabitDate(row.id, '2026-11-16', []),
        repository.toggleHabitDate(row.id, '2026-11-17', []),
      ]);
      expect(
        jsonDecode((await db.select(db.habits).get()).single.completedDates),
        ['2026-11-16', '2026-11-17'],
      );
      expect(await db.select(db.syncQueueTable).get(), isEmpty);
    },
  );
  test('invalid title and calendar dates do not mutate history', () async {
    await expectLater(repository.addHabit('  <b></b>  '), throwsArgumentError);
    await repository.addHabit('history');
    final before = (await db.select(db.habits).get()).single;
    for (final date in [
      '2026-02-30',
      '2026-13-01',
      '2026-1-01',
      'bad',
      '2026-11-18T00:00:00',
    ]) {
      await expectLater(
        repository.updateHabitDates(before.id, [date]),
        throwsArgumentError,
      );
    }
    expect((await db.select(db.habits).get()).single, before);
  });

  test('detached session refuses late reads and mutations', () async {
    String? current = uid;
    db.localMutations.bindSessionReader(() => current);
    db.localMutations.openPreparedSession();
    await repository.addHabit('preserved');
    final row = (await db.select(db.habits).get()).single;
    current = null;
    db.localMutations.observeSession(null);
    await expectLater(
      repository.addHabit('late'),
      throwsA(isA<LocalMutationUnavailable>()),
    );
    await expectLater(
      repository.toggleHabitToday(row.id, []),
      throwsA(isA<LocalMutationUnavailable>()),
    );
    await expectLater(
      repository.updateHabitDates(row.id, ['2026-01-01']),
      throwsA(isA<LocalMutationUnavailable>()),
    );
    await expectLater(
      repository.deleteHabit(row.id, row.title),
      throwsA(isA<LocalMutationUnavailable>()),
    );
    await expectLater(
      repository.getHabitsStream().first,
      throwsA(isA<LocalMutationUnavailable>()),
    );
    current = uid;
    db.localMutations.openPreparedSession();
    expect((await db.select(db.habits).get()).single, row);
  });

  test('local constructor refuses a remote-enabled connection', () async {
    final remote = AppDatabase(executor: NativeDatabase.memory());
    try {
      expect(() => HabitsRepository.local(remote), throwsArgumentError);
    } finally {
      await remote.close();
    }
  });
}
