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
import 'package:life_os/core/runtime/app_runtime_mode.dart';
import 'package:life_os/core/services/firebase_auth_provider.dart';
import 'package:life_os/core/services/sync_manager_provider.dart';
import 'package:life_os/features/checkin/data/repositories/checkin_repository.dart';
import 'package:life_os/features/checkin/presentation/providers/check_in_provider.dart';
import 'package:life_os/features/checkin/presentation/providers/checkin_controller.dart';

void main() {
  const uid = 'local-v1-123e4567-e89b-42d3-a456-426614174000';
  late AppDatabase db;
  late CheckInRepository repository;
  setUp(() {
    db = AppDatabase.forUser(
      identity: LocalDatabaseIdentity(uid),
      executor: NativeDatabase.memory(),
      syncPolicy: DatabaseSyncPolicy.localOnly,
    );
    repository = CheckInRepository.local(db);
  });
  tearDown(() => db.close());
  Future<void> save(double energy, {double focus = 4, double motivation = 2}) =>
      repository.saveDailyMetrics(
        energy: energy,
        focus: focus,
        motivation: motivation,
      );
  test(
    'daily create, stream, replace and delete need no Firebase and never enqueue uploads',
    () async {
      final stream = StreamIterator(repository.watchCheckIns());
      try {
        expect(await stream.moveNext(), true);
        expect(stream.current, isEmpty);
        await save(3);
        expect(await stream.moveNext(), true);
        final day = stream.current.single.id;
        expect(day, DateTime.now().toIso8601String().split('T').first);
        await save(5);
        expect(await stream.moveNext(), true);
        expect(stream.current.single.id, day);
        expect(stream.current.single.energy, 5);
        expect(stream.current.single.isSynced, false);
        await repository.deleteLocalDailyMetrics(day);
        expect(await stream.moveNext(), true);
        expect(stream.current, isEmpty);
        expect(await db.select(db.syncQueueTable).get(), isEmpty);
      } finally {
        await stream.cancel();
      }
    },
  );
  test(
    'provider and form controller never construct Auth, Firestore or queue manager',
    () async {
      var reads = 0;
      Never remote() {
        reads++;
        throw StateError('REMOTE_MUST_NOT_BE_READ');
      }

      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          appRuntimeModeProvider.overrideWithValue(AppRuntimeMode.localFirst),
          firebaseAuthProvider.overrideWith((ref) => remote()),
          firebaseFirestoreProvider.overrideWith((ref) => remote()),
          syncManagerProvider.overrideWith((ref) => remote()),
        ],
      );
      final sub = container.listen(
        checkInControllerProvider,
        (previous, next) {},
      );
      try {
        final controller = container.read(checkInControllerProvider.notifier);
        controller.updateEnergy(5);
        controller.updateFocus(4);
        controller.updateMotivation(2);
        var saved = 0;
        var errors = 0;
        await controller.submitCheckIn(
          onSuccess: () => saved++,
          onError: () => errors++,
        );
        expect(saved, 1);
        expect(errors, 0);
        final row = (await db.select(db.checkInTable).get()).single;
        expect((row.energy, row.focus, row.motivation), (5.0, 4.0, 2.0));
        expect(container.read(checkInControllerProvider).isLoading, false);
        expect(reads, 0);
        expect(await db.select(db.syncQueueTable).get(), isEmpty);
      } finally {
        sub.close();
        container.dispose();
      }
    },
  );
  test(
    'legacy pull and upload entrypoints are inert without changing local status',
    () async {
      await save(3);
      final before = await db.select(db.checkInTable).get();
      expect(await repository.syncPendingCheckIns(), false);
      await repository.syncCheckinsFromFirebaseToLocal();
      expect(await db.select(db.checkInTable).get(), before);
      expect(await db.select(db.syncQueueTable).get(), isEmpty);
    },
  );
  test(
    'concurrent daily replacements commit a full tuple in exactly one row',
    () async {
      await Future.wait(
        List.generate(
          8,
          (i) =>
              save(i.toDouble(), focus: i.toDouble(), motivation: i.toDouble()),
        ),
      );
      final row = (await db.select(db.checkInTable).get()).single;
      expect(row.energy, inInclusiveRange(0, 7));
      expect(row.focus, row.energy);
      expect(row.motivation, row.energy);
      expect(await db.select(db.syncQueueTable).get(), isEmpty);
    },
  );
  test(
    'deletion is exact by civil day and preserves neighbouring history',
    () async {
      for (final id in ['2026-11-16', '2026-11-17']) {
        await db.insertCheckIn(
          CheckInTableCompanion(
            id: Value(id),
            energy: const Value(3),
            focus: const Value(4),
            motivation: const Value(2),
            createdAt: Value(DateTime.parse(id)),
            isSynced: const Value(false),
          ),
        );
      }
      await repository.deleteLocalDailyMetrics('2026-11-16');
      expect((await repository.watchCheckIns().first).single.id, '2026-11-17');
      for (final id in [
        '',
        '2026-02-30',
        '2026-11-17%',
        '2026-1-01',
        '0000-01-01',
      ]) {
        await expectLater(
          repository.deleteLocalDailyMetrics(id),
          throwsArgumentError,
        );
      }
      expect((await db.select(db.checkInTable).get()).single.id, '2026-11-17');
    },
  );
  test('invalid metrics do not overwrite the admitted daily record', () async {
    await save(3);
    final before = (await db.select(db.checkInTable).get()).single;
    for (final value in [-1.0, 11.0, double.nan, double.infinity]) {
      await expectLater(save(value), throwsArgumentError);
      await expectLater(save(3, focus: value), throwsArgumentError);
      await expectLater(save(3, motivation: value), throwsArgumentError);
    }
    expect((await db.select(db.checkInTable).get()).single, before);
  });
  test(
    'detached session refuses updates, deletes and reads without erasing history',
    () async {
      String? current = uid;
      db.localMutations.bindSessionReader(() => current);
      db.localMutations.openPreparedSession();
      await save(3);
      final before = (await db.select(db.checkInTable).get()).single;
      current = null;
      db.localMutations.observeSession(null);
      await expectLater(save(5), throwsA(isA<LocalMutationUnavailable>()));
      await expectLater(
        repository.deleteLocalDailyMetrics(before.id),
        throwsA(isA<LocalMutationUnavailable>()),
      );
      await expectLater(
        repository.watchCheckIns().first,
        throwsA(isA<LocalMutationUnavailable>()),
      );
      current = uid;
      db.localMutations.openPreparedSession();
      expect((await db.select(db.checkInTable).get()).single, before);
    },
  );
  test('local constructor rejects remote-enabled storage', () async {
    final remote = AppDatabase(executor: NativeDatabase.memory());
    try {
      expect(() => CheckInRepository.local(remote), throwsArgumentError);
    } finally {
      await remote.close();
    }
  });
}
