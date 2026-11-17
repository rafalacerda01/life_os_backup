import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:life_os/core/database/database_encryption.dart';
import 'package:life_os/core/database/local_database_identity.dart';

const control = MethodChannel('lifeos.gate02/control');
const proposed = FlutterSecureStorage(
  aOptions: AndroidOptions(
    encryptedSharedPreferences: true,
    resetOnError: false,
    migrateOnAlgorithmChange: false,
  ),
);
const old = FlutterSecureStorage(
  aOptions: AndroidOptions(encryptedSharedPreferences: true),
);
const syntheticKey = 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=';
final uidIdentity = LocalDatabaseIdentity('synthetic-gate02-uid-generation-7');
final values = <String, String>{
  'db_encryption_key': syntheticKey,
  uidIdentity.keyAlias: syntheticKey,
  'auth_access_token': 'SYNTHETIC-NOT-A-CREDENTIAL',
  'life_os_cycle_reminder_v1_synthetic': '{"enabled":true}',
  'life_os_cycle_action_token_v1_synthetic': 'SYNTHETIC-32-BYTES',
  'life_os_auth_cleanup_pending_v1': '{"synthetic":true}',
};
final report = <String, Object?>{};

void check(bool condition, String label) {
  (report['checks'] as Map<String, bool>)[label] = condition;
}

Future<Object?> snap() async {
  await Future<void>.delayed(const Duration(milliseconds: 350));
  return control.invokeMethod<Object?>('snapshot');
}

Future<void> seedDatabases() async {
  final dir = await getApplicationDocumentsDirectory();
  for (final name in ['life_os.sqlite', uidIdentity.fileName]) {
    final file = File('${dir.path}/$name');
    await DatabaseEncryptionBootstrap().prepare(
      databaseFile: file,
      keyProvider: ({required allowCreate}) async => syntheticKey,
    );
    final db = sqlite3.open(file.path);
    DatabaseEncryptionBootstrap.configureEncryptedConnection(db, syntheticKey);
    db.execute(
      'CREATE TABLE IF NOT EXISTS gate_fixture (id INTEGER PRIMARY KEY, payload TEXT)',
    );
    db.execute(
      "INSERT OR REPLACE INTO gate_fixture VALUES (1, 'SYNTHETIC-PRESERVE-GENERATION-7')",
    );
    db.dispose();
    check(
      !DatabaseEncryptionBootstrap.hasPlaintextHeader(file),
      'encrypted-$name',
    );
  }
  // Opaque synthetic auxiliaries: the storage guard must never edit these.
  for (final suffix in [
    '-wal',
    '-shm',
    '-journal',
    '.plaintext-backup',
    '.encryption-candidate',
  ]) {
    await File(
      '${dir.path}/life_os_fixture.sqlite$suffix',
    ).writeAsString('SYNTHETIC-AUXILIARY-$suffix');
  }
  await SharedPreferencesAsync().setBool(
    'life_os_onboarding_completed_v1',
    false,
  );
}

Future<void> verifyDatabases(FlutterSecureStorage storage) async {
  final dir = await getApplicationDocumentsDirectory();
  for (final entry in {
    'life_os.sqlite': 'db_encryption_key',
    uidIdentity.fileName: uidIdentity.keyAlias,
  }.entries) {
    try {
      final key = await storage.read(key: entry.value);
      check(key == syntheticKey, 'key-accessible-${entry.key}');
      if (key == null) continue;
      final db = sqlite3.open(
        '${dir.path}/${entry.key}',
        mode: OpenMode.readOnly,
      );
      try {
        DatabaseEncryptionBootstrap.configureEncryptedConnection(db, key);
        check(
          db.select('PRAGMA integrity_check').first.values.first == 'ok',
          'integrity-${entry.key}',
        );
        check(
          db.select('SELECT payload FROM gate_fixture').single.values.first ==
              'SYNTHETIC-PRESERVE-GENERATION-7',
          'content-${entry.key}',
        );
      } finally {
        db.dispose();
      }
    } catch (e) {
      report['db-error-${entry.key}'] = e.toString();
    }
  }
}
