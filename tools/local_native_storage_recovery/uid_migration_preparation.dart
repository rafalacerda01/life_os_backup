import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:life_os/core/database/database_encryption.dart';
import 'package:life_os/core/database/local_database_identity.dart';
import 'package:life_os/core/database/local_profile_admission.dart';
import 'package:sqlite3/sqlite3.dart';

const historicalQueue = 'migration_sync_queue_archive';
const _queue = 'sync_queue_table';
const _sidecars = ['', '-wal', '-shm', '-journal'];

String keyDigest(String key) => sha256.convert(utf8.encode(key)).toString();

Future<String> fileDigest(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

/// Trust roots and all inputs belong exclusively to the synthetic lab.
final class FixtureCustody {
  FixtureCustody({
    required this.id,
    required this.project,
    required this.database,
    required this.tenant,
  }) {
    if (id.isLocalInstallation ||
        (id.generation != null && !id.isBound) ||
        (id.isBound &&
            (project != id.projectId ||
                database != id.databaseId ||
                tenant != id.tenantId))) {
      throw StateError('CUSTODY_BINDING_INVALID');
    }
  }

  final LocalDatabaseIdentity id;
  final String project;
  final String database;
  final String? tenant;

  Map<String, Object?> claims(String fingerprint) => {
    'version': 1,
    'audience': 'life-os-stage19-synthetic',
    'project': project,
    'database': database,
    'tenant': tenant,
    'uid': id.uid,
    'generation': id.generation,
    'namespace': id.namespace,
    'file': id.fileName,
    'keyFingerprint': fingerprint,
  };

  static Map<String, Object?> issue(
    Map<String, Object?> claims,
    String issuerKey,
  ) {
    final payload = jsonEncode(claims);
    return {'payload': payload, 'mac': _mac(payload, issuerKey)};
  }

  void authorize(Object? receipt, String issuerKey, String fingerprint) {
    if (receipt is! Map || receipt.length != 2)
      throw StateError('CUSTODY_RECEIPT_INVALID');
    final payload = receipt['payload'];
    final mac = receipt['mac'];
    if (payload is! String || mac is! String)
      throw StateError('CUSTODY_RECEIPT_INVALID');
    final wanted = _mac(payload, issuerKey);
    if (!_equalMac(wanted, mac)) throw StateError('CUSTODY_SIGNATURE_INVALID');
    if (payload != jsonEncode(claims(fingerprint)))
      throw StateError('CUSTODY_CLAIMS_MISMATCH');
  }

  static String _mac(String payload, String key) => Hmac(
    sha256,
    base64Url.decode(key),
  ).convert(utf8.encode(payload)).toString();

  static bool _equalMac(String a, String b) {
    if (a.length != b.length) return false;
    var mismatch = 0;
    for (var i = 0; i < a.length; i++) {
      mismatch |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return mismatch == 0;
  }
}

Future<Map<String, String>> fileFamily(File main) async {
  final base = main.path;
  final hashes = <String, String>{};
  for (final infix in ['', '.encryption-candidate', '.plaintext-backup']) {
    for (final suffix in _sidecars) {
      final file = File('$base$infix$suffix');
      final type = await FileSystemEntity.type(file.path, followLinks: false);
      if (type == FileSystemEntityType.notFound) continue;
      if (type != FileSystemEntityType.file ||
          infix.isNotEmpty ||
          suffix == '-journal') {
        throw StateError('SOURCE_FAMILY_UNSAFE');
      }
      hashes[suffix.isEmpty ? 'main' : suffix.substring(1)] = await fileDigest(
        file,
      );
    }
  }
  if (!hashes.containsKey('main') ||
      hashes.containsKey('wal') != hashes.containsKey('shm')) {
    throw StateError('SOURCE_FAMILY_INCOMPLETE');
  }
  if (await main.length() < 16 ||
      DatabaseEncryptionBootstrap.hasPlaintextHeader(main)) {
    throw StateError('SOURCE_ENCRYPTION_REQUIRED');
  }
  return hashes;
}

/// Called within a lease of the same zero-byte coordination database that
/// every synthetic writer takes before touching these source families.
Future<Map<String, String>> sealSource({
  required Directory source,
  required Directory archive,
  required FixtureCustody custody,
  required Object? receipt,
  required String issuerKey,
  required String sourceKey,
}) async {
  custody.authorize(receipt, issuerKey, keyDigest(sourceKey));
  LocalProfileAdmission.requireCurrent(source);
  final main = custody.id.fileIn(source);
  final sealed = custody.id.fileIn(archive);
  if (source.absolute.path == archive.absolute.path || await archive.exists()) {
    throw StateError('SNAPSHOT_ARCHIVE_NOT_FRESH');
  }
  final before = await fileFamily(main);
  await archive.create();
  for (final name in before.keys) {
    final suffix = name == 'main' ? '' : '-$name';
    await File('${main.path}$suffix').copy('${sealed.path}$suffix');
  }
  await verifySealed(sealed, before);
  await verifySealed(main, before);
  return before;
}

Future<void> verifySealed(File file, Map<String, String> expected) async {
  if (jsonEncode(await fileFamily(file)) != jsonEncode(expected)) {
    throw StateError('SNAPSHOT_HASH_MISMATCH');
  }
}

Future<File> queryCopy(
  File sealed,
  Directory work, {
  required bool includeWal,
}) async {
  if (await work.exists()) throw StateError('SNAPSHOT_QUERY_NOT_FRESH');
  await work.create();
  final copy = await sealed.copy('${work.path}/query.sqlite');
  final wal = File('${sealed.path}-wal');
  if (includeWal && await wal.exists()) await wal.copy('${copy.path}-wal');
  return copy;
}

Database openCopy(File file, String key, {required bool queryOnly}) {
  final db = sqlite3.open(file.path, mode: OpenMode.readWrite);
  try {
    DatabaseEncryptionBootstrap.configureEncryptedConnection(db, key);
    db.execute('PRAGMA foreign_keys=ON');
    if (queryOnly) db.execute('PRAGMA query_only=ON');
    return db;
  } catch (_) {
    db.dispose();
    rethrow;
  }
}

String _identifier(String value) {
  if (!RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(value))
    throw StateError('SCHEMA_IDENTIFIER_INVALID');
  return '"$value"';
}

void requireIntegrity(Database db, int schema) {
  if (db.select('PRAGMA user_version').single.values.single != schema)
    throw StateError('SCHEMA_UNSUPPORTED');
  if (db.select('PRAGMA integrity_check').single.values.single != 'ok' ||
      db.select('PRAGMA foreign_key_check').isNotEmpty)
    throw StateError('DATA_INTEGRITY_FAILED');
}

final class EntityRows {
  EntityRows(this.columns, this.rows);
  final List<String> columns;
  final List<List<Object?>> rows;

  String get digest =>
      keyDigest(jsonEncode([columns, rows.map(jsonEncode).toList()..sort()]));
}

EntityRows readRows(Database db, String table) {
  final rows = db.select('SELECT * FROM ${_identifier(table)}');
  return EntityRows(
    rows.columnNames,
    rows.map((row) => row.values.toList()).toList(),
  );
}

Map<String, EntityRows> readEntities(Database db) {
  return {
    for (final row in db.select(
      "SELECT name FROM sqlite_schema WHERE type='table' AND substr(name,1,7)!='sqlite_' ORDER BY name",
    ))
      row['name'] as String: readRows(db, row['name'] as String),
  };
}

Map<String, Object?> entityProof(Map<String, EntityRows> data) => {
  for (final entry in data.entries)
    entry.key: {'rows': entry.value.rows.length, 'digest': entry.value.digest},
};

void importCandidate(
  Database destination,
  Map<String, EntityRows> source,
  List<List<Object?>> sequence,
) {
  const localTables = {'market_items', 'market_purchases'};
  final inventory = readEntities(destination);
  if (!inventory.keys.toSet().containsAll(source.keys) ||
      inventory.keys
          .toSet()
          .difference(source.keys.toSet())
          .difference(localTables)
          .isNotEmpty ||
      !inventory.keys.toSet().containsAll(localTables) ||
      inventory.values.any((rows) => rows.rows.isNotEmpty)) {
    throw StateError('DESTINATION_SCHEMA_MISMATCH');
  }
  destination.execute('BEGIN IMMEDIATE');
  try {
    destination.execute('PRAGMA defer_foreign_keys=ON');
    destination.execute(
      'CREATE TABLE $historicalQueue AS SELECT * FROM $_queue WHERE 0',
    );
    for (final entry in source.entries) {
      if (jsonEncode(entry.value.columns) !=
          jsonEncode(inventory[entry.key]!.columns))
        throw StateError('ENTITY_SCHEMA_MISMATCH');
      final table = _identifier(
        entry.key == _queue ? historicalQueue : entry.key,
      );
      final columns = entry.value.columns.map(_identifier).join(',');
      final marks = List.filled(entry.value.columns.length, '?').join(',');
      final insert = destination.prepare(
        'INSERT INTO $table ($columns) VALUES ($marks)',
      );
      try {
        for (final row in entry.value.rows) {
          insert.execute(row);
        }
      } finally {
        insert.dispose();
      }
    }
    destination.execute('DELETE FROM sqlite_sequence');
    for (final row in sequence) {
      destination.execute(
        'INSERT INTO sqlite_sequence (name,seq) VALUES (?,?)',
        row,
      );
    }
    for (final table in [_queue, historicalQueue]) {
      for (final operation in ['insert', 'update', 'delete']) {
        destination.execute(
          "CREATE TRIGGER protect_${table}_$operation BEFORE $operation ON $table BEGIN SELECT RAISE(ABORT, 'HISTORICAL_QUEUE_FROZEN'); END",
        );
      }
    }
    if (destination.select('PRAGMA foreign_key_check').isNotEmpty)
      throw StateError('DESTINATION_RELATIONSHIP_INVALID');
    destination.execute('COMMIT');
  } catch (_) {
    destination.execute('ROLLBACK');
    rethrow;
  }
}

Map<String, EntityRows> comparableDestination(Database db) {
  final data = readEntities(db);
  final queue = data[_queue];
  final archive = data.remove(historicalQueue);
  if (queue == null ||
      queue.rows.isNotEmpty ||
      archive == null ||
      data.remove('market_items')?.rows.isNotEmpty != false ||
      data.remove('market_purchases')?.rows.isNotEmpty != false) {
    throw StateError('DESTINATION_QUEUE_OR_LOCAL_TABLE_INVALID');
  }
  data[_queue] = archive;
  return data;
}
