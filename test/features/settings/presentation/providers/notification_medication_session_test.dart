import 'dart:async';

import 'package:drift/native.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/database_provider.dart';
import 'package:life_os/core/services/notification_preferences.dart';
import 'package:life_os/core/services/notification_service.dart';
import 'package:life_os/features/auth/presentation/providers/auth_provider.dart';
import 'package:life_os/features/health/presentation/cycle/cycle_reminder_preferences.dart';
import 'package:life_os/features/health/services/medication_reminder_lifecycle.dart';
import 'package:life_os/features/health/services/medication_reminder_session_reconciler.dart';
import 'package:life_os/features/settings/presentation/providers/notification_provider.dart';

class _User extends Fake implements User {
  _User(this.uid);
  @override
  final String uid;
}

class _Auth extends Fake implements FirebaseAuth {
  User? user = _User('user-a');
  @override
  User? get currentUser => user;
}

class _Store extends NotificationPreferencesStore {
  bool all = true;
  bool medication = false;
  int reads = 0;
  Future<void> Function(int)? beforeLoad;

  @override
  Future<NotificationPreferences> load() async {
    await beforeLoad?.call(++reads);
    return NotificationPreferences(
      allNotifications: all,
      medicationReminders: medication,
      studyReminders: true,
      habitReminders: true,
    );
  }

  @override
  Future<void> save(String key, bool value) async {
    if (key == NotificationPreferenceKeys.allNotifications) all = value;
    if (key == NotificationPreferenceKeys.medicationReminders) {
      medication = value;
    }
  }
}

class _Notifications extends NotificationService {
  int permissionRequests = 0;
  int exactRequests = 0;
  int globalCancels = 0;
  int pendingReads = 0;
  int concurrent = 0;
  int maximumConcurrent = 0;
  final scheduled = <int>[];
  final cancelled = <int>[];
  final pending = <PendingNotificationRequest>[];
  Future<void> Function()? beforePermission;
  Future<void> Function()? beforeExact;
  Future<void> Function()? beforeSchedule;

  @override
  Future<bool> requestPermissions({String? preferenceKey}) async {
    permissionRequests += 1;
    await beforePermission?.call();
    return true;
  }

  @override
  Future<bool> requestExactAlarmPermission() async {
    exactRequests += 1;
    await beforeExact?.call();
    return false;
  }

  @override
  Future<List<PendingNotificationRequest>> pendingNotificationRequests() async {
    pendingReads += 1;
    return List.of(pending);
  }

  @override
  Future<bool> scheduleMedicationNotification({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledDate,
    String? preferenceKey,
    bool repeatDaily = false,
    String? payload,
  }) async {
    scheduled.add(id);
    concurrent += 1;
    if (concurrent > maximumConcurrent) maximumConcurrent = concurrent;
    try {
      await beforeSchedule?.call();
      pending.removeWhere((request) => request.id == id);
      pending.add(PendingNotificationRequest(id, title, body, payload));
      return true;
    } finally {
      concurrent -= 1;
    }
  }

  @override
  Future<void> cancelNotificationOrThrow(int id) async {
    cancelled.add(id);
    pending.removeWhere((request) => request.id == id);
  }

  @override
  Future<void> cancelAllNotifications() async {
    globalCancels += 1;
    pending.clear();
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late _Auth auth;
  late _Store store;
  late _Notifications service;
  late ProviderContainer container;
  late MedicationReminderSessionReconciler reconciler;
  late NotificationsNotifier settings;

  Future<void> seed(String id) => db
      .into(db.medications)
      .insert(
        MedicationsCompanion.insert(
          firestoreId: id,
          name: 'Fixture',
          startDate: DateTime(2026, 10, 3, 21),
        ),
      )
      .then((_) {});

  setUp(() async {
    db = AppDatabase(executor: NativeDatabase.memory());
    auth = _Auth();
    store = _Store();
    service = _Notifications();
    container = ProviderContainer(
      overrides: [
        firebaseAuthProvider.overrideWithValue(auth),
        databaseProvider.overrideWithValue(db),
        notificationPreferencesStoreProvider.overrideWithValue(store),
        notificationServiceProvider.overrideWithValue(service),
        medicationReminderLifecycleProvider.overrideWith((ref) {
          return MedicationReminderLifecycleService(
            ref.watch(databaseProvider),
            ref.watch(notificationServiceProvider),
            now: () => DateTime(2026, 10, 3, 12),
            loadPreferences: store.load,
          );
        }),
        cycleReminderUserIdReaderProvider.overrideWithValue(() => null),
        notificationPreferencesChangedProvider.overrideWithValue(() {}),
      ],
    );
    reconciler = container.read(medicationReminderSessionReconcilerProvider);
    await reconciler.onSessionPrepared('user-a');
    await container.read(notificationsProvider.future);
    settings = container.read(notificationsProvider.notifier);
    store.reads = 0;
    service.pendingReads = 0;
    await seed('medication-a');
  });

  tearDown(() async {
    container.dispose();
    await reconciler.drain();
    await db.closeDatabase();
  });

  test(
    'prepared medication ON uses shared provider and schedules normally',
    () async {
      expect(
        container.read(medicationReminderSessionReconcilerProvider),
        same(reconciler),
      );
      await settings.toggleMedication(true);
      expect(service.permissionRequests, 1);
      expect(service.exactRequests, 1);
      expect(service.pending.map((request) => request.id), [
        notificationIdForMedication('medication-a'),
      ]);
      expect(store.medication, isTrue);
    },
  );

  test(
    'prepared medication OFF reconciles and cancels without permissions',
    () async {
      await settings.toggleMedication(true);
      service.permissionRequests = 0;
      service.exactRequests = 0;
      await settings.toggleMedication(false);
      expect(store.medication, isFalse);
      expect(service.pending, isEmpty);
      expect(service.globalCancels, 0);
      expect(service.permissionRequests, 0);
      expect(service.exactRequests, 0);
    },
  );

  for (final action in ['medication', 'all']) {
    for (final pause in ['permission', 'exact', 'native']) {
      test(
        '$action ON clear during $pause cannot leave old reminders',
        () async {
          if (action == 'all') {
            store.all = false;
            store.medication = true;
          }
          final started = Completer<void>();
          final release = Completer<void>();
          Future<void> block() async {
            started.complete();
            await release.future;
          }

          if (pause == 'permission') service.beforePermission = block;
          if (pause == 'exact') service.beforeExact = block;
          if (pause == 'native') service.beforeSchedule = block;
          final toggle = action == 'all'
              ? settings.toggleAll(true)
              : settings.toggleMedication(true);
          await started.future;
          reconciler.onSessionCleared();
          expect(auth.currentUser?.uid, 'user-a');
          var drained = false;
          final drain = reconciler.drain().then((_) => drained = true);
          if (pause == 'native') expect(drained, isFalse);
          release.complete();
          await toggle;
          await drain;
          expect(drained, isTrue);
          expect(service.pending, isEmpty);
          if (pause != 'native') {
            expect(service.scheduled, isEmpty);
            expect(service.pendingReads, 0);
          } else {
            expect(service.scheduled, [
              notificationIdForMedication('medication-a'),
            ]);
            expect(service.cancelled, containsAll(service.scheduled));
          }
          if (pause == 'permission') expect(service.exactRequests, 0);
        },
      );
    }
  }

  for (final enabled in [false, true]) {
    test(
      'medication $enabled clear during reconciler preference read stops native work',
      () async {
        final started = Completer<void>();
        final release = Completer<void>();
        store.beforeLoad = (count) async {
          if (count == 2) {
            started.complete();
            await release.future;
          }
        };
        final toggle = settings.toggleMedication(enabled);
        await started.future;
        reconciler.onSessionCleared();
        release.complete();
        await toggle;
        await reconciler.drain();
        expect(service.pendingReads, 0);
        expect(service.scheduled, isEmpty);
        expect(service.cancelled, isEmpty);
      },
    );
  }

  test(
    'unprepared settings saves preference but admits no medication work',
    () async {
      reconciler.onSessionCleared();
      await settings.toggleMedication(true);
      await settings.toggleAll(true);
      expect(store.medication, isTrue);
      expect(service.pendingReads, 0);
      expect(service.scheduled, isEmpty);
      expect(service.exactRequests, 0);
    },
  );

  test('global OFF prevents medication ON rebuild', () async {
    store.all = false;
    await settings.toggleMedication(true);
    expect(service.permissionRequests, 0);
    expect(service.exactRequests, 0);
    expect(service.scheduled, isEmpty);
  });

  test('medication OFF prevents global ON rebuild', () async {
    await settings.toggleAll(true);
    expect(service.scheduled, isEmpty);
    expect(service.exactRequests, 0);
  });

  for (final allOff in [false, true]) {
    test(
      '${allOff ? "global" : "medication"} OFF queues fresh preferences behind ON in flight',
      () async {
        final started = Completer<void>();
        final release = Completer<void>();
        service.beforeSchedule = () async {
          started.complete();
          await release.future;
        };
        final on = settings.toggleMedication(true);
        await started.future;
        final saved = Completer<void>();
        store.beforeLoad = (_) async {
          if (!saved.isCompleted) saved.complete();
        };
        final off = allOff
            ? settings.toggleAll(false)
            : settings.toggleMedication(false);
        await saved.future;
        expect(service.globalCancels, 0);
        release.complete();
        await on;
        await off;
        expect(service.pending, isEmpty);
        expect(service.maximumConcurrent, 1);
        expect(service.globalCancels, allOff ? 1 : 0);
      },
    );
  }

  test('old permission result cannot reconcile newly prepared B', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    service.beforePermission = () async {
      started.complete();
      await release.future;
    };
    final old = settings.toggleMedication(true);
    await started.future;
    reconciler.onSessionCleared();
    await reconciler.drain();
    auth.user = _User('user-b');
    await db.delete(db.medications).go();
    await seed('medication-b');
    await reconciler.onSessionPrepared('user-b');
    expect(service.scheduled, [notificationIdForMedication('medication-b')]);
    release.complete();
    await old;
    expect(service.scheduled, [notificationIdForMedication('medication-b')]);
    expect(service.exactRequests, 0);
  });

  test(
    'global OFF awaiting medication cannot cancel a later session',
    () async {
      final started = Completer<void>();
      final release = Completer<void>();
      service.beforeSchedule = () async {
        started.complete();
        await release.future;
      };
      final on = settings.toggleMedication(true);
      await started.future;
      final saved = Completer<void>();
      store.beforeLoad = (_) async {
        if (!saved.isCompleted) saved.complete();
      };
      final off = settings.toggleAll(false);
      await saved.future;
      reconciler.onSessionCleared();
      auth.user = _User('user-b');
      release.complete();
      await on;
      await off;
      expect(service.globalCancels, 0);
      expect(service.pending, isEmpty);
      expect(service.cancelled, containsAll(service.scheduled));
    },
  );

  test(
    'same UID prepared again cannot revive an old Settings admission',
    () async {
      final started = Completer<void>();
      final release = Completer<void>();
      service.beforePermission = () async {
        started.complete();
        await release.future;
      };
      final old = settings.toggleMedication(true);
      await started.future;
      reconciler.onSessionCleared();
      await reconciler.onSessionPrepared('user-a');
      expect(service.scheduled, hasLength(1));
      release.complete();
      await old;
      expect(service.scheduled, hasLength(1));
      expect(service.exactRequests, 0);
    },
  );

  test(
    'native A is compensated before B can reconcile its own records',
    () async {
      final started = Completer<void>();
      final release = Completer<void>();
      service.beforeSchedule = () async {
        started.complete();
        await release.future;
      };
      final old = settings.toggleMedication(true);
      await started.future;
      reconciler.onSessionCleared();
      auth.user = _User('user-b');
      release.complete();
      await old;
      await reconciler.drain();
      expect(service.pending, isEmpty);
      await db.delete(db.medications).go();
      await seed('medication-b');
      service.beforeSchedule = null;
      await reconciler.onSessionPrepared('user-b');
      expect(service.pending.map((request) => request.id), [
        notificationIdForMedication('medication-b'),
      ]);
      expect(service.maximumConcurrent, 1);
    },
  );

  test(
    'startup and resume use shared authority without requesting permissions',
    () async {
      store.medication = true;
      reconciler.onSessionCleared();
      await reconciler.onSessionPrepared('user-a');
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await reconciler.drain();
      expect(service.scheduled, hasLength(2));
      expect(service.permissionRequests, 0);
      expect(service.exactRequests, 0);
    },
  );
}
