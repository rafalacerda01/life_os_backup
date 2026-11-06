import 'package:firebase_auth/firebase_auth.dart';
import 'package:life_os/core/services/auth_logout_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:life_os/core/services/generational_read_policy.dart';
import 'package:life_os/features/settings/presentation/providers/notification_provider.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/session_database_coordinator.dart';
import 'package:life_os/core/database/user_database_storage_destroyer.dart';
import 'package:life_os/core/db/user_db_key_manager.dart';
import 'package:life_os/core/storage/secure_storage_service.dart';
import '../db/fake_secure_storage.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:life_os/core/database/local_database_identity.dart';
import 'package:life_os/core/database/local_account_session.dart';
import 'package:life_os/core/storage/generational_local_store.dart';
import 'package:life_os/core/storage/generational_cleanup.dart';
import 'package:life_os/core/storage/ai_consent_local_cache.dart';
import 'package:life_os/core/services/notification_preferences.dart';
import 'package:life_os/core/services/notification_service.dart';
import 'package:life_os/core/services/owned_notification_service.dart';
import 'package:life_os/core/services/native_notification_registry.dart';
import 'package:life_os/core/services/trusted_account_access.dart';
import 'package:life_os/features/auth/data/local/auth_cleanup_barrier.dart';
import 'package:life_os/features/auth/data/local/account_deletion_cleanup_barrier.dart';
import 'package:life_os/features/health/presentation/cycle/cycle_reminder_preferences.dart';
import 'package:life_os/features/health/services/cycle_reminder_action_security.dart';

// Synthetic local scopes test addressing/concurrency only. They confer no
// Auth provenance, remote admission or permission to open the real cohort.
const ga = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    gb = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
LocalDatabaseIdentity scope(
  String generation, {
  String uid = 'same',
  String project = 'demo-life-os',
  String database = '(default)',
  String? tenant,
}) => LocalDatabaseIdentity.bound(
  projectId: project,
  databaseId: database,
  tenantId: tenant,
  uid: uid,
  generation: generation,
);

class LogoutAuth extends Fake implements FirebaseAuth {
  int signOutCalls = 0;
  @override
  Future<void> signOut() async {
    signOutCalls++;
  }
}

class Memory
    implements
        AuthCleanupBarrierStorage,
        CycleReminderPreferencesStorage,
        CycleReminderActionTokenStorage {
  final values = <String, String>{};
  bool discardWrites = false, discardDeletes = false;
  Future<void> Function(String key)? beforeWrite;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    await beforeWrite?.call(key);
    if (!discardWrites) values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    if (!discardDeletes) values.remove(key);
  }

  Future<Set<String>> keys() async => values.keys.toSet();
  GenerationalLocalStore store(
    LocalDatabaseIdentity identity, {
    String domain = 'test',
  }) => GenerationalLocalStore(
    identity: identity,
    domain: domain,
    read: read,
    write: write,
    delete: delete,
    listKeys: keys,
  );
  GenerationalCleanupJournal get cleanup =>
      GenerationalCleanupJournal(read: read, write: write);
}

class Native extends NotificationService {
  final pending = <int, PendingNotificationRequest>{};
  final active = <int, ActiveNotification>{};
  final tags = <int, String>{};
  final cancelled = <int>[];
  int ownedPermissionCalls = 0;
  @override
  Future<bool> requestOwnedPermissions() async {
    ownedPermissionCalls++;
    return true;
  }

  @override
  Future<bool> requestPermissions({String? preferenceKey}) async =>
      throw StateError("LEGACY_PERMISSION_MUST_NOT_RUN");
  bool failCancel = false, loseResponse = false;
  Completer<void>? hold, entered;
  NotificationResponseHandler? handler;
  @override
  Future<void> init() async {}
  @override
  Future<List<PendingNotificationRequest>>
  pendingNotificationRequests() async => pending.values.toList();
  @override
  Future<List<ActiveNotification>> activeNotificationRequests() async =>
      active.values.toList();
  @override
  Future<bool> scheduleOwnedNotification({
    required int id,
    required String tag,
    required String payload,
    required String kind,
    required String title,
    required String body,
    required DateTime scheduledDate,
    bool repeatDaily = false,
    int? weekday,
    bool includeDoneAction = false,
    bool snooze = false,
    bool immediate = false,
    bool Function()? canSend,
  }) async {
    if (canSend?.call() != true) return false;
    entered?.complete();
    await hold?.future;
    if (canSend?.call() != true) return false;
    pending[id] = PendingNotificationRequest(id, title, body, payload);
    tags[id] = tag;
    if (loseResponse) throw StateError('APPLIED_RESPONSE_UNKNOWN');
    return true;
  }

  @override
  Future<void> cancelOwnedNotification(int id, String tag) async {
    if (failCancel) throw StateError('NATIVE_CANCEL_UNKNOWN');
    if (tags[id] != null && tags[id] != tag) throw StateError('FOREIGN_TAG');
    pending.remove(id);
    active.remove(id);
    cancelled.add(id);
  }

  @override
  void setNotificationResponseHandler(NotificationResponseHandler? h) {
    handler = h;
  }

  @override
  Future<void> cancelAllNotificationsOrThrow() async =>
      throw StateError('GLOBAL_CANCEL_MUST_NOT_RUN');
  @override
  Future<void> cancelNotificationOrThrow(int id) async =>
      throw StateError('UNOWNED_CANCEL_MUST_NOT_RUN');
}

class LegacyPlugin extends Fake implements FlutterLocalNotificationsPlugin {
  final pending = <int, PendingNotificationRequest>{};
  final active = <ActiveNotification>[];
  final cancelled = <int>[];
  @override
  Future<bool?> initialize({
    required InitializationSettings settings,
    DidReceiveNotificationResponseCallback? onDidReceiveNotificationResponse,
    DidReceiveBackgroundNotificationResponseCallback?
    onDidReceiveBackgroundNotificationResponse,
  }) async => true;
  @override
  Future<List<PendingNotificationRequest>>
  pendingNotificationRequests() async => pending.values.toList();
  @override
  Future<List<ActiveNotification>> getActiveNotifications() async => active;
  @override
  Future<void> cancel({required int id, String? tag}) async {
    cancelled.add(id);
    pending.remove(id);
  }

  @override
  Future<void> cancelAll() async =>
      throw StateError('GLOBAL_NATIVE_CANCEL_FORBIDDEN');
}

Future<bool> schedule(
  OwnedNotificationService service, {
  int logicalId = 7,
  String payload = 'medication',
}) => service.scheduleMedicationNotification(
  id: logicalId,
  title: 'Synthetic',
  body: 'No real data',
  scheduledDate: DateTime(2030),
  payload: payload,
);
CycleReminderPreferences preferences(int hour) => CycleReminderPreferences(
  enabled: true,
  type: CycleReminderType.personal,
  hour: hour,
  minute: 0,
  frequency: CycleReminderFrequency.daily,
);

class BoundApp extends Fake implements FirebaseApp {
  BoundApp(this.project);
  final String project;
  @override
  FirebaseOptions get options => FirebaseOptions(
    apiKey: 'demo-key',
    appId: 'demo-app',
    messagingSenderId: 'demo',
    projectId: project,
  );
}

class BoundFirestore extends Fake implements FirebaseFirestore {
  BoundFirestore(String project, this.databaseId) : app = BoundApp(project);
  @override
  final FirebaseApp app;
  @override
  String databaseId;
}

class HeldNotificationPreferences extends NotificationPreferencesStore {
  HeldNotificationPreferences(this.delegate, this.entered, this.release);
  final NotificationPreferencesStore delegate;
  final Completer<void> entered, release;
  @override
  Future<NotificationPreferences> load() => delegate.load();
  @override
  Future<void> save(String key, bool value) async {
    entered.complete();
    await release.future;
    await delegate.save(key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'full binding separates project/database/tenant/UID/generation and legacy/R1 drafts',
    () {
      final all = [
        scope(ga),
        scope(gb),
        scope(ga, uid: 'B'),
        scope(ga, project: 'other-demo'),
        scope(ga, database: 'other'),
        scope(ga, tenant: 'tenant'),
        LocalDatabaseIdentity('same'),
        LocalDatabaseIdentity('same', generation: ga),
      ];
      expect(all.map((s) => s.fileName).toSet().length, all.length);
      expect(all.map((s) => s.keyAlias).toSet().length, all.length);
      expect(
        LocalDatabaseIdentity.fromBinding(scope(ga).toBinding()),
        scope(ga),
      );
      expect(all.last.isBound, isFalse);
      expect(TrustedAccountAccess.localSessionClosed, isTrue);
    },
  );
  for (final input in [
    {...scope(ga).toBinding(), 'generation': true},
    {...scope(ga).toBinding(), 'extra': 'unknown'},
    {...scope(ga).toBinding(), 'tenant': ''},
  ]) {
    test('malformed local binding is refused $input', () {
      expect(() => LocalDatabaseIdentity.fromBinding(input), throwsA(anything));
    });
  }
  for (final sameUid in [true, false]) {
    test('captured lease invalidates A after B, same UID=$sameUid', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final session = container.read(localAccountSessionProvider.notifier);
      session.bind(scope(ga));
      final a = session.capture();
      session.clear();
      session.bind(scope(gb, uid: sameUid ? 'same' : 'B'));
      final b = session.capture();
      expect(a.isCurrent, isFalse);
      expect(a.requireCurrent, throwsStateError);
      expect(b.isCurrent, isTrue);
    });
  }
  test('store restart never adopts legacy or another generation', () async {
    final m = Memory();
    m.values['setting'] = 'legacy';
    await m.store(scope(ga)).write('setting', 'A');
    expect(await m.store(scope(gb)).read('setting'), isNull);
    await m.store(scope(gb)).write('setting', 'B');
    expect(await m.store(scope(ga)).read('setting'), 'A');
    await m.store(scope(ga)).retire();
    expect(await m.store(scope(gb)).read('setting'), 'B');
    expect(m.values['setting'], 'legacy');
    await expectLater(m.store(scope(ga)).write('late', 'A'), throwsStateError);
  });
  test(
    'late A write is drained by A seal while B writes independently',
    () async {
      final m = Memory(), a = m.store(scope(ga)), b = m.store(scope(gb));
      final entered = Completer<void>(), release = Completer<void>();
      m.beforeWrite = (key) async {
        if (key == a.keyFor('pending')) {
          entered.complete();
          await release.future;
        }
      };
      final pending = a.write('pending', 'A');
      await entered.future;
      final deletion = m.store(scope(ga)).retire();
      await b.write('pending', 'B');
      release.complete();
      await pending;
      await deletion;
      expect(await b.read('pending'), 'B');
      expect(m.values.containsKey(a.keyFor('pending')), isFalse);
    },
  );
  test('unmanifested or orphan local value is refused and preserved', () async {
    final m = Memory(), s = m.store(scope(ga));
    m.values[s.keyFor('orphan')] = 'old';
    await expectLater(s.read('orphan'), throwsStateError);
    await expectLater(s.write('orphan', 'claim'), throwsStateError);
    await expectLater(s.retire(), throwsStateError);
    expect(m.values[s.keyFor('orphan')], 'old');
    expect((jsonDecode(m.values[s.journalKey]!) as Map)['state'], 'SEALED');
  });
  test('durable delete failure never becomes COMPLETE, B survives', () async {
    final m = Memory(), a = m.store(scope(ga)), b = m.store(scope(gb));
    await a.write('pending', 'A');
    await b.write('pending', 'B');
    m.discardDeletes = true;
    await expectLater(a.retire(), throwsStateError);
    expect((jsonDecode(m.values[a.journalKey]!) as Map)['state'], 'SEALED');
    expect(await b.read('pending'), 'B');
    m.discardDeletes = false;
    await m.store(scope(ga)).retire();
    expect((jsonDecode(m.values[a.journalKey]!) as Map)['state'], 'COMPLETE');
  });
  test('discarded intent does not permit a value write or false ACK', () async {
    final m = Memory(), s = m.store(scope(ga));
    m.discardWrites = true;
    await expectLater(s.write('value', 'A'), throwsStateError);
    expect(m.values, isEmpty);
  });
  test(
    'finite key budget refuses excess without clamping or discarding values',
    () async {
      final m = Memory(), s = m.store(scope(ga));
      for (var i = 0; i < GenerationalLocalStore.maxKeys; i++) {
        await s.write('k$i', '$i');
      }
      await expectLater(s.write('excess', 'not accepted'), throwsStateError);
      expect(await s.read('k0'), '0');
    },
  );
  test('contradictory journal cannot claim a namespace', () async {
    final m = Memory(), s = m.store(scope(ga));
    await s.write('A', 'A');
    final d = jsonDecode(m.values[s.journalKey]!) as Map;
    d['binding'] = scope(gb).toBinding();
    m.values[s.journalKey] = jsonEncode(d);
    final before = Map.of(m.values);
    await expectLater(s.retire(), throwsA(anything));
    expect(m.values, before);
  });
  test(
    'cycle preferences and action tokens survive restart without UID adoption',
    () async {
      final m = Memory(), a = scope(ga), b = scope(gb);
      final pa = CycleReminderPreferencesStore.scoped(m, a, listKeys: m.keys),
          pb = CycleReminderPreferencesStore.scoped(m, b, listKeys: m.keys);
      await pa.save('same', preferences(8));
      expect(await pb.load('same'), isNull);
      await pb.save('same', preferences(9));
      final ta = CycleReminderActionTokenStore.scoped(m, a, listKeys: m.keys),
          tb = CycleReminderActionTokenStore.scoped(m, b, listKeys: m.keys);
      final tokenA = await ta.getOrCreate('same'),
          tokenB = await tb.getOrCreate('same');
      expect(tokenA, isNot(tokenB));
      await pa.retire();
      await ta.retire();
      expect((await pb.load('same'))?.hour, 9);
      expect(
        await CycleReminderActionTokenStore.scoped(
          m,
          b,
          listKeys: m.keys,
        ).load('same'),
        tokenB,
      );
      await expectLater(ta.getOrCreate('same'), throwsStateError);
    },
  );
  test(
    'account notification preferences and AI cache do not inherit legacy globals',
    () async {
      SharedPreferences.setMockInitialValues({
        'all_notifications': false,
        'ai_consent_accepted_same': true,
        'onboardingCompleted': true,
      });
      final a = NotificationPreferencesStore.scoped(scope(ga)),
          b = NotificationPreferencesStore.scoped(scope(gb));
      expect((await a.load()).allNotifications, isTrue);
      await a.save('all_notifications', false);
      expect((await b.load()).allNotifications, isTrue);
      await b.save('study_reminders', false);
      final cache = AiConsentLocalCache();
      await cache.write('same', identity: scope(ga));
      await cache.write('same', identity: scope(gb));
      await cache.deleteForAccount('same', identity: scope(ga));
      await a.retire();
      expect((await b.load()).studyReminders, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('all_notifications'), isFalse);
      expect(prefs.getBool('onboardingCompleted'), isTrue);
      expect(await cache.write('same', identity: scope(gb)), isTrue);
      await expectLater(
        cache.write('same', identity: scope(ga)),
        throwsStateError,
      );
    },
  );
  test(
    'logout and deletion markers bind full identity and never inherit UID-only markers',
    () async {
      final m = Memory(), a = scope(ga), b = scope(gb);
      final legacy = AuthCleanupBarrierStore(m);
      await legacy.setPending('same', AuthCleanupIntent.logout);
      final aa = AuthCleanupBarrierStore(m, identity: a, listKeys: m.keys),
          ab = AuthCleanupBarrierStore(m, identity: b, listKeys: m.keys);
      expect(await aa.readPending(), isNull);
      final marker = await aa.setPending('same', AuthCleanupIntent.logout);
      expect(marker.identity, a);
      expect(await ab.clearIfCurrent(marker), isFalse);
      expect((await legacy.readPending())?.identity, isNull);
      final da = AccountDeletionCleanupBarrier(
            m,
            identity: a,
            listKeys: m.keys,
          ),
          db = AccountDeletionCleanupBarrier(m, identity: b, listKeys: m.keys);
      final requested = await da.request('same');
      await expectLater(db.confirmIfCurrent(requested), throwsStateError);
      final confirmed = await da.confirmIfCurrent(requested);
      expect(confirmed.identity, a);
      expect(await db.clearIfCurrent(confirmed), isFalse);
    },
  );
  test(
    'UNKNOWN remote outcome remains REQUESTED and cannot run cleanup effects',
    () async {
      final m = Memory(),
          journal = m.cleanup,
          request = await journal.request(scope(ga));
      var effects = 0;
      await expectLater(
        journal.resume(request, {
          'preferences': (_) async {
            effects++;
          },
          'notifications': (_) async {
            effects++;
          },
          'database': (_) async {
            effects++;
          },
        }),
        throwsStateError,
      );
      expect(effects, 0);
      expect((await m.cleanup.read(scope(ga)))?.phase, 'REQUESTED');
    },
  );
  test(
    'interrupted confirmed deletion resumes original finite plan and retains terminal receipt',
    () async {
      final m = Memory(), a = scope(ga), b = scope(gb);
      await m.store(b).write('private', 'B');
      var receipt = await m.cleanup.confirmOriginalResponse(
        await m.cleanup.request(a),
      );
      var first = 0, last = 0;
      var fail = true;
      final effects = <String, Future<void> Function(LocalDatabaseIdentity)>{
        'preferences': (id) async {
          expect(id, a);
          first++;
        },
        'notifications': (id) async {
          expect(id, a);
          if (fail) throw StateError('UNKNOWN_NATIVE');
        },
        'database': (id) async {
          expect(id, a);
          last++;
        },
      };
      await expectLater(m.cleanup.resume(receipt, effects), throwsStateError);
      receipt = (await m.cleanup.read(a))!;
      expect(receipt.completedSteps, ['preferences']);
      expect(receipt.isComplete, isFalse);
      fail = false;
      final complete = await m.cleanup.resume(receipt, effects);
      expect(complete.isComplete, isTrue);
      expect(first, 1);
      expect(last, 1);
      await m.cleanup.resume(complete, effects);
      expect(first, 1);
      expect(last, 1);
      expect(await m.store(b).read('private'), 'B');
      expect((await m.cleanup.request(a)).isComplete, isTrue);
    },
  );
  test(
    'cleanup delayed across B start receives A identity after every await',
    () async {
      final m = Memory(), a = scope(ga), b = scope(gb);
      await m.store(a).write('queue', 'HOLD');
      await m.store(b).write('queue', 'pending');
      final marker = await m.cleanup.confirmOriginalResponse(
        await m.cleanup.request(a, plan: ['preferences']),
      );
      final pause = Completer<void>(), release = Completer<void>();
      final execution = m.cleanup.resume(marker, {
        'preferences': (target) async {
          pause.complete();
          await release.future;
          await m.store(target).retire();
        },
      });
      await pause.future;
      await m.store(b).write('queue', 'B-active');
      release.complete();
      await execution;
      expect(await m.store(b).read('queue'), 'B-active');
    },
  );
  test(
    'cleanup plan replacement and malformed stored confirmation refuse effects',
    () async {
      final m = Memory(), a = scope(ga);
      final request = await m.cleanup.request(a, plan: ['database']);
      final confirmed = await m.cleanup.confirmOriginalResponse(request);
      var ran = false;
      await expectLater(
        m.cleanup.resume(confirmed, {
          'other': (_) async {
            ran = true;
          },
        }),
        throwsStateError,
      );
      expect(ran, isFalse);
      final d = jsonDecode(m.values[m.cleanup.keyFor(a)]!) as Map;
      d['binding'] = scope(gb).toBinding();
      m.values[m.cleanup.keyFor(a)] = jsonEncode(d);
      await expectLater(m.cleanup.read(a), throwsA(anything));
    },
  );
  for (final sameUid in [true, false]) {
    test(
      'late native cancellation of A preserves B, same UID=$sameUid',
      () async {
        final db = NativeNotificationRegistry(sqlite3.openInMemory());
        addTearDown(db.close);
        final native = Native(),
            a = scope(ga),
            b = scope(gb, uid: sameUid ? 'same' : 'B');
        var current = a;
        OwnedNotificationService service(LocalDatabaseIdentity id) =>
            OwnedNotificationService(
              identity: id,
              native: native,
              isCurrent: () => current == id,
              registry: () async => db,
              android: true,
              preferences: () async => const NotificationPreferences.enabled(),
            );
        final sa = service(a), sb = service(b);
        expect(await schedule(sa), isTrue);
        final aid = native.pending.keys.single;
        current = b;
        expect(await schedule(sb), isTrue);
        final bid = native.pending.keys.singleWhere((id) => id != aid);
        expect(aid, isNot(bid));
        await sa.cancelAllNotificationsOrThrow();
        expect(native.pending.keys, [bid]);
        await sb.retire();
        expect(native.pending, isEmpty);
        await expectLater(schedule(sb), throwsStateError);
      },
    );
  }
  test(
    'native allocation survives restart and independent SQLite connections',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lifeos-generational-',
      );
      final path = '${directory.path}/registry.sqlite';
      final first = NativeNotificationRegistry(sqlite3.open(path)),
          second = NativeNotificationRegistry(sqlite3.open(path));
      final a = first.reserve(scope(ga), 7, 'A', {}),
          b = second.reserve(scope(gb), 7, 'B', {});
      expect(a.id, isNot(b.id));
      first.state(a, 'RETIRED');
      first.close();
      second.close();
      final restart = NativeNotificationRegistry(sqlite3.open(path));
      expect(restart.reserve(scope(ga), 7, 'A-new', {}).id, greaterThan(b.id));
      restart.seal(scope(gb));
      restart.close();
      final again = NativeNotificationRegistry(sqlite3.open(path));
      expect(
        () => again.reserve(scope(gb), 7, 'resurrect', {}),
        throwsStateError,
      );
      again.close();
      expect(directory.path.startsWith(Directory.systemTemp.path), isTrue);
      await directory.delete(recursive: true);
    },
  );
  test(
    'in-flight native schedule invalidated by B compensates only its captured row',
    () async {
      final db = NativeNotificationRegistry(sqlite3.openInMemory());
      addTearDown(db.close);
      final native = Native()
        ..hold = Completer<void>()
        ..entered = Completer<void>();
      var active = true;
      final a = OwnedNotificationService(
        identity: scope(ga),
        native: native,
        isCurrent: () => active,
        registry: () async => db,
        android: true,
        preferences: () async => const NotificationPreferences.enabled(),
      );
      final execution = schedule(a);
      await native.entered!.future;
      active = false;
      native.hold!.complete();
      expect(await execution, isFalse);
      expect(native.pending, isEmpty);
      expect(db.records(scope(ga)).single.state, 'RETIRED');
    },
  );
  test(
    'native response loss stays UNKNOWN; failed cancellation cannot complete',
    () async {
      final db = NativeNotificationRegistry(sqlite3.openInMemory());
      addTearDown(db.close);
      final native = Native()..loseResponse = true;
      final a = OwnedNotificationService(
        identity: scope(ga),
        native: native,
        isCurrent: () => true,
        registry: () async => db,
        android: true,
        preferences: () async => const NotificationPreferences.enabled(),
      );
      await expectLater(schedule(a), throwsStateError);
      expect(db.records(scope(ga)).single.state, 'UNKNOWN');
      expect(native.pending.length, 1);
      native.failCancel = true;
      await expectLater(a.retire(), throwsStateError);
      expect(db.records(scope(ga)).single.state, isNot('RETIRED'));
      native.failCancel = false;
      await a.retire();
      expect(native.pending, isEmpty);
    },
  );
  test(
    'foreign payload at reserved native ID is preserved without cancellation',
    () async {
      final db = NativeNotificationRegistry(sqlite3.openInMemory());
      addTearDown(db.close);
      final native = Native();
      final a = OwnedNotificationService(
        identity: scope(ga),
        native: native,
        isCurrent: () => true,
        registry: () async => db,
        android: true,
        preferences: () async => const NotificationPreferences.enabled(),
      );
      await schedule(a);
      final id = native.pending.keys.single;
      native.pending[id] = PendingNotificationRequest(id, 'B', 'B', 'foreign');
      await expectLater(a.retire(), throwsStateError);
      expect(native.pending[id]?.payload, 'foreign');
      expect(native.cancelled, isEmpty);
    },
  );
  test(
    'late callback from A is never delivered to same-UID generation B',
    () async {
      final db = NativeNotificationRegistry(sqlite3.openInMemory());
      addTearDown(db.close);
      final native = Native();
      var current = ga;
      OwnedNotificationService service(String g) => OwnedNotificationService(
        identity: scope(g),
        native: native,
        isCurrent: () => current == g,
        registry: () async => db,
        android: true,
        preferences: () async => const NotificationPreferences.enabled(),
      );
      final a = service(ga);
      await schedule(a, payload: 'A-action');
      final p = native.pending.values.single;
      current = gb;
      final b = service(gb);
      var calls = 0;
      b.setNotificationResponseHandler((_) async {
        calls++;
      });
      await native.handler!(
        NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotification,
          id: p.id,
          payload: p.payload,
        ),
      );
      expect(calls, 0);
      await schedule(b, payload: 'B-action');
      final own = native.pending.values.singleWhere((n) => n.id != p.id);
      await native.handler!(
        NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotification,
          id: own.id,
          payload: own.payload,
        ),
      );
      expect(calls, 1);
    },
  );

  test(
    'real Drift restart and same-UID swap retain each pending/HOLD queue without ACK',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lifeos-generation-drift-',
      );
      String? uid = 'same';
      SessionDatabaseCoordinator coordinator() => SessionDatabaseCoordinator(
        currentUserId: () => uid,
        openDatabase: (id) async => AppDatabase.forUser(
          identity: id,
          executor: NativeDatabase(id.fileIn(directory)),
        ),
      );
      var session = coordinator();
      final a = scope(ga), b = scope(gb);
      final first = await session.prepare('same', accountIdentity: a);
      await first
          .into(first.syncQueueTable)
          .insert(
            SyncQueueTableCompanion.insert(
              ownerUid: const Value('same'),
              collection: 'subjects',
              docId: 'A-held',
              operationType: 'delete',
              payloadJson: '{}',
              createdAt: 1,
              lastErrorCode: const Value('STUDY_REVIEW_QUEUE_STATE_INVALID'),
            ),
          );
      session.observeSession(null);
      uid = null;
      await session.detach(expectedUid: 'same');
      uid = 'same';
      final second = await session.prepare('same', accountIdentity: b);
      expect(await second.select(second.syncQueueTable).get(), isEmpty);
      await second
          .into(second.syncQueueTable)
          .insert(
            SyncQueueTableCompanion.insert(
              ownerUid: const Value('same'),
              collection: 'notes',
              docId: 'B-pending',
              operationType: 'update',
              payloadJson: '{}',
              createdAt: 2,
            ),
          );
      // A deletion does not blacklist B by UID or close B's attached database.
      await session.destroy(a, () async {
        expect(second.identity, b);
      });
      expect(session.requirePrepared().identity, b);
      expect(
        (await second.select(second.syncQueueTable).get()).single.isSynced,
        isFalse,
      );
      await session.dispose();
      session = coordinator();
      final restored = await session.prepare('same', accountIdentity: a);
      final row = (await restored.select(restored.syncQueueTable).get()).single;
      expect(row.docId, 'A-held');
      expect(row.lastErrorCode, 'STUDY_REVIEW_QUEUE_STATE_INVALID');
      expect(row.isSynced, isFalse);
      expect(row.attemptCount, 0);
      await session.dispose();
      expect(directory.path.startsWith(Directory.systemTemp.path), isTrue);
      await directory.delete(recursive: true);
    },
  );
  test(
    'delayed A file/key destruction and token removal preserve same-UID B and legacy',
    () async {
      final directory = await Directory.systemTemp.createTemp(
            'lifeos-generation-files-',
          ),
          storage = FakeSecureStorage();
      final a = scope(ga),
          b = scope(gb),
          legacy = LocalDatabaseIdentity('same'),
          keys = UserDbKeyManager(storage: storage);
      await keys.getEncryptionKey(a, allowCreate: true);
      await keys.getEncryptionKey(b, allowCreate: true);
      a.fileIn(directory).writeAsStringSync('A');
      b.fileIn(directory).writeAsStringSync('B');
      legacy.fileIn(directory).writeAsStringSync('legacy');
      final destroyer = UserDatabaseStorageDestroyer(
        directoryProvider: () async => directory,
        keyManager: keys,
      );
      await destroyer.destroy(a);
      expect(b.fileIn(directory).readAsStringSync(), 'B');
      expect(legacy.fileIn(directory).readAsStringSync(), 'legacy');
      expect(storage.values.containsKey(b.keyAlias), isTrue);
      expect(storage.values.containsKey(a.keyAlias), isFalse);
      storage.values[SecureStorageService.tokenKey] = 'legacy-token';
      await SecureStorageService.scoped(storage, a).saveToken('A-token');
      await SecureStorageService.scoped(storage, b).saveToken('B-token');
      await SecureStorageService.scoped(storage, a).deleteToken();
      expect(
        await SecureStorageService.scoped(storage, b).getToken(),
        'B-token',
      );
      expect(storage.values[SecureStorageService.tokenKey], 'legacy-token');
      expect(directory.path.startsWith(Directory.systemTemp.path), isTrue);
      await directory.delete(recursive: true);
    },
  );

  test(
    'legacy cancellation cannot erase owned pending or active Android notifications',
    () async {
      final registry = NativeNotificationRegistry(sqlite3.openInMemory());
      addTearDown(registry.close);
      final row = registry.reserve(scope(gb), 7, 'B', {}),
          plugin = LegacyPlugin();
      plugin.pending[3] = const PendingNotificationRequest(
        3,
        'legacy',
        'legacy',
        null,
      );
      plugin.pending[row.id] = PendingNotificationRequest(
        row.id,
        'B',
        'B',
        row.deliveryPayload,
      );
      plugin.active.add(ActiveNotification(id: row.id, tag: row.tag));
      final service = NotificationService(
        notificationsPlugin: plugin,
        isAndroidOverride: false,
        deviceTimeZoneResolver: () async => 'UTC',
      );
      await service.cancelAllNotificationsOrThrow();
      expect(plugin.cancelled, [3]);
      expect(plugin.pending.containsKey(row.id), isTrue);
      await expectLater(
        service.cancelNotificationOrThrow(row.id),
        throwsStateError,
      );
      expect(plugin.cancelled, [3]);
    },
  );
  test(
    'timeout preserves native intent and queue until the original result is handled',
    () async {
      final registry = NativeNotificationRegistry(sqlite3.openInMemory());
      addTearDown(registry.close);
      final native = Native()
        ..hold = Completer<void>()
        ..entered = Completer<void>();
      var current = true;
      final a = OwnedNotificationService(
        identity: scope(ga),
        native: native,
        isCurrent: () => current,
        registry: () async => registry,
        android: true,
        preferences: () async => const NotificationPreferences.enabled(),
      );
      final execution = schedule(a);
      await native.entered!.future;
      await expectLater(
        execution.timeout(const Duration(milliseconds: 10)),
        throwsA(isA<TimeoutException>()),
      );
      expect(registry.records(scope(ga)).single.state, 'RESERVED');
      final memory = Memory();
      await memory.store(scope(gb)).write('queue', 'B-pending');
      current = false;
      native.hold!.complete();
      expect(await execution, isFalse);
      expect(await memory.store(scope(gb)).read('queue'), 'B-pending');
    },
  );
  test(
    'native seals and terminal rows never reopen after late acknowledgments',
    () {
      final registry = NativeNotificationRegistry(sqlite3.openInMemory());
      addTearDown(registry.close);
      final row = registry.reserve(scope(ga), 7, 'A', {});
      registry.state(row, 'RETIRED');
      expect(() => registry.state(row, 'ACTIVE'), throwsStateError);
      expect(() => registry.state(row, 'UNKNOWN'), throwsStateError);
      final other = registry.reserve(scope(gb), 7, 'B', {});
      registry.seal(scope(gb));
      expect(() => registry.state(other, 'ACTIVE'), throwsStateError);
      expect(registry.records(scope(ga)).single.state, 'RETIRED');
    },
  );
  test('native finite manifest and ID exhaustion refuse without mutation', () {
    final registry = NativeNotificationRegistry(sqlite3.openInMemory());
    addTearDown(registry.close);
    final row = registry.reserve(scope(ga), 7, 'A', {1000000});
    expect(row.id, 1000001);
    registry.database.execute(
      'UPDATE native_notification_owners SET id=? WHERE id=?',
      [0x7fffffff, row.id],
    );
    expect(() => registry.reserve(scope(gb), 7, 'B', {}), throwsStateError);
    expect(
      registry.database
          .select('SELECT COUNT(*) AS n FROM native_notification_owners')
          .single['n'],
      1,
    );
  });
  test('unsupported native platform is CLOSED without scheduling', () async {
    final native = Native();
    final registry = NativeNotificationRegistry(sqlite3.openInMemory());
    addTearDown(registry.close);
    final service = OwnedNotificationService(
      identity: scope(ga),
      native: native,
      isCurrent: () => true,
      registry: () async => registry,
      android: false,
      preferences: () async => const NotificationPreferences.enabled(),
    );
    await expectLater(schedule(service), throwsStateError);
    expect(native.pending, isEmpty);
    expect(registry.records(scope(ga)), isEmpty);
  });

  for (final fromCache in [false, true]) {
    for (final pending in [false, true]) {
      test(
        'bound hydration refuses UID-only SDK cache=$fromCache pending=$pending',
        () {
          expect(
            GenerationalReadPolicy.accepts(
              scope(ga),
              fromCache: fromCache,
              pendingWrites: pending,
            ),
            !fromCache && !pending,
          );
          expect(
            GenerationalReadPolicy.accepts(
              LocalDatabaseIdentity('same'),
              fromCache: fromCache,
              pendingWrites: pending,
            ),
            isTrue,
          );
        },
      );
    }
  }
  test(
    'bound hydration binds SDK project/database and requires Source.server',
    () {
      expect(
        GenerationalReadPolicy.options(
          scope(ga),
          BoundFirestore('demo-life-os', '(default)'),
        )?.source,
        Source.server,
      );
      expect(
        () => GenerationalReadPolicy.options(
          scope(ga),
          BoundFirestore('other', '(default)'),
        ),
        throwsStateError,
      );
      expect(
        () => GenerationalReadPolicy.options(
          scope(ga),
          BoundFirestore('demo-life-os', 'named'),
        ),
        throwsStateError,
      );
      expect(
        () => GenerationalReadPolicy.options(
          LocalDatabaseIdentity('same', generation: ga),
          BoundFirestore('demo-life-os', '(default)'),
        ),
        throwsStateError,
      );
    },
  );
  test(
    'late Settings completion cannot publish A preferences in B same-UID session',
    () async {
      SharedPreferences.setMockInitialValues({});
      final entered = Completer<void>(), release = Completer<void>();
      final a = scope(ga),
          b = scope(gb),
          storeA = NotificationPreferencesStore.scoped(a),
          storeB = NotificationPreferencesStore.scoped(b);
      final container = ProviderContainer(
        overrides: [
          notificationPreferencesStoreProvider.overrideWith(
            (ref) => ref.watch(localAccountSessionProvider).identity == a
                ? HeldNotificationPreferences(storeA, entered, release)
                : storeB,
          ),
          notificationPreferencesChangedProvider.overrideWithValue(() {}),
        ],
      );
      addTearDown(container.dispose);
      final session = container.read(localAccountSessionProvider.notifier);
      session.bind(a);
      await container.read(notificationsProvider.future);
      final execution = container
          .read(notificationsProvider.notifier)
          .toggleStudy(false);
      await entered.future;
      session.bind(b);
      await container.read(notificationsProvider.future);
      release.complete();
      await execution;
      expect(
        container.read(notificationsProvider).requireValue.studyReminders,
        isTrue,
      );
      expect((await storeA.load()).studyReminders, isFalse);
      expect((await storeB.load()).studyReminders, isTrue);
    },
  );

  test('native journal persists payload digest, not a copied action token', () {
    final registry = NativeNotificationRegistry(sqlite3.openInMemory());
    addTearDown(registry.close);
    final row = registry.reserve(scope(ga), 7, 'synthetic-action-token', {});
    expect(
      registry.database
          .select('SELECT payload FROM native_notification_owners')
          .single['payload'],
      isNot(contains('synthetic-action-token')),
    );
    expect(registry.matches(row, row.deliveryPayload), isTrue);
    expect(
      registry.originalPayload(
        registry.records(scope(ga)).single,
        row.deliveryPayload,
      ),
      'synthetic-action-token',
    );
  });

  test(
    'owned permission/category checks never inherit the old global preferences',
    () async {
      SharedPreferences.setMockInitialValues({
        'all_notifications': false,
        'study_reminders': false,
      });
      final native = Native(),
          registry = NativeNotificationRegistry(sqlite3.openInMemory());
      addTearDown(registry.close);
      final own = NotificationPreferencesStore.scoped(scope(gb));
      final service = OwnedNotificationService(
        identity: scope(gb),
        native: native,
        isCurrent: () => true,
        registry: () async => registry,
        android: true,
        preferences: own.load,
      );
      expect(
        await service.requestPermissions(
          preferenceKey: NotificationPreferenceKeys.studyReminders,
        ),
        isTrue,
      );
      expect(native.ownedPermissionCalls, 1);
      await own.save(NotificationPreferenceKeys.studyReminders, false);
      expect(
        await service.requestPermissions(
          preferenceKey: NotificationPreferenceKeys.studyReminders,
        ),
        isFalse,
      );
      expect(native.ownedPermissionCalls, 1);
      await expectLater(
        service.showNotification(
          'Study',
          'Synthetic',
          preferenceKey: NotificationPreferenceKeys.studyReminders,
        ),
        throwsStateError,
      );
      expect(native.pending, isEmpty);
    },
  );

  test(
    'full local binding rejects missing tenant, substituted keys and numeric version coercion',
    () {
      final missing = {...scope(ga).toBinding()}..remove('tenant');
      missing['unknown'] = null;
      expect(
        () => LocalDatabaseIdentity.fromBinding(missing),
        throwsFormatException,
      );
      expect(
        () => LocalDatabaseIdentity.fromBinding({
          ...scope(ga).toBinding(),
          'v': 2.0,
        }),
        throwsFormatException,
      );
      expect(
        () => LocalDatabaseIdentity.bound(
          projectId: 'demo-life-os',
          databaseId: '(default)',
          uid: 'A/B',
          generation: ga,
        ),
        throwsArgumentError,
      );
    },
  );
  test(
    'legacy logout refuses bound generation before any destructive effect',
    () async {
      final db = AppDatabase.forUser(
        identity: scope(ga),
        executor: NativeDatabase.memory(),
      );
      addTearDown(db.close);
      final storage = FakeSecureStorage();
      storage.values[SecureStorageService.tokenKey] = 'legacy-session';
      final auth = LogoutAuth();
      final service = AuthLogoutService(
        database: db,
        secureStorage: storage,
        firebaseAuth: auth,
      );
      await expectLater(service.executeLogout(), throwsStateError);
      expect(auth.signOutCalls, 0);
      expect(storage.deletes, isEmpty);
      expect(storage.values[SecureStorageService.tokenKey], 'legacy-session');
      expect(
        (await db.customSelect('SELECT 1 AS intact').getSingle()).read<int>(
          'intact',
        ),
        1,
      );
    },
  );
}
