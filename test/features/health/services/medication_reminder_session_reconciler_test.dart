import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/services/notification_preferences.dart';
import 'package:life_os/core/services/notification_service.dart';
import 'package:life_os/features/health/services/medication_reminder_lifecycle.dart';
import 'package:life_os/features/health/services/medication_reminder_session_reconciler.dart';

class _Notifications extends NotificationService {
  final scheduled = <int>[];
  final cancelled = <int>[];
  int permissionRequests = 0;
  int exactRequests = 0;
  int concurrent = 0;
  int maximumConcurrent = 0;
  Future<void> Function()? beforeSchedule;

  @override
  Future<bool> requestPermissions({String? preferenceKey}) async {
    permissionRequests += 1;
    throw StateError('Automatic reconcile must not request permissions');
  }

  @override
  Future<bool> requestExactAlarmPermission() async {
    exactRequests += 1;
    throw StateError('Automatic reconcile must not request exact permission');
  }

  @override
  Future<bool> scheduleMedicationNotification({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledDate,
    String? preferenceKey,
    bool repeatDaily = false,
  }) async {
    scheduled.add(id);
    concurrent += 1;
    if (concurrent > maximumConcurrent) maximumConcurrent = concurrent;
    try {
      await beforeSchedule?.call();
      return true;
    } finally {
      concurrent -= 1;
    }
  }

  @override
  Future<void> cancelNotification(int id) async => cancelled.add(id);
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late _Notifications notifications;
  late MedicationReminderLifecycleService lifecycle;
  late MedicationReminderSessionReconciler reconciler;
  late DateTime now;
  String? currentUid;
  late NotificationPreferences preferences;
  Future<void> Function()? beforePreferences;
  int preferenceReads = 0;

  Future<void> seed(String id, {DateTime? endDate}) async {
    await db
        .into(db.medications)
        .insert(
          MedicationsCompanion.insert(
            firestoreId: id,
            name: 'Test',
            startDate: DateTime(2026, 8, 20, 21),
            endDate: Value(endDate),
          ),
        );
  }

  setUp(() {
    db = AppDatabase(executor: NativeDatabase.memory());
    notifications = _Notifications();
    now = DateTime(2026, 8, 25, 12);
    currentUid = 'user-a';
    preferences = const NotificationPreferences.enabled();
    beforePreferences = null;
    preferenceReads = 0;
    lifecycle = MedicationReminderLifecycleService(
      db,
      notifications,
      now: () => now,
    );
    reconciler = MedicationReminderSessionReconciler(
      lifecycle: lifecycle,
      loadPreferences: () async {
        preferenceReads += 1;
        await beforePreferences?.call();
        return preferences;
      },
      currentUserId: () => currentUid,
      binding: binding,
    );
  });

  tearDown(() async {
    reconciler.dispose();
    await reconciler.drain();
    expect(notifications.permissionRequests, 0);
    expect(notifications.exactRequests, 0);
    await db.closeDatabase();
  });

  test(
    'startup cancela expirado e agenda ativo somente após sessão preparada',
    () async {
      await seed('expired', endDate: DateTime(2026, 8, 24));
      await seed('active', endDate: DateTime(2026, 8, 26));
      await reconciler.reconcile();
      expect(preferenceReads, 0);
      await reconciler.onSessionPrepared('user-b');
      expect(preferenceReads, 0);
      await reconciler.onSessionPrepared('user-a');
      expect(notifications.cancelled, [notificationIdForMedication('expired')]);
      expect(notifications.scheduled, [notificationIdForMedication('active')]);
      await reconciler.onSessionPrepared('user-a');
      expect(notifications.scheduled, hasLength(1));
    },
  );

  test('resume após última ocorrência cancela em vez de recriar', () async {
    await seed('last-day', endDate: DateTime(2026, 8, 25, 21));
    await reconciler.onSessionPrepared('user-a');
    now = DateTime(2026, 8, 25, 22);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await reconciler.drain();
    expect(notifications.scheduled, [notificationIdForMedication('last-day')]);
    expect(notifications.cancelled, [notificationIdForMedication('last-day')]);
  });

  for (final disabled in ['all', 'medication']) {
    test('$disabled OFF no startup/resume cancela sem agendar', () async {
      await seed('active');
      preferences = NotificationPreferences(
        allNotifications: disabled != 'all',
        studyReminders: true,
        habitReminders: true,
        medicationReminders: disabled != 'medication',
      );
      await reconciler.onSessionPrepared('user-a');
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await reconciler.drain();
      expect(notifications.scheduled, isEmpty);
      expect(notifications.cancelled, [
        notificationIdForMedication('active'),
        notificationIdForMedication('active'),
      ]);
    });
  }

  test('resume relê preferências e respeita alteração para OFF', () async {
    await seed('active');
    await reconciler.onSessionPrepared('user-a');
    preferences = const NotificationPreferences(
      allNotifications: true,
      studyReminders: true,
      habitReminders: true,
      medicationReminders: false,
    );
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await reconciler.drain();
    expect(notifications.scheduled, hasLength(1));
    expect(notifications.cancelled, [notificationIdForMedication('active')]);
  });

  test(
    'dois resumes durante startup reutilizam operação sem sobreposição',
    () async {
      await seed('active');
      final started = Completer<void>();
      final release = Completer<void>();
      notifications.beforeSchedule = () async {
        if (!started.isCompleted) started.complete();
        await release.future;
      };
      final initial = reconciler.onSessionPrepared('user-a');
      await started.future;
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(notifications.scheduled, hasLength(1));
      release.complete();
      await initial;
      expect(notifications.maximumConcurrent, 1);
      expect(notifications.scheduled, hasLength(1));
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await reconciler.drain();
      expect(notifications.scheduled, hasLength(2));
      expect(notifications.maximumConcurrent, 1);
    },
  );

  test(
    'UID muda durante leitura: nenhuma ação continua para sessão antiga',
    () async {
      await seed('expired', endDate: DateTime(2026, 8, 24));
      await seed('active');
      final started = Completer<void>();
      final release = Completer<void>();
      beforePreferences = () async {
        started.complete();
        await release.future;
      };
      final initial = reconciler.onSessionPrepared('user-a');
      await started.future;
      currentUid = 'user-b';
      release.complete();
      await initial;
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await reconciler.drain();
      expect(preferenceReads, 1);
      expect(notifications.cancelled, isEmpty);
      expect(notifications.scheduled, isEmpty);
    },
  );

  test(
    'clear durante leitura invalida operação mesmo com mesmo UID Firebase',
    () async {
      await seed('active');
      final started = Completer<void>();
      final release = Completer<void>();
      beforePreferences = () async {
        started.complete();
        await release.future;
      };
      final initial = reconciler.onSessionPrepared('user-a');
      await started.future;
      reconciler.onSessionCleared();
      release.complete();
      await initial;
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await reconciler.drain();
      expect(preferenceReads, 1);
      expect(notifications.scheduled, isEmpty);
      expect(notifications.cancelled, isEmpty);
    },
  );

  test(
    'clear durante schedule compensa e drain aguarda antes do cleanup',
    () async {
      await seed('first');
      await seed('second');
      final started = Completer<void>();
      final release = Completer<void>();
      notifications.beforeSchedule = () async {
        started.complete();
        await release.future;
      };
      final initial = reconciler.onSessionPrepared('user-a');
      await started.future;
      reconciler.onSessionCleared();
      var drained = false;
      final drain = reconciler.drain().then((_) {
        drained = true;
      });
      expect(drained, isFalse);
      release.complete();
      await initial;
      await drain;
      expect(drained, isTrue);
      expect(notifications.scheduled, [notificationIdForMedication('first')]);
      expect(notifications.cancelled, [notificationIdForMedication('first')]);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await reconciler.drain();
      expect(notifications.scheduled, hasLength(1));
    },
  );

  test(
    'novo prepare após clear do mesmo UID não readmite geração anterior',
    () async {
      await seed('active');
      final started = Completer<void>();
      final release = Completer<void>();
      notifications.beforeSchedule = () async {
        if (!started.isCompleted) started.complete();
        await release.future;
      };
      final old = reconciler.onSessionPrepared('user-a');
      await started.future;
      reconciler.onSessionCleared();
      final next = reconciler.onSessionPrepared('user-a');
      release.complete();
      await old;
      await next;
      expect(notifications.cancelled, [notificationIdForMedication('active')]);
      expect(notifications.scheduled, hasLength(2));
      expect(notifications.maximumConcurrent, 1);
    },
  );

  test(
    'dispose remove observer e ignora resume e prepare posteriores',
    () async {
      await seed('active');
      await reconciler.onSessionPrepared('user-a');
      reconciler.dispose();
      reconciler.dispose();
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await reconciler.onSessionPrepared('user-a');
      await reconciler.drain();
      expect(preferenceReads, 1);
      expect(notifications.scheduled, hasLength(1));
    },
  );
}
