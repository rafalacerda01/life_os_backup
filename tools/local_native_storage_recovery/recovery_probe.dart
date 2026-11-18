import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:drift/drift.dart' show InsertMode;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:life_os/core/database/database_encryption.dart';
import 'package:life_os/core/database/local_database_identity.dart';
import 'package:life_os/core/database/user_database_factory.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/database_sync_policy.dart';
import 'package:life_os/core/database/remote_send_permit.dart';
import 'package:life_os/core/database/local_device_session.dart';
import 'package:life_os/core/database/local_installation_identity_provider.dart';
import 'package:life_os/core/database/local_installation_identity_service.dart';
import 'package:life_os/core/database/local_profile_admission.dart';
import 'package:life_os/core/database/local_profile_bootstrap_journal.dart';
import 'package:life_os/core/db/user_db_key_manager.dart';
import 'fixture_support.dart' as fixture;

final bound = LocalDatabaseIdentity.bound(
  projectId: 'synthetic-project',
  databaseId: '(default)',
  tenantId: null,
  uid: 'synthetic-generation-owner',
  generation: '00000000-0000-4000-8000-000000000007',
);

Object? canonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((e) => e.toString()).toList()..sort();
    return {for (final key in keys) key: canonical(value[key])};
  }
  if (value is List) return value.map(canonical).toList();
  return value;
}

bool same(Object? a, Object? b) =>
    jsonEncode(canonical(a)) == jsonEncode(canonical(b));

Future<void> seedBound() async {
  // Actual P1 factory, crypto setup and schema, with a synthetic bound identity.
  final db = await UserDatabaseFactory().open(bound);
  fixture.check(
    (await db.customSelect('PRAGMA user_version').getSingle())
            .data
            .values
            .first ==
        11,
    'p1-bound-schema-11',
  );
  await db.closeDatabase();
  final dir = await getApplicationDocumentsDirectory();
  final raw = sqlite3.open(bound.fileIn(dir).path);
  try {
    DatabaseEncryptionBootstrap.configureEncryptedConnection(
      raw,
      fixture.syntheticKey,
    );
    raw.execute(
      'CREATE TABLE IF NOT EXISTS gate_fixture (id INTEGER PRIMARY KEY, payload TEXT)',
    );
    raw.execute(
      "INSERT OR REPLACE INTO gate_fixture VALUES (1, 'SYNTHETIC-BOUND-GENERATION-7')",
    );
  } finally {
    raw.dispose();
  }
}

Future<void> verifyAll() async {
  await fixture.verifyDatabases(fixture.proposed);
  final key = await fixture.old.read(key: bound.keyAlias);
  fixture.check(key == fixture.syntheticKey, 'bound-key-readable');
  if (key == null) return;
  final dir = await getApplicationDocumentsDirectory();
  final raw = sqlite3.open(bound.fileIn(dir).path, mode: OpenMode.readOnly);
  try {
    DatabaseEncryptionBootstrap.configureEncryptedConnection(raw, key);
    fixture.check(
      raw.select('PRAGMA integrity_check').single.values.first == 'ok',
      'bound-integrity',
    );
    fixture.check(
      raw.select('SELECT payload FROM gate_fixture').single.values.first ==
          'SYNTHETIC-BOUND-GENERATION-7',
      'bound-content',
    );
    fixture.check(
      !DatabaseEncryptionBootstrap.hasPlaintextHeader(bound.fileIn(dir)),
      'bound-encrypted',
    );
  } finally {
    raw.dispose();
  }
}

Future<bool> refuses(Future<Object?> Function() call) async {
  try {
    await call();
    return false;
  } on PlatformException catch (e) {
    return e.code.startsWith('LIFEOS_SECURE_STORAGE_');
  }
}

Future<bool> refusesLocalQueue(Future<Object?> Function() call) async {
  try {
    await call();
    return false;
  } catch (error) {
    return error.toString().contains(LocalRemoteSyncDisabled.code);
  }
}

Future<void> incrementUnderNativeAdmission(String path) async {
  final directory = Directory(path);
  for (var index = 0; index < 4; index++) {
    await LocalProfileAdmission(directory).run(() async {
      final counter = File('$path/counter.synthetic');
      final value = int.parse(await counter.readAsString());
      await Future<void>.delayed(const Duration(milliseconds: 8));
      await counter.writeAsString('${value + 1}', flush: true);
    });
  }
}

Future<void> runBootstrapScenario(String scenario) async {
  final out = fixture.report;
  final documents = await getApplicationDocumentsDirectory();
  if (scenario == 'admission-concurrent') {
    final path = documents.path;
    await File('$path/counter.synthetic').writeAsString('0');
    await Future.wait(
      List.generate(
        4,
        (_) => Isolate.run(() => incrementUnderNativeAdmission(path)),
      ),
    );
    fixture.check(
      await File('$path/counter.synthetic').readAsString() == '16',
      'native-four-isolates-no-lost-update',
    );
    fixture.check(
      await File('$path/${LocalProfileAdmission.fileName}').length() == 0,
      'native-admission-file-empty',
    );
    return;
  }
  if (scenario == 'admission-hold' || scenario == 'admission-after-kill') {
    await LocalProfileAdmission(documents).run(() async {
      fixture.check(
        LocalProfileAdmission.isCurrentFile(
          '${documents.path}/${LocalProfileAdmission.fileName}',
        ),
        'native-admission-acquired',
      );
      fixture.check(
        await File(
              '${documents.path}/${LocalProfileAdmission.fileName}',
            ).length() ==
            0,
        'native-admission-file-empty',
      );
      if (scenario == 'admission-hold') {
        out['after'] = await fixture.snap();
        await fixture.control.invokeMethod('save', jsonEncode(out));
        // Runner force-stops this disposable process while its lock is held.
        await Future<void>.delayed(const Duration(minutes: 2));
      }
    });
    return;
  }
  final container = ProviderContainer();
  try {
    final service = container.read(localInstallationIdentityServiceProvider);
    final identity = await service.resolve();
    out['profileId'] = identity.uid;
    final file = identity.fileIn(documents);
    final keys = UserDbKeyManager(storage: fixture.proposed);
    if (scenario == 'bootstrap-interrupted' ||
        scenario == 'bootstrap-with-content') {
      var interrupted = false;
      try {
        await LocalProfileAdmission(documents).run(
          () => LocalProfileBootstrapJournal(fixture.proposed).run<void>(
            identity: identity,
            databaseFile: file,
            schemaVersion: AppDatabase.currentSchemaVersion,
            open: (permit) async {
              final key = await DatabaseEncryptionBootstrap()
                  .prepareLocalProfile(
                    databaseFile: file,
                    expectedSchemaVersion: AppDatabase.currentSchemaVersion,
                    keyProvider: ({required allowCreate}) => keys
                        .getEncryptionKey(identity, allowCreate: allowCreate),
                    creationPermit: permit,
                  );
              if (scenario == 'bootstrap-with-content') {
                final raw = sqlite3.open(file.path);
                try {
                  DatabaseEncryptionBootstrap.configureEncryptedConnection(
                    raw,
                    key,
                  );
                  raw.execute('CREATE TABLE sentinel (payload TEXT)');
                  raw.execute(
                    "INSERT INTO sentinel VALUES ('SYNTHETIC-PRESERVE')",
                  );
                } finally {
                  raw.dispose();
                }
              }
              throw StateError('SYNTHETIC_BOOTSTRAP_INTERRUPTION');
            },
            closeOnFailure: (_) async {},
          ),
        );
      } on StateError catch (error) {
        interrupted = error.message == 'SYNTHETIC_BOOTSTRAP_INTERRUPTION';
      }
      fixture.check(interrupted, 'native-controlled-interruption');
      final record =
          jsonDecode(
                (await fixture.proposed.read(
                  key: LocalProfileBootstrapJournal.storageKey,
                ))!,
              )
              as Map;
      fixture.check(record['phase'] == 'CREATING', 'native-journal-creating');
      final key = await keys.getEncryptionKey(identity, allowCreate: false);
      out['keyFingerprint'] = sha256.convert(utf8.encode(key)).toString();
      final raw = sqlite3.open(file.path, mode: OpenMode.readOnly);
      try {
        DatabaseEncryptionBootstrap.configureEncryptedConnection(raw, key);
        fixture.check(
          raw.select('PRAGMA user_version').single.values.single == 0,
          'native-schema-zero',
        );
        fixture.check(
          raw.select('PRAGMA integrity_check').single.values.single == 'ok',
          'native-interrupted-integrity',
        );
      } finally {
        raw.dispose();
      }
      fixture.check(
        !DatabaseEncryptionBootstrap.hasPlaintextHeader(file),
        'native-interrupted-encrypted',
      );
      return;
    }
    if (scenario == 'bootstrap-content-refused') {
      final before = await file.readAsBytes();
      final journal = await fixture.proposed.read(
        key: LocalProfileBootstrapJournal.storageKey,
      );
      final key = await keys.getEncryptionKey(identity, allowCreate: false);
      out['keyFingerprint'] = sha256.convert(utf8.encode(key)).toString();
      var refused = false;
      try {
        final db = await UserDatabaseFactory(
          syncPolicy: DatabaseSyncPolicy.localOnly,
        ).open(identity);
        await db.closeDatabase();
      } on StateError catch (error) {
        refused = error.message == 'LOCAL_PROFILE_SCHEMA_MIGRATION_REQUIRED';
      }
      fixture.check(refused, 'native-content-refused');
      fixture.check(
        same(await file.readAsBytes(), before),
        'native-refusal-preserves-database',
      );
      fixture.check(
        await fixture.proposed.read(
              key: LocalProfileBootstrapJournal.storageKey,
            ) ==
            journal,
        'native-refusal-preserves-journal',
      );
      return;
    }
    if (scenario != 'bootstrap-recover')
      throw StateError('UNKNOWN_BOOTSTRAP_SCENARIO');
    final key = await keys.getEncryptionKey(identity, allowCreate: false);
    out['keyFingerprint'] = sha256.convert(utf8.encode(key)).toString();
    final session = LocalDeviceSession(identityService: service);
    try {
      final db = await session.open();
      final tasks = await db.select(db.taskTable).get();
      if (tasks.isEmpty) {
        await db
            .into(db.taskTable)
            .insert(
              TaskTableCompanion.insert(
                id: 'synthetic-bootstrap-task',
                title: 'SYNTHETIC-BOOTSTRAP-PRESERVE',
                priority: 'medium',
                date: DateTime.utc(2026, 11, 17),
              ),
            );
      }
      fixture.check(
        (await db.select(db.taskTable).get()).single.title ==
            'SYNTHETIC-BOOTSTRAP-PRESERVE',
        'native-recovered-content',
      );
      fixture.check(
        (await db.customSelect('PRAGMA integrity_check').getSingle())
                .data
                .values
                .single ==
            'ok',
        'native-recovered-integrity',
      );
      fixture.check(
        (await db.customSelect('PRAGMA user_version').getSingle())
                .data
                .values
                .single ==
            AppDatabase.currentSchemaVersion,
        'native-recovered-schema',
      );
      fixture.check(db.isLocalOnly, 'native-recovered-local-only');
      fixture.check(
        (await db.select(db.syncQueueTable).get()).isEmpty,
        'native-recovered-no-sync',
      );
      final record =
          jsonDecode(
                (await fixture.proposed.read(
                  key: LocalProfileBootstrapJournal.storageKey,
                ))!,
              )
              as Map;
      fixture.check(record['phase'] == 'READY', 'native-journal-ready');
      fixture.check(
        await keys.getEncryptionKey(identity, allowCreate: false) == key,
        'native-recovered-original-key',
      );
    } finally {
      await session.dispose();
    }
  } finally {
    container.dispose();
  }
}

Future<void> run(String scenario) async {
  final out = fixture.report;
  out['scenario'] = scenario;
  out['checks'] = <String, bool>{};
  out['processId'] = int.parse(
    (await File('/proc/self/stat').readAsString()).split(' ').first,
  );
  fixture.values[bound.keyAlias] = fixture.syntheticKey;
  out['before'] = await fixture.snap();
  if (scenario.startsWith('bootstrap-') || scenario.startsWith('admission-')) {
    await runBootstrapScenario(scenario);
  } else if (scenario == 'local-profile') {
    final container = ProviderContainer();
    final session = LocalDeviceSession(
      identityService: container.read(localInstallationIdentityServiceProvider),
    );
    try {
      final db = await session.open();
      out['profileId'] = session.currentLocalId;
      fixture.check(
        session.currentLocalId!.startsWith('local-v1-'),
        'permanent-local-identity',
      );
      fixture.check(
        db.identity!.uid == session.currentLocalId,
        'local-session-address',
      );
      final before = await db.select(db.taskTable).get();
      if (before.isEmpty) {
        await db.transactionWithSync(
          ownerUid: session.currentLocalId!,
          collection: 'tasks',
          docId: 'synthetic-local-task',
          operationType: 'create',
          payloadJson: '{"synthetic":true}',
          localOperation: () => db
              .into(db.taskTable)
              .insert(
                TaskTableCompanion.insert(
                  id: 'synthetic-local-task',
                  title: 'SYNTHETIC-LOCAL-PROFILE',
                  priority: 'normal',
                  date: DateTime.utc(2026, 11, 17),
                ),
                mode: InsertMode.insertOrReplace,
              ),
        );
      }
      fixture.check(db.isLocalOnly, 'local-only-connection');
      fixture.check(
        await refusesLocalQueue(
          () => db
              .into(db.syncQueueTable)
              .insert(
                SyncQueueTableCompanion.insert(
                  collection: 'tasks',
                  docId: 'forbidden',
                  operationType: 'create',
                  payloadJson: '{}',
                  createdAt: 123,
                ),
              ),
        ),
        'native-sqlite-blocks-direct-enqueue',
      );
      var remoteRefused = false;
      try {
        db.localMutations.captureRemoteSend(
          expectedUid: session.currentLocalId!,
        );
      } on RemoteSessionStopped {
        remoteRefused = true;
      }
      fixture.check(remoteRefused, 'native-local-session-has-no-remote-permit');
      final row = await db.select(db.taskTable).getSingle();
      fixture.check(
        row.title == 'SYNTHETIC-LOCAL-PROFILE',
        'local-core-task-persisted',
      );
      fixture.check(
        (await db.select(db.syncQueueTable).get()).isEmpty,
        'core-test-has-no-remote-queue',
      );
      fixture.check(
        (await db.customSelect('PRAGMA integrity_check').getSingle())
                .data
                .values
                .first ==
            'ok',
        'local-profile-integrity',
      );
    } finally {
      await session.dispose();
      container.dispose();
    }
  } else if (scenario == 'local-policy-historical') {
    final container = ProviderContainer();
    final service = container.read(localInstallationIdentityServiceProvider);
    final identity = await service.resolve();
    // Only synthetic fixture setup uses the remote-enabled connection to seed
    // a historical row. The app's LocalDeviceSession cannot grant this mode.
    final seed = await UserDatabaseFactory().open(identity);
    await seed
        .into(seed.taskTable)
        .insert(
          TaskTableCompanion.insert(
            id: 'retained-task',
            title: 'SYNTHETIC-RETAIN',
            priority: 'normal',
            date: DateTime.utc(2026, 11, 17),
          ),
        );
    await seed.insertSyncItem(
      ownerUid: identity.uid,
      collection: 'tasks',
      docId: 'retained-task',
      operationType: 'create',
      payloadJson: '{"retained":true}',
      createdAt: 123,
    );
    final original = (await seed.select(seed.syncQueueTable).get()).single;
    await seed.closeDatabase();
    final session = LocalDeviceSession(identityService: service);
    try {
      final db = await session.open();
      fixture.check(db.isLocalOnly, 'historical-open-is-local-only');
      fixture.check(
        await refusesLocalQueue(
          () => db.customStatement(
            "UPDATE sync_queue_table SET payload_json='changed'",
          ),
        ),
        'historical-update-refused',
      );
      fixture.check(
        await refusesLocalQueue(() => db.delete(db.syncQueueTable).go()),
        'historical-delete-refused',
      );
      fixture.check(
        await refusesLocalQueue(db.clearAllData),
        'historical-bulk-cleanup-refused',
      );
      fixture.check(
        (await db.select(db.syncQueueTable).get()).single == original,
        'historical-row-unchanged',
      );
      fixture.check(
        (await db.select(db.taskTable).get()).single.title ==
            'SYNTHETIC-RETAIN',
        'historical-failed-cleanup-is-atomic',
      );
    } finally {
      await session.dispose();
      container.dispose();
    }
  } else if (scenario == 'secondary-guard') {
    final support = await getApplicationSupportDirectory();
    final artifact = File(
      '${support.path}/life_os_native_ownership_v1.sqlite-wal',
    );
    await artifact.writeAsString('SYNTHETIC-SECONDARY-PRESERVE');
    final container = ProviderContainer();
    var blocked = false;
    try {
      await container.read(localInstallationIdentityServiceProvider).resolve();
    } on StateError catch (e) {
      blocked = e.toString().contains('LOCAL_PROFILE_MIGRATION_REQUIRED');
    } finally {
      container.dispose();
    }
    fixture.check(blocked, 'secondary-store-blocks-adoption');
    fixture.check(
      await artifact.readAsString() == 'SYNTHETIC-SECONDARY-PRESERVE',
      'secondary-bytes-unchanged',
    );
    fixture.check(
      await fixture.proposed.read(
            key: LocalInstallationIdentityService.storageKey,
          ) ==
          null,
      'secondary-no-marker-created',
    );
    await artifact.delete(); // Only the synthetic file just created above.
  } else if (scenario.startsWith('seed-')) {
    if (scenario == 'seed-esp') {
      await fixture.control.invokeMethod('seedEsp', fixture.values);
    } else if (scenario == 'seed-cbc') {
      await fixture.control.invokeMethod('seedLegacyCustom', fixture.values);
    } else {
      for (final e in fixture.values.entries) {
        await fixture.old.write(key: e.key, value: e.value);
      }
    }
    await fixture.seedDatabases();
    await seedBound();
    if (scenario == 'seed-cbc')
      await fixture.control.invokeMethod('removeAlgorithmMarkers');
    await verifyAll();
  } else if (scenario == 'fresh-read') {
    fixture.check(
      await fixture.old.read(key: 'absent') == null,
      'old-read-null',
    );
    fixture.check(
      (await fixture.proposed.readAll()).isEmpty,
      'proposed-readAll-empty',
    );
    fixture.check(
      !await fixture.old.containsKey(key: 'absent'),
      'contains-absent',
    );
    fixture.check(
      same(out['before'], await fixture.snap()),
      'fresh-read-creates-no-files-or-aliases',
    );
  } else if (scenario == 'biometric-refused') {
    const storage = FlutterSecureStorage(
      aOptions: AndroidOptions.biometric(enforceBiometrics: true),
    );
    fixture.check(
      await refuses(() => storage.read(key: 'absent')),
      'biometric-not-silently-downgraded',
    );
    fixture.check(
      same(out['before'], await fixture.snap()),
      'biometric-refusal-preserves-store',
    );
  } else if (scenario == 'healthy') {
    final results = await Future.wait<Object?>([
      fixture.old.read(key: 'db_encryption_key'),
      fixture.proposed.readAll(),
      fixture.proposed.read(key: bound.keyAlias),
      fixture.old.readAll(),
    ]);
    fixture.check(results[0] == fixture.syntheticKey, 'old-read-decrypted');
    fixture.check(
      results[2] == fixture.syntheticKey,
      'proposed-read-decrypted',
    );
    fixture.check(
      same(results[1], fixture.values),
      'proposed-readAll-decrypted',
    );
    fixture.check(same(results[3], fixture.values), 'old-readAll-decrypted');
    await verifyAll();
    fixture.check(
      same(out['before'], await fixture.snap()),
      'reads-preserve-files-and-aliases',
    );
  } else if (scenario == 'corrupt-readAll') {
    await fixture.old.read(key: 'db_encryption_key'); // unsafe defaults first
    await fixture.control.invokeMethod('corruptCustom');
    final damaged = await fixture.snap();
    out['after-injected-failure'] = damaged;
    fixture.check(
      await refuses(() => fixture.old.readAll()),
      'old-readAll-refuses-corruption',
    );
    fixture.check(
      await refuses(() => fixture.proposed.readAll()),
      'proposed-readAll-refuses-corruption',
    );
    fixture.check(
      same(damaged, await fixture.snap()),
      'corrupt-readAll-never-resets',
    );
    fixture.check(
      await fixture.old.read(key: bound.keyAlias) == fixture.syntheticKey,
      'healthy-key-survives',
    );
    await fixture.control.invokeMethod('restoreCustom');
    await verifyAll();
    fixture.check(
      same(out['before'], await fixture.snap()),
      'restoration-recovers-exact-fixture',
    );
  } else if (scenario == 'missing-wrapped-key') {
    await fixture.control.invokeMethod('removeWrapped');
    final damaged = await fixture.snap();
    out['after-injected-failure'] = damaged;
    fixture.check(
      await refuses(() => fixture.old.read(key: 'db_encryption_key')),
      'missing-wrap-refuses',
    );
    fixture.check(
      same(damaged, await fixture.snap()),
      'missing-wrap-does-not-recreate',
    );
    await fixture.control.invokeMethod('restoreWrapped');
    await verifyAll();
  } else if (scenario == 'missing-esp-master') {
    await fixture.control.invokeMethod('removeMaster');
    final damaged = await fixture.snap();
    out['after-injected-failure'] = damaged;
    fixture.check(
      await refuses(() => fixture.old.readAll()),
      'missing-master-refuses',
    );
    fixture.check(
      same(damaged, await fixture.snap()),
      'missing-master-is-not-recreated',
    );
  } else if (scenario == 'explicit-writes') {
    fixture.check(
      await refuses(() => fixture.old.deleteAll()),
      'bulk-delete-disabled',
    );
    fixture.check(
      same(out['before'], await fixture.snap()),
      'bulk-delete-preserves-store',
    );
    await fixture.proposed.delete(key: 'auth_access_token');
    fixture.check(
      await fixture.old.read(key: 'auth_access_token') == null,
      'selected-delete-only',
    );
    await verifyAll();
    await fixture.proposed.write(
      key: 'auth_access_token',
      value: fixture.values['auth_access_token'],
    );
    fixture.check(
      same(await fixture.old.readAll(), fixture.values),
      'write-keeps-logical-values',
    );
    final after = await fixture.snap() as Map;
    final before = out['before'] as Map;
    fixture.check(
      same(before['aliases'], after['aliases']),
      'write-keeps-keystore-aliases',
    );
    final a = Map.of(before['files'] as Map)
      ..remove('shared_prefs/FlutterSecureStorage.xml');
    final b = Map.of(after['files'] as Map)
      ..remove('shared_prefs/FlutterSecureStorage.xml');
    fixture.check(same(a, b), 'write-keeps-wrapped-keys-config-and-db');
  } else {
    throw StateError('UNKNOWN_SCENARIO');
  }
  out['after'] = await fixture.snap();
  out['binding'] = bound.toBinding();
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      home: Scaffold(body: Text('Synthetic storage recovery gate')),
    ),
  );
  final scenario =
      await fixture.control.invokeMethod<String>('scenario') ?? 'fresh-read';
  try {
    await run(scenario).timeout(const Duration(seconds: 90));
  } catch (e, st) {
    fixture.report['fatal'] = e.toString();
    fixture.report['stack'] = st.toString();
  }
  await fixture.control.invokeMethod('save', jsonEncode(fixture.report));
}
