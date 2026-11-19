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
import 'package:life_os/core/services/water_v2_provider.dart';
import 'package:life_os/features/health/data/repositories/health_repository.dart';
import 'package:life_os/features/health/presentation/cycle/cycle_reminder_preferences.dart';
import 'package:life_os/features/health/presentation/health_screen.dart';
import 'package:life_os/features/health/presentation/providers/health_provider.dart';
import 'package:life_os/features/premium/domain/services/quota_service.dart';
import 'package:life_os/features/settings/presentation/providers/notification_provider.dart';

void main() {
  const uid = 'local-v1-123e4567-e89b-42d3-a456-426614174000';
  late AppDatabase db;
  late HealthRepository repository;
  late DateTime now;

  setUp(() {
    now = DateTime(2026, 11, 18, 12);
    db = AppDatabase.forUser(
      identity: LocalDatabaseIdentity(uid),
      executor: NativeDatabase.memory(),
      syncPolicy: DatabaseSyncPolicy.localOnly,
    );
    repository = HealthRepository.local(db, now: () => now);
  });
  tearDown(() => db.close());

  test(
    'concurrent water and mood commits preserve each other and the day boundary',
    () async {
      await Future.wait([
        repository.updateMood('Focado'),
        for (var i = 0; i < 8; i++) repository.addWater(),
      ]);
      final first = (await db.select(db.healthEntries).get()).single;
      expect(
        (first.docId, first.waterIntakeMl, first.mood),
        ('2026-11-18', 2000, 'Focado'),
      );
      now = now.add(const Duration(days: 1));
      expect((await repository.getHealthStream().first).waterIntakeMl, 0);
      await repository.addWater();
      expect((await repository.getHealthStream().first).waterIntakeMl, 250);
      expect(await db.select(db.healthEntries).get(), contains(first));
      expect(await db.select(db.waterV2Intents).get(), isEmpty);
      expect(await db.select(db.waterV2DailyStates).get(), isEmpty);
      expect(await db.select(db.syncQueueTable).get(), isEmpty);
    },
  );

  test(
    'health provider and local water preference avoid Firebase, alarms and V2',
    () async {
      var remoteReads = 0;
      Never remote() {
        remoteReads++;
        throw StateError('REMOTE_PROVIDER_ACCESSED');
      }

      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          appRuntimeModeProvider.overrideWithValue(AppRuntimeMode.localFirst),
          firebaseAuthProvider.overrideWith((ref) => remote()),
          firebaseFirestoreProvider.overrideWith((ref) => remote()),
          syncManagerProvider.overrideWith((ref) => remote()),
          notificationServiceProvider.overrideWith((ref) => remote()),
          waterV2ControllerProvider.overrideWith((ref) => remote()),
          cycleReminderUserIdReaderProvider.overrideWith((ref) => remote()),
          cycleReminderPreferencesProvider.overrideWith(() => remote()),
          healthDayClockProvider.overrideWithValue(() => now),
        ],
      );
      addTearDown(container.dispose);
      final fromProvider = container.read(healthRepositoryProvider);
      expect(container.read(cycleHealthOwnerReaderProvider)(), uid);
      expect(container.read(cyclePillTrackingVisibleProvider), true);
      final subscription = container.listen(healthWaterGoalProvider, (_, _) {});
      addTearDown(subscription.close);
      expect(await container.read(localWaterGoalProvider.future), 3000);
      await fromProvider.setLocalWaterGoal(2250);
      expect(await fromProvider.watchLocalWaterGoal().first, 2250);
      await fromProvider.syncHealthFromFirebase();
      final goal = (await db.select(db.waterV2Preferences).get()).single;
      expect(
        (goal.ownerUid, goal.goalMl, goal.epoch, goal.revision),
        (uid, 2250, null, 0),
      );
      expect(await db.select(db.syncQueueTable).get(), isEmpty);
      expect(await db.select(db.notificationsTable).get(), isEmpty);
      expect(remoteReads, 0);
    },
  );

  test(
    'water goal refuses an authority conflict and leaves other owner intact',
    () async {
      final other = WaterV2PreferencesCompanion.insert(
        ownerUid: 'other-owner',
        goalMl: const Value(1750),
        epoch: const Value('remote'),
      );
      await db.into(db.waterV2Preferences).insert(other);
      await expectLater(
        repository.setLocalWaterGoal(2200),
        throwsArgumentError,
      );
      expect(await repository.watchLocalWaterGoal().first, 3000);
      await repository.setLocalWaterGoal(2500);
      final rows = await db.select(db.waterV2Preferences).get();
      final old = rows.singleWhere((row) => row.ownerUid == 'other-owner');
      expect((old.goalMl, old.epoch), (1750, 'remote'));
      await (db.update(db.waterV2Preferences)
            ..where((row) => row.ownerUid.equals(uid)))
          .write(const WaterV2PreferencesCompanion(epoch: Value('unknown')));
      final before = await db.select(db.waterV2Preferences).get();
      await expectLater(repository.setLocalWaterGoal(2750), throwsStateError);
      expect(await db.select(db.waterV2Preferences).get(), before);
    },
  );

  test(
    'medication quota serializes and deletion matches both identifiers',
    () async {
      final results = await Future.wait(
        List.generate(8, (index) async {
          try {
            await repository.addMedication('Sintético $index', now, 5);
            return true;
          } on PlanQuotaExceeded {
            return false;
          }
        }),
      );
      expect(results.where((result) => result), hasLength(3));
      final before = await db.select(db.medications).get();
      expect(before, hasLength(3));
      await repository.deleteMedication(
        before.first.firestoreId,
        before.last.id,
      );
      expect(await db.select(db.medications).get(), before);
      await repository.deleteMedication(
        before.first.firestoreId,
        before.first.id,
      );
      await repository.addMedication('Reposição sintética', now, null);
      final after = await db.select(db.medications).get();
      expect(after, hasLength(3));
      expect(after, isNot(contains(before.first)));
      expect(after, contains(before.last));
      expect(await db.select(db.notificationsTable).get(), isEmpty);
      expect(await db.select(db.syncQueueTable).get(), isEmpty);
    },
  );

  test(
    'cycle settings and daily pill track the admitted profile across days',
    () async {
      final settings = <String, dynamic>{
        'isEnabled': true,
        'lastPeriodStart': '2026-11-17',
        'cycleLengthDays': 28,
        'periodLengthDays': 5,
      };
      expect(
        await repository.updateCycleSettings(settings, expectedUid: 'other'),
        false,
      );
      expect(
        await repository.updateCycleSettings(settings, expectedUid: uid),
        true,
      );
      expect(await repository.updatePillStatus(true, expectedUid: uid), true);
      expect(await repository.updatePillStatus(true, expectedUid: uid), true);
      expect(await db.select(db.healthEntries).get(), hasLength(1));
      now = now.add(const Duration(days: 1));
      final next = await repository.getHealthStream().first;
      expect(next.menstrualCycle?['isEnabled'], true);
      expect(next.hasTakenPillToday, false);
      expect(
        await repository.toggleMenstrualCycleFeature(false, expectedUid: uid),
        true,
      );
      expect(
        (await repository.getHealthStream().first).menstrualCycle?['isEnabled'],
        false,
      );
      final previous = (await db.select(db.healthEntries).get()).singleWhere(
        (row) => row.docId == '2026-11-18',
      );
      expect(previous.hasTakenPillToday, true);
      expect(await db.select(db.syncQueueTable).get(), isEmpty);
    },
  );

  test('detached session cannot write any daily health data', () async {
    String? current = uid;
    db.localMutations.bindSessionReader(() => current);
    db.localMutations.openPreparedSession();
    await repository.addWater();
    final before = (await db.select(db.healthEntries).get()).single;
    current = null;
    db.localMutations.observeSession(null);
    await expectLater(
      repository.addWater(),
      throwsA(isA<LocalMutationUnavailable>()),
    );
    await expectLater(
      repository.setLocalWaterGoal(1500),
      throwsA(isA<LocalMutationUnavailable>()),
    );
    await expectLater(
      repository.updatePillStatus(true, expectedUid: uid),
      throwsA(isA<LocalMutationUnavailable>()),
    );
    current = uid;
    db.localMutations.openPreparedSession();
    expect((await db.select(db.healthEntries).get()).single, before);
    expect(await db.select(db.waterV2Preferences).get(), isEmpty);
  });
}
