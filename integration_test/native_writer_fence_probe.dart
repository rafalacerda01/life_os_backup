import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/database_encryption.dart';
import 'package:life_os/core/database/database_sync_policy.dart';
import 'package:life_os/core/database/local_database_identity.dart';
import 'package:life_os/core/database/user_database_factory.dart';
import 'package:life_os/core/db/user_db_key_manager.dart';
import 'package:life_os/core/services/native_notification_registry.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

const _channel = MethodChannel('lifeos.fence21');
const _taskId = 'SYNTHETIC-FENCE21';
const _updatedTask = 'SYNTHETIC-WAL-ONLY';
final _openWriters = <Database>[];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      home: Scaffold(body: Text('Synthetic native writer admission')),
    ),
  );
  final admission = await _channel.invokeMapMethod<String, Object?>(
    'admission',
  );
  if (admission == null) throw StateError('NATIVE_ADMISSION_REQUIRED');
  final report = <String, Object?>{...admission};
  try {
    final kind = admission['kind']! as String;
    final uid = admission['uid']! as String;
    final identity = kind == 'p1'
        ? LocalDatabaseIdentity.bound(
            uid: uid,
            projectId: 'fence21-project',
            databaseId: '(default)',
            tenantId: 'fence21-tenant',
            generation: '00000000-0000-4000-8000-000000000021',
          )
        : LocalDatabaseIdentity(uid);
    if (identity.namespace != admission['namespace'])
      throw StateError('NATIVE_NAMESPACE_MISMATCH');

    final docs = await getApplicationDocumentsDirectory();
    final files = await getApplicationSupportDirectory();
    final source = identity.fileIn(docs);
    final keys = UserDbKeyManager(
      storage: const FlutterSecureStorage(
        aOptions: AndroidOptions(
          encryptedSharedPreferences: true,
          resetOnError: false,
          migrateOnAlgorithmChange: false,
        ),
      ),
    );
    final local = identity.isLocalInstallation;
    final seeded = admission['seed'] == true;
    if (seeded) {
      for (final suffix in [
        '',
        '-wal',
        '-shm',
        '-journal',
        '.encryption-candidate',
        '.plaintext-backup',
      ]) {
        if (await File('${source.path}$suffix').exists())
          throw StateError('FRESH_FIXTURE_REQUIRED');
      }
      await _seed(
        identity,
        keys,
        local,
        source,
        files,
        admission['stamp']! as String,
      );
    }
    final key = await keys.getEncryptionKey(identity, allowCreate: false);
    await _verifyOnCopies(source, key, local);
    report['source'] = source.path.split('/').last;
    report['keyFingerprint'] = sha256.convert(utf8.encode(key)).toString();
    report['ok'] = true;
  } on StateError catch (error) {
    report['error'] = error.message;
  } on SqliteException catch (error) {
    report['error'] = 'SQLITE_${error.extendedResultCode}';
  } catch (error) {
    report['error'] = error.runtimeType.toString();
  }
  await _channel.invokeMethod<void>('report', jsonEncode(report));
}

Future<void> _seed(
  LocalDatabaseIdentity identity,
  UserDbKeyManager keys,
  bool local,
  File source,
  Directory files,
  String stamp,
) async {
  final database = await UserDatabaseFactory(
    keyManager: keys,
    syncPolicy: local
        ? DatabaseSyncPolicy.localOnly
        : DatabaseSyncPolicy.remoteEnabled,
  ).open(identity);
  try {
    await database
        .into(database.taskTable)
        .insert(
          TaskTableCompanion.insert(
            id: _taskId,
            title: _taskId,
            priority: 'medium',
            date: DateTime.utc(2026, 11, 20),
          ),
        );
  } finally {
    await database.closeDatabase();
  }
  final key = await keys.getEncryptionKey(identity, allowCreate: false);
  final writer = sqlite3.open(source.path, mode: OpenMode.readWrite);
  _openWriters.add(writer);
  DatabaseEncryptionBootstrap.configureEncryptedConnection(writer, key);
  if (writer.select('PRAGMA journal_mode=WAL').single.values.single != 'wal')
    throw StateError('WAL_NOT_QUALIFIED');
  writer.execute('PRAGMA wal_autocheckpoint=0');
  writer.execute('PRAGMA synchronous=FULL');
  if (writer.select('PRAGMA wal_checkpoint(TRUNCATE)').single.values.first != 0)
    throw StateError('WAL_CHECKPOINT_BUSY');
  writer.execute('UPDATE task_table SET title=? WHERE id=?', [
    _updatedTask,
    _taskId,
  ]);
  await File(
    '${source.path}.plaintext-backup-journal',
  ).writeAsString('SYNTHETIC-RECOVERY-JOURNAL-21', flush: true);
  final registryName = local
      ? NativeNotificationRegistry.installationFileName
      : 'life_os_native_ownership_v1.sqlite';
  final sql = sqlite3.open('${files.path}/$registryName');
  try {
    NativeNotificationRegistry(sql, installationOnly: local);
    sql.execute(
      'INSERT INTO native_notification_owners VALUES (?, ?, ?, ?, ?, ?)',
      [
        21001,
        1,
        identity.namespace,
        sha256.convert(utf8.encode(stamp)).toString(),
        'fence21',
        'ACTIVE',
      ],
    );
  } finally {
    sql.dispose();
  }
  final native = FlutterLocalNotificationsPlugin();
  await native.initialize(
    settings: const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ),
  );
  tz_data.initializeTimeZones();
  await native.zonedSchedule(
    id: 21001,
    scheduledDate: tz.TZDateTime.now(tz.UTC).add(const Duration(hours: 2)),
    notificationDetails: const NotificationDetails(
      android: AndroidNotificationDetails(
        'fence21',
        'Fence 21',
        tag: 'fence21',
      ),
    ),
    androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
    title: 'SYNTHETIC-FENCE21-NOTIFICATION',
    body: 'Synthetic notification fixture',
    payload: stamp,
  );
}

Future<void> _verifyOnCopies(File source, String key, bool local) async {
  if (DatabaseEncryptionBootstrap.hasPlaintextHeader(source))
    throw StateError('PLAINTEXT_SOURCE');
  final temp = await getTemporaryDirectory();
  for (final includeWal in [false, true]) {
    final folder = await temp.createTemp('fence21-query-');
    final copy = await source.copy('${folder.path}/query.sqlite');
    if (includeWal) await File('${source.path}-wal').copy('${copy.path}-wal');
    final reader = sqlite3.open(copy.path, mode: OpenMode.readWrite);
    try {
      DatabaseEncryptionBootstrap.configureEncryptedConnection(reader, key);
      reader.execute('PRAGMA query_only=ON');
      final schema = local
          ? AppDatabase.currentLocalSchemaVersion
          : AppDatabase.currentSchemaVersion;
      if (reader.select('PRAGMA user_version').single.values.single != schema ||
          reader.select('PRAGMA integrity_check').single.values.single !=
              'ok' ||
          reader
                  .select('SELECT title FROM task_table WHERE id=?', [_taskId])
                  .single
                  .values
                  .single !=
              (includeWal ? _updatedTask : _taskId)) {
        throw StateError('FIXTURE_INTEGRITY_FAILED');
      }
    } finally {
      reader.dispose();
    }
  }
}
