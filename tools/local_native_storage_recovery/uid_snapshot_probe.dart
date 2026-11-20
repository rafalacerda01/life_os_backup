import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/database_encryption.dart';
import 'package:life_os/core/database/local_database_identity.dart';
import 'package:life_os/core/database/user_database_factory.dart';
import 'package:life_os/core/db/user_db_key_manager.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import 'fixture_support.dart' as fixture;
import 'recovery_probe.dart' show bound, same;

const _task = 'SYNTHETIC-UID-SNAPSHOT-TASK';
const _intent = 'SYNTHETIC-WAL-ONLY';
const _payload = '{"synthetic":true}';
const _sidecars = ['', '-wal', '-shm', '-journal'];
const _migrationFiles = ['.plaintext-backup', '.encryption-candidate'];
final _draft = LocalDatabaseIdentity(bound.uid, generation: bound.generation);
final _sources = {'uid': fixture.uidIdentity, 'bound': bound};

// Kept open in the seed process so SQLite cannot checkpoint on the last close.
// The disposable package is stopped abruptly by the executor after the report.
final List<Database> _writers = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(home: Scaffold(body: Text('Synthetic UID snapshot'))),
  );
  final scenario = await fixture.control.invokeMethod<String>('scenario');
  final report = fixture.report;
  report.addAll({
    'module': 'uid-snapshot',
    'scenario': scenario,
    'checks': <String, bool>{},
    'processId': pid,
  });
  try {
    await _run(scenario).timeout(const Duration(seconds: 90));
  } on StateError catch (error) {
    // All errors thrown by the proof have fixed labels, never SQL or keys.
    report['fatal'] = error.message;
  } catch (error) {
    report['fatal'] = error.runtimeType.toString();
  }
  await fixture.control.invokeMethod('save', jsonEncode(report));
}

void _check(bool value, String label) {
  fixture.check(value, label);
  if (!value) throw StateError(label);
}

Future<void> _run(String? scenario) async {
  _check(scenario == 'seed' || scenario == 'verify', 'known-scenario');
  final source = await getApplicationDocumentsDirectory();
  final cache = await getTemporaryDirectory();
  final keyManager = UserDbKeyManager(storage: fixture.proposed);
  final absentIdentity = LocalDatabaseIdentity('synthetic-key-must-not-exist');
  if (scenario == 'seed') {
    final blank = await _sourceNames(source);
    _check(blank.isEmpty, 'empty-synthetic-sources');
    for (final entry in _sources.entries) {
      await _seed(source, entry.value, keyManager);
    }
  }

  final before = await fixture.snap();
  final keys = <String, String>{};
  final evidence = <String, Object?>{};
  for (final entry in _sources.entries) {
    final identity = entry.value;
    keys[entry.key] = await keyManager.getEncryptionKey(
      identity,
      allowCreate: false,
    );
  }
  _check(keys['uid'] != keys['bound'], 'separate-native-keys');
  _check(
    await _refuses(
      () => keyManager.getEncryptionKey(absentIdentity, allowCreate: false),
      'USER_DATABASE_KEY_UNAVAILABLE',
    ),
    'absent-key-refused-without-creation',
  );
  _check(
    await _refuses(
      () => _sourceSnapshot(source, _draft),
      'UID_SNAPSHOT_DRAFT_REFUSED',
    ),
    'draft-generation-refused',
  );

  for (final entry in _sources.entries) {
    final label = entry.key;
    final identity = entry.value;
    final key = keys[label]!;
    final archive = await cache.createTemp('uid-sealed-$label-');
    final hashes = await _seal(source, identity, archive);
    _check(
      hashes.keys.toSet().containsAll(['', '-wal', '-shm']),
      '$label-real-wal-and-shm',
    );
    final mainOnly = await _copyForQuery(
      archive,
      identity,
      cache,
      includeWal: false,
    );
    final captured = await _copyForQuery(
      archive,
      identity,
      cache,
      includeWal: true,
    );
    final absent = _read(mainOnly, key, identity);
    _check(absent.queueRows == 0, '$label-intent-absent-from-main-file');
    final recovered = _read(captured, key, identity);
    _check(
      recovered.schema == AppDatabase.currentSchemaVersion &&
          recovered.schema == 11,
      '$label-current-legacy-schema-11',
    );
    _check(
      recovered.integrity == 'ok' &&
          !DatabaseEncryptionBootstrap.hasPlaintextHeader(captured),
      '$label-encrypted-integrity',
    );
    _check(recovered.taskId == _task, '$label-historical-task-preserved');
    _check(
      recovered.queueRows == 1 && recovered.exactIntent,
      '$label-intent-recovered-from-real-wal',
    );
    final wrongKeySource = await _copyForQuery(
      archive,
      identity,
      cache,
      includeWal: true,
    );
    final wrongKey = keys[label == 'uid' ? 'bound' : 'uid']!;
    var wrongKeyRefused = false;
    try {
      _read(wrongKeySource, wrongKey, identity);
    } on SqliteException {
      wrongKeyRefused = true;
    }
    _check(wrongKeyRefused, '$label-other-native-key-refused');
    _check(
      same(hashes, await _sourceSnapshot(archive, identity)),
      '$label-archive-untouched-by-sqlite',
    );
    _check(
      same(hashes, await _sourceSnapshot(source, identity)),
      '$label-source-family-unchanged',
    );
    evidence[label] = {
      'namespace': identity.namespace,
      'schema': recovered.schema,
      'hashes': hashes,
      'keyFingerprint': sha256.convert(utf8.encode(key)).toString(),
    };
  }

  if (scenario == 'verify') {
    await _negativeCopies(source, cache, keyManager);
  }

  _check(
    same(before, await fixture.snap()),
    'native-store-aliases-and-source-files-unchanged',
  );
  fixture.report['sources'] = evidence;
}

Future<List<FileSystemEntity>> _sourceNames(Directory source) async => [
  await for (final entity in source.list(followLinks: false))
    if (_sources.values.any(
      (identity) => entity.path.split('/').last.startsWith(identity.fileName),
    ))
      entity,
];

Future<void> _seed(
  Directory source,
  LocalDatabaseIdentity identity,
  UserDbKeyManager keyManager,
) async {
  final database = await UserDatabaseFactory(
    keyManager: keyManager,
  ).open(identity);
  try {
    await database
        .into(database.taskTable)
        .insert(
          TaskTableCompanion.insert(
            id: _task,
            title: _task,
            priority: 'medium',
            date: DateTime.utc(2026, 11, 20),
          ),
        );
  } finally {
    await database.closeDatabase();
  }
  final key = await keyManager.getEncryptionKey(identity, allowCreate: false);
  final writer = sqlite3.open(
    identity.fileIn(source).path,
    mode: OpenMode.readWrite,
  );
  _writers.add(writer);
  DatabaseEncryptionBootstrap.configureEncryptedConnection(writer, key);
  final mode = writer.select('PRAGMA journal_mode=WAL').single.values.single;
  _check(mode == 'wal', 'seed-real-wal-${identity.isBound ? 'bound' : 'uid'}');
  writer.execute('PRAGMA wal_autocheckpoint=0');
  writer.execute('PRAGMA synchronous=FULL');
  final checkpoint = writer.select('PRAGMA wal_checkpoint(TRUNCATE)').single;
  _check(
    checkpoint.values.first == 0,
    'seed-checkpoint-${identity.isBound ? 'bound' : 'uid'}',
  );
  writer.execute('BEGIN IMMEDIATE');
  writer.execute(
    'INSERT INTO sync_queue_table (owner_uid, collection, doc_id, operation_type, payload_json, created_at) '
    'VALUES (?, ?, ?, ?, ?, ?)',
    [identity.uid, 'tasks', _intent, 'create', _payload, 123],
  );
  writer.execute('COMMIT');
}

Future<Map<String, String>> _sourceSnapshot(
  Directory location,
  LocalDatabaseIdentity identity,
) async {
  if (identity.generation != null && !identity.isBound)
    throw StateError('UID_SNAPSHOT_DRAFT_REFUSED');
  if (identity.isLocalInstallation)
    throw StateError('UID_SNAPSHOT_LOCAL_SOURCE_REFUSED');
  final path = identity.fileIn(location).path;
  for (final migration in _migrationFiles) {
    for (final suffix in _sidecars) {
      if (await FileSystemEntity.type(
            '$path$migration$suffix',
            followLinks: false,
          ) !=
          FileSystemEntityType.notFound) {
        throw StateError('UID_SNAPSHOT_MIGRATION_ARTIFACT_PRESENT');
      }
    }
  }
  final hashes = <String, String>{};
  for (final suffix in _sidecars) {
    final file = File('$path$suffix');
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) continue;
    if (type != FileSystemEntityType.file)
      throw StateError('UID_SNAPSHOT_INVALID_FILE_TYPE');
    hashes[suffix] = (await sha256.bind(file.openRead()).first).toString();
  }
  if (!hashes.containsKey('')) throw StateError('UID_SNAPSHOT_SOURCE_MISSING');
  if (hashes.containsKey('-journal'))
    throw StateError('UID_SNAPSHOT_ROLLBACK_JOURNAL_PRESENT');
  if (hashes.containsKey('-shm') && !hashes.containsKey('-wal'))
    throw StateError('UID_SNAPSHOT_ORPHAN_SHM');
  final database = identity.fileIn(location);
  if (await database.length() < 16 ||
      DatabaseEncryptionBootstrap.hasPlaintextHeader(database)) {
    throw StateError('UID_SNAPSHOT_ENCRYPTED_SOURCE_REQUIRED');
  }
  return hashes;
}

Future<Map<String, String>> _seal(
  Directory source,
  LocalDatabaseIdentity identity,
  Directory archive, {
  Future<void> Function()? simulateWriter,
}) async {
  final hashes = await _sourceSnapshot(source, identity);
  final original = identity.fileIn(source).path;
  final archived = identity.fileIn(archive).path;
  for (final suffix in hashes.keys) {
    await File('$original$suffix').copy('$archived$suffix');
  }
  await simulateWriter?.call();
  if (!same(hashes, await _sourceSnapshot(archive, identity)) ||
      !same(hashes, await _sourceSnapshot(source, identity))) {
    throw StateError('UID_SNAPSHOT_SOURCE_CHANGED');
  }
  return hashes;
}

Future<File> _copyForQuery(
  Directory archive,
  LocalDatabaseIdentity identity,
  Directory cache, {
  required bool includeWal,
}) async {
  final folder = await cache.createTemp('uid-query-');
  final copy = identity.fileIn(folder);
  final archived = identity.fileIn(archive);
  await archived.copy(copy.path);
  if (includeWal) {
    final wal = File('${archived.path}-wal');
    if (await wal.exists()) await wal.copy('${copy.path}-wal');
  }
  // Reconstruct the WAL index in this private query copy. The archived SHM
  // and all source files stay untouched by SQLite.
  return copy;
}

({int schema, String integrity, String taskId, int queueRows, bool exactIntent})
_read(File copy, String key, LocalDatabaseIdentity identity) {
  final db = sqlite3.open(copy.path, mode: OpenMode.readWrite);
  try {
    DatabaseEncryptionBootstrap.configureEncryptedConnection(db, key);
    db.execute('PRAGMA query_only=ON');
    final schema = db.select('PRAGMA user_version').single.values.single as int;
    if (schema != AppDatabase.currentSchemaVersion)
      throw StateError('UID_SNAPSHOT_SCHEMA_UNSUPPORTED');
    final integrity =
        db.select('PRAGMA integrity_check').single.values.single as String;
    final taskId =
        db
                .select('SELECT id FROM task_table WHERE id = ?', [_task])
                .single
                .values
                .single
            as String;
    final queue = db.select(
      'SELECT owner_uid, collection, doc_id, operation_type, payload_json, created_at FROM sync_queue_table',
    );
    final expected = [identity.uid, 'tasks', _intent, 'create', _payload, 123];
    return (
      schema: schema,
      integrity: integrity,
      taskId: taskId,
      queueRows: queue.length,
      exactIntent:
          queue.length == 1 && same(expected, queue.single.values.toList()),
    );
  } finally {
    db.dispose();
  }
}

Future<bool> _refuses(Future<Object?> Function() action, String code) async {
  try {
    await action();
    return false;
  } on StateError catch (error) {
    return error.message == code;
  }
}

Future<void> _negativeCopies(
  Directory source,
  Directory cache,
  UserDbKeyManager keyManager,
) async {
  final identity = fixture.uidIdentity;
  final key = await keyManager.getEncryptionKey(identity, allowCreate: false);
  final unrelated = await cache.createTemp('uid-invalid-');
  final file = identity.fileIn(unrelated);
  final orphan = File('${file.path}-wal');
  await orphan.writeAsString('SYNTHETIC-ORPHAN-WAL', flush: true);
  _check(
    await _refuses(
      () => _sourceSnapshot(unrelated, identity),
      'UID_SNAPSHOT_SOURCE_MISSING',
    ),
    'orphan-wal-refused',
  );
  _check(
    await orphan.readAsString() == 'SYNTHETIC-ORPHAN-WAL',
    'orphan-wal-preserved',
  );

  final archived = await cache.createTemp('uid-negative-archive-');
  await _seal(source, identity, archived);
  final withArtifact = await cache.createTemp('uid-artifact-');
  await identity.fileIn(archived).copy(identity.fileIn(withArtifact).path);
  final artifact = File(
    '${identity.fileIn(withArtifact).path}.encryption-candidate-wal',
  );
  await artifact.writeAsString('SYNTHETIC-ENC-CANDIDATE-WAL', flush: true);
  _check(
    await _refuses(
      () => _sourceSnapshot(withArtifact, identity),
      'UID_SNAPSHOT_MIGRATION_ARTIFACT_PRESENT',
    ),
    'candidate-sidecar-refused',
  );
  _check(
    await artifact.readAsString() == 'SYNTHETIC-ENC-CANDIDATE-WAL',
    'candidate-sidecar-preserved',
  );

  final fakeSource = await cache.createTemp('uid-concurrent-');
  final fakeFile = identity.fileIn(fakeSource);
  await identity.fileIn(archived).copy(fakeFile.path);
  final interrupted = await cache.createTemp('uid-incomplete-');
  _check(
    await _refuses(
      () => _seal(
        fakeSource,
        identity,
        interrupted,
        simulateWriter: () async {
          await fakeFile.writeAsString(
            'SYNTHETIC-WRITER',
            mode: FileMode.append,
            flush: true,
          );
        },
      ),
      'UID_SNAPSHOT_SOURCE_CHANGED',
    ),
    'changing-source-refused',
  );

  final wrongSchema = await _copyForQuery(
    archived,
    identity,
    cache,
    includeWal: false,
  );
  final db = sqlite3.open(wrongSchema.path, mode: OpenMode.readWrite);
  try {
    DatabaseEncryptionBootstrap.configureEncryptedConnection(db, key);
    db.execute('PRAGMA user_version=10');
  } finally {
    db.dispose();
  }
  _check(
    await _refuses(
      () async => _read(wrongSchema, key, identity),
      'UID_SNAPSHOT_SCHEMA_UNSUPPORTED',
    ),
    'unsupported-schema-refused',
  );
  final wrongIdentity = LocalDatabaseIdentity(
    'synthetic-unrelated-database-id',
  );
  _check(
    await _refuses(
      () => _sourceSnapshot(source, wrongIdentity),
      'UID_SNAPSHOT_SOURCE_MISSING',
    ),
    'unrelated-namespace-refused',
  );
}
