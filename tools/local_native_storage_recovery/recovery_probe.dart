import 'dart:convert';
import 'dart:io';
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
import 'package:life_os/core/database/local_device_session.dart';
import 'package:life_os/core/database/local_installation_identity_provider.dart';
import 'package:life_os/core/database/local_installation_identity_service.dart';
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

Future<void> run(String scenario) async {
  final out = fixture.report;
  out['scenario'] = scenario;
  out['checks'] = <String, bool>{};
  fixture.values[bound.keyAlias] = fixture.syntheticKey;
  out['before'] = await fixture.snap();
  if (scenario == 'local-profile') {
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
        await db
            .into(db.taskTable)
            .insert(
              TaskTableCompanion.insert(
                id: 'synthetic-local-task',
                title: 'SYNTHETIC-LOCAL-PROFILE',
                priority: 'normal',
                date: DateTime.utc(2026, 11, 17),
              ),
              mode: InsertMode.insertOrReplace,
            );
      }
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
