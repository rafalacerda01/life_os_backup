import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:life_os/core/database/local_database_identity.dart';
import 'package:life_os/core/database/user_database_storage_destroyer.dart';
import 'package:life_os/core/db/user_db_key_manager.dart';
import 'package:life_os/core/storage/ai_consent_local_cache.dart';
import 'package:life_os/features/auth/data/local/account_deletion_cleanup_barrier.dart';
import 'package:life_os/features/auth/data/local/account_deletion_storage_cleanup.dart';
import 'package:life_os/features/auth/data/local/auth_cleanup_barrier.dart';
import 'package:life_os/features/health/presentation/cycle/cycle_reminder_preferences.dart';
import 'package:life_os/features/health/services/cycle_reminder_action_security.dart';

import '../../../../core/db/fake_secure_storage.dart';

class _FailedRemovalPreferences extends Fake implements SharedPreferences {
  bool persisted = true;
  bool cached = true;
  bool failRemoval = true;

  @override
  bool containsKey(String key) => cached;
  @override
  Future<void> reload() async => cached = persisted;
  @override
  Future<bool> remove(String key) async {
    cached = false;
    if (failRemoval) return false;
    persisted = false;
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final a = LocalDatabaseIdentity('A');
  final b = LocalDatabaseIdentity('B');
  late Directory directory;
  late FakeSecureStorage storage;
  late UserDbKeyManager keys;
  late CycleReminderActionTokenStore tokens;
  late CycleReminderPreferencesStore preferences;
  late SharedPreferences device;
  late AiConsentLocalCache ai;
  late AccountDeletionCleanupBarrier barrier;
  late AccountDeletionStorageCleanup cleanup;
  late PendingAccountDeletion confirmed;
  final config = CycleReminderPreferences(
    enabled: true,
    type: CycleReminderType.pill,
    hour: 16,
    minute: 35,
    frequency: CycleReminderFrequency.daily,
  );

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('account_stores_');
    storage = FakeSecureStorage();
    keys = UserDbKeyManager(storage: storage);
    for (final identity in [a, b]) {
      await keys.getEncryptionKey(identity, allowCreate: true);
      identity.fileIn(directory).writeAsStringSync(identity.uid);
    }
    tokens = CycleReminderActionTokenStore(
      SecureCycleReminderActionTokenStorage(storage),
    );
    preferences = CycleReminderPreferencesStore(
      SecureCycleReminderPreferencesStorage(storage),
    );
    for (final uid in ['A', 'B']) {
      await tokens.getOrCreate(uid);
      await preferences.save(uid, config);
    }
    SharedPreferences.setMockInitialValues({
      'ai_consent_accepted_A': true,
      'ai_consent_accepted_B': true,
      'all_notifications': true,
      'study_reminders': true,
      'habit_reminders': true,
      'medication_reminders': true,
      'analytics_enabled': true,
      'biometrics_enabled': true,
      'life_os_onboarding_completed_v1': true,
    });
    device = await SharedPreferences.getInstance();
    ai = AiConsentLocalCache(preferencesLoader: () async => device);
    barrier = AccountDeletionCleanupBarrier(
      SecureAuthCleanupBarrierStorage(storage),
    );
    confirmed = await barrier.confirmIfCurrent(await barrier.request('A'));
    cleanup = AccountDeletionStorageCleanup(
      destroyer: UserDatabaseStorageDestroyer(
        directoryProvider: () async => directory,
        keyManager: keys,
      ),
      deletePreferences: preferences.delete,
      deleteActionToken: tokens.delete,
      deleteAiCache: ai.deleteForAccount,
    );
  });
  tearDown(() => directory.deleteSync(recursive: true));

  Future<void> finish() async {
    expect(
      (await barrier.readForUser(a.uid))?.phase,
      AccountDeletionPhase.remoteConfirmed,
    );
    await cleanup.destroy(a);
    expect(await barrier.clearIfCurrent(confirmed), isTrue);
  }

  test(
    'files then key then stores deletes A only and preserves device settings',
    () async {
      final keyB = storage.values[b.keyAlias];
      final tokenB = await tokens.load('B');
      cleanup = AccountDeletionStorageCleanup(
        destroyer: cleanup.destroyer,
        deletePreferences: (uid) async {
          expect(a.fileIn(directory).existsSync(), isFalse);
          expect(storage.values.containsKey(a.keyAlias), isFalse);
          await preferences.delete(uid);
        },
        deleteActionToken: tokens.delete,
        deleteAiCache: ai.deleteForAccount,
      );
      await finish();
      expect(await preferences.load('A'), isNull);
      expect(await tokens.load('A'), isNull);
      expect(device.containsKey('ai_consent_accepted_A'), isFalse);
      expect(await preferences.load('B'), isNotNull);
      expect(await tokens.load('B'), tokenB);
      expect(storage.values[b.keyAlias], keyB);
      expect(b.fileIn(directory).readAsStringSync(), 'B');
      for (final key in [
        'ai_consent_accepted_B',
        'all_notifications',
        'study_reminders',
        'habit_reminders',
        'medication_reminders',
        'analytics_enabled',
        'biometrics_enabled',
        'life_os_onboarding_completed_v1',
      ]) {
        expect(device.getBool(key), isTrue);
      }
      await cleanup.destroy(a);
      expect(a.fileIn(directory).existsSync(), isFalse);
      expect(storage.writes[a.keyAlias], 1);
    },
  );

  test(
    'key failure retains marker; retry never creates database or key',
    () async {
      storage.discardDeletes = true;
      await expectLater(finish(), throwsStateError);
      expect(await barrier.readForUser(a.uid), confirmed);
      expect(a.fileIn(directory).existsSync(), isFalse);
      expect(storage.values.containsKey(a.keyAlias), isTrue);
      storage.discardDeletes = false;
      await finish();
      expect(await barrier.readAll(), isEmpty);
      expect(storage.writes[a.keyAlias], 1);
    },
  );

  test('crash after files before key resumes without opening A', () async {
    for (final file in UserDatabaseStorageDestroyer.artifacts(a, directory)) {
      if (file.existsSync()) file.deleteSync();
    }
    expect(storage.values.containsKey(a.keyAlias), isTrue);
    await finish();
    expect(storage.values.containsKey(a.keyAlias), isFalse);
    expect(storage.writes[a.keyAlias], 1);
  });

  test(
    'crash after key before preferences retries stores without key recreation',
    () async {
      await cleanup.destroyer.destroy(a);
      expect(await barrier.readForUser(a.uid), confirmed);
      expect(await preferences.load('A'), isNotNull);
      await finish();
      expect(await preferences.load('A'), isNull);
      expect(storage.writes[a.keyAlias], 1);
    },
  );

  test(
    'AI cache removal failure retains marker and retry keeps token sealed',
    () async {
      var fail = true;
      final realCleanup = cleanup;
      cleanup = AccountDeletionStorageCleanup(
        destroyer: realCleanup.destroyer,
        deletePreferences: preferences.delete,
        deleteActionToken: tokens.delete,
        deleteAiCache: (uid) async {
          if (fail) throw StateError('fixture');
          await ai.deleteForAccount(uid);
        },
      );
      await expectLater(finish(), throwsStateError);
      expect(await barrier.readForUser(a.uid), confirmed);
      expect(await tokens.load('A'), isNull);
      expect(storage.values.containsKey(a.keyAlias), isFalse);
      fail = false;
      await finish();
      await expectLater(tokens.getOrCreate('A'), throwsStateError);
    },
  );

  test('crash after everything before marker clear is idempotent', () async {
    await cleanup.destroy(a);
    expect(await barrier.readForUser(a.uid), confirmed);
    final writes = Map<String, int>.of(storage.writes);
    await finish();
    expect(storage.writes, writes);
    expect(await barrier.readAll(), isEmpty);
  });

  test(
    'failed AI disk removal cannot be mistaken for an empty memory cache',
    () async {
      final failedPreferences = _FailedRemovalPreferences();
      final failedCache = AiConsentLocalCache(
        preferencesLoader: () async => failedPreferences,
      );
      cleanup = AccountDeletionStorageCleanup(
        destroyer: cleanup.destroyer,
        deletePreferences: preferences.delete,
        deleteActionToken: tokens.delete,
        deleteAiCache: failedCache.deleteForAccount,
      );
      await expectLater(finish(), throwsStateError);
      expect(failedPreferences.cached, isFalse);
      expect(failedPreferences.persisted, isTrue);
      expect(await barrier.readForUser(a.uid), confirmed);
      failedPreferences.failRemoval = false;
      await finish();
      expect(failedPreferences.persisted, isFalse);
      expect(await barrier.readAll(), isEmpty);
    },
  );

  test(
    'unconfirmed preference removal retains marker until verified retry',
    () async {
      await cleanup.destroyer.destroy(a);
      storage.discardDeletes = true;
      await expectLater(finish(), throwsStateError);
      expect(await barrier.readForUser(a.uid), confirmed);
      expect(await preferences.load('A'), isNotNull);
      expect(await tokens.load('A'), isNotNull);
      storage.discardDeletes = false;
      await finish();
      expect(await preferences.load('A'), isNull);
      expect(await barrier.readAll(), isEmpty);
    },
  );

  test(
    'AI delete waits for old cache write and denies late recreation',
    () async {
      final started = Completer<void>();
      final release = Completer<void>();
      var reads = 0;
      ai = AiConsentLocalCache(
        preferencesLoader: () async {
          if (reads++ == 0) {
            started.complete();
            await release.future;
          }
          return device;
        },
      );
      final oldWrite = ai.write('A');
      await started.future;
      final deletion = ai.deleteForAccount('A');
      release.complete();
      await oldWrite;
      await deletion;
      expect(await ai.write('A'), isFalse);
      expect(device.containsKey('ai_consent_accepted_A'), isFalse);
      expect(device.getBool('ai_consent_accepted_B'), isTrue);
    },
  );
}
