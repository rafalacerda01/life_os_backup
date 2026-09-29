import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:drift/native.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/services/notification_service.dart';
import 'package:life_os/core/services/sync_manager.dart';
import 'package:life_os/features/health/data/repositories/health_repository.dart';
import 'package:life_os/features/health/presentation/providers/health_provider.dart';

class _Firestore extends Fake implements FirebaseFirestore {}

class _Auth extends Fake implements FirebaseAuth {}

class _Notifications extends Fake implements NotificationService {}

class _SyncManager extends Fake implements SyncManager {}

class _BoundaryTimer implements Timer {
  _BoundaryTimer(this.delay, this.callback);

  final Duration delay;
  final void Function() callback;
  bool _active = true;
  int _tick = 0;

  @override
  bool get isActive => _active;

  @override
  int get tick => _tick;

  @override
  void cancel() => _active = false;

  void fire() {
    if (!_active) return;
    _active = false;
    _tick += 1;
    callback();
  }
}

void main() {
  for (final (name, now, expected) in [
    ('midday', DateTime(2026, 8, 21, 12), DateTime(2026, 8, 22)),
    ('23:59', DateTime(2026, 8, 21, 23, 59), DateTime(2026, 8, 22)),
    ('month rollover', DateTime(2026, 8, 31, 23, 59), DateTime(2026, 9, 1)),
    ('year rollover', DateTime(2026, 12, 31, 23, 59), DateTime(2027)),
  ]) {
    test('next Health boundary uses local calendar: $name', () {
      final boundary = nextHealthDayBoundary(now);
      expect(boundary, expected);
      expect(boundary.isUtc, isFalse);
      expect(boundary.difference(now), expected.difference(now));
    });
  }

  late AppDatabase db;
  late ProviderContainer container;
  late DateTime now;
  late List<_BoundaryTimer> timers;

  setUp(() {
    now = DateTime(2026, 8, 21, 23, 59);
    timers = [];
    db = AppDatabase(executor: NativeDatabase.memory());
    final repository = HealthRepository(
      _Notifications(),
      _Firestore(),
      _Auth(),
      db,
      _SyncManager(),
      now: () => now,
    );
    container = ProviderContainer(
      overrides: [
        healthRepositoryProvider.overrideWithValue(repository),
        healthDayClockProvider.overrideWithValue(() => now),
        healthDayTimerProvider.overrideWithValue((delay, callback) {
          final timer = _BoundaryTimer(delay, callback);
          timers.add(timer);
          return timer;
        }),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await db.closeDatabase();
  });

  test(
    'midnight refresh resets daily metrics without any Drift mutation',
    () async {
      final cycle = {
        'isEnabled': true,
        'lastPeriodStart': '2026-08-01T00:00:00.000',
        'cycleLengthDays': 30,
        'periodLengthDays': 6,
      };
      await db
          .into(db.healthEntries)
          .insert(
            HealthEntry(
              docId: '2026-08-21',
              mood: 'Radiante',
              waterIntakeMl: 1500,
              hasTakenPillToday: true,
              menstrualCycleJson: jsonEncode(cycle),
              date: now,
            ),
          );
      final rowsBefore = await db.select(db.healthEntries).get();
      final subscription = container.listen(healthStreamProvider, (_, _) {});
      addTearDown(subscription.close);
      final previousDay = await container.read(healthStreamProvider.future);
      expect(previousDay.mood, 'Radiante');
      expect(previousDay.waterIntakeMl, 1500);
      expect(previousDay.hasTakenPillToday, isTrue);
      expect(timers.single.delay, const Duration(minutes: 1));

      now = DateTime(2026, 8, 22);
      timers.single.fire();
      final nextDay = await container.read(healthStreamProvider.future);
      expect(nextDay.date, now);
      expect(nextDay.mood, '—');
      expect(nextDay.waterIntakeMl, 0);
      expect(nextDay.hasTakenPillToday, isFalse);
      expect(nextDay.menstrualCycle, cycle);
      expect(await db.select(db.healthEntries).get(), rowsBefore);
      expect(await db.select(db.syncQueueTable).get(), isEmpty);
      expect(timers, hasLength(2));
      expect(timers.first.isActive, isFalse);
      expect(timers.last.delay, nextHealthDayBoundary(now).difference(now));
      expect(timers.last.isActive, isTrue);

      now = DateTime(2026, 8, 23);
      timers.last.fire();
      expect((await container.read(healthStreamProvider.future)).date, now);
      expect(timers, hasLength(3));
      expect(timers.where((timer) => timer.isActive), hasLength(1));
    },
  );

  test('invalidation and dispose cancel owned boundary timers', () async {
    container.listen(healthStreamProvider, (_, _) {});
    await container.read(healthStreamProvider.future);
    final initialTimer = timers.single;

    container.invalidate(healthStreamProvider);
    expect(initialTimer.isActive, isFalse);
    await container.read(healthStreamProvider.future);
    expect(timers, hasLength(2));
    expect(timers.last.isActive, isTrue);
    initialTimer.fire();
    expect(timers, hasLength(2));

    container.dispose();
    expect(timers.every((timer) => !timer.isActive), isTrue);
    timers.last.fire();
    expect(timers, hasLength(2));
  });
}
