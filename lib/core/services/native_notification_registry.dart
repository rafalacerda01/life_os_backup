import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:path_provider/path_provider.dart';
import '../database/local_database_identity.dart';

const ownedNotificationPrefix = 'life_os_owned_v2:';

class NativeNotificationOwnership {
  const NativeNotificationOwnership._(
    this.id,
    this.logicalId,
    this.owner,
    this.payload,
    this.tag,
    this.state, {
    this.deliveryPayload,
  });
  final int id, logicalId;

  /// [payload] is a digest. The delivery body exists only in the process that
  /// reserved it; SQLite does not copy the local action token.
  final String owner, payload, tag, state;
  final String? deliveryPayload;
}

class NativeNotificationRegistry {
  NativeNotificationRegistry(this.database) {
    database.execute('PRAGMA busy_timeout=5000');
    database.execute('PRAGMA synchronous=FULL');
    database.execute(
      'CREATE TABLE IF NOT EXISTS native_notification_owners (id INTEGER PRIMARY KEY, logical_id INTEGER NOT NULL, owner TEXT NOT NULL, payload TEXT NOT NULL, tag TEXT NOT NULL, state TEXT NOT NULL)',
    );
    database.execute(
      'CREATE TABLE IF NOT EXISTS native_notification_seals (owner TEXT PRIMARY KEY)',
    );
  }
  final Database database;
  static Future<NativeNotificationRegistry>? _instance;
  static Future<NativeNotificationRegistry> open() => _instance ??= () async {
    final directory = await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    return NativeNotificationRegistry(
      sqlite3.open(
        File('${directory.path}/life_os_native_ownership_v1.sqlite').path,
      ),
    );
  }();
  static const maxRecords = 10000;
  void _bound(LocalDatabaseIdentity identity) {
    if (!identity.isBound)
      throw StateError('LOCAL_GENERATION_BINDING_REQUIRED');
  }

  bool sealed(LocalDatabaseIdentity identity) {
    _bound(identity);
    return database.select(
      'SELECT owner FROM native_notification_seals WHERE owner=?',
      [identity.namespace],
    ).isNotEmpty;
  }

  NativeNotificationOwnership reserve(
    LocalDatabaseIdentity identity,
    int logicalId,
    String? originalPayload,
    Set<int> occupied,
  ) {
    _bound(identity);
    if (logicalId < 0 ||
        logicalId > 0x7fffffff ||
        originalPayload != null && originalPayload.length > 2048)
      throw ArgumentError('NATIVE_LOGICAL_INPUT_INVALID');
    database.execute('BEGIN IMMEDIATE');
    try {
      final count =
          database
                  .select(
                    'SELECT COUNT(*) AS n FROM native_notification_owners',
                  )
                  .single['n']
              as int;
      if (sealed(identity) || count >= maxRecords)
        throw StateError('NATIVE_OWNER_CLOSED_OR_LIMIT');
      var id =
          (database
                      .select(
                        'SELECT MAX(id) AS n FROM native_notification_owners',
                      )
                      .single['n']
                  as int? ??
              999999) +
          1;
      while (occupied.contains(id)) {
        id++;
      }
      if (id > 0x7fffffff) throw StateError('NATIVE_ID_EXHAUSTED');
      final nonce = base64Url.encode(
        List<int>.generate(16, (_) => Random.secure().nextInt(256)),
      );
      final body =
          ownedNotificationPrefix +
          jsonEncode({
            'v': 2,
            'owner': identity.namespace,
            'id': id,
            'nonce': nonce,
            'payload': originalPayload,
          });
      final digest = sha256.convert(utf8.encode(body)).toString(),
          tag = 'lifeos:${identity.namespace}:$id';
      database.execute(
        'INSERT INTO native_notification_owners VALUES (?,?,?,?,?,?)',
        [id, logicalId, identity.namespace, digest, tag, 'RESERVED'],
      );
      database.execute('COMMIT');
      return NativeNotificationOwnership._(
        id,
        logicalId,
        identity.namespace,
        digest,
        tag,
        'RESERVED',
        deliveryPayload: body,
      );
    } catch (_) {
      database.execute('ROLLBACK');
      rethrow;
    }
  }

  NativeNotificationOwnership _record(Row row) {
    final id = row['id'] as int,
        logical = row['logical_id'] as int,
        owner = row['owner'] as String,
        digest = row['payload'] as String,
        tag = row['tag'] as String,
        state = row['state'] as String;
    if (id < 1 ||
        id > 0x7fffffff ||
        logical < 0 ||
        logical > 0x7fffffff ||
        !RegExp(r'^u_[0-9a-f]{64}$').hasMatch(owner) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest) ||
        tag != 'lifeos:$owner:$id' ||
        !{'RESERVED', 'ACTIVE', 'UNKNOWN', 'RETIRED'}.contains(state))
      throw const FormatException('NATIVE_REGISTRY_INVALID');
    return NativeNotificationOwnership._(
      id,
      logical,
      owner,
      digest,
      tag,
      state,
    );
  }

  List<NativeNotificationOwnership> records(LocalDatabaseIdentity identity) {
    _bound(identity);
    return database
        .select(
          'SELECT * FROM native_notification_owners WHERE owner=? ORDER BY id',
          [identity.namespace],
        )
        .map(_record)
        .toList();
  }

  void state(NativeNotificationOwnership row, String state) {
    if (!{'ACTIVE', 'UNKNOWN', 'RETIRED'}.contains(state))
      throw ArgumentError('NATIVE_STATE_INVALID');
    final rows = database.select(
      'SELECT * FROM native_notification_owners WHERE id=? AND owner=? AND payload=?',
      [row.id, row.owner, row.payload],
    );
    if (rows.length != 1) throw StateError('NATIVE_OWNER_CHANGED');
    final current = _record(rows.single);
    if (current.state == 'RETIRED' && state != 'RETIRED' ||
        state == 'ACTIVE' && current.state != 'RESERVED')
      throw StateError('NATIVE_TERMINAL_OR_UNKNOWN');
    final activeFence = state == 'ACTIVE'
        ? ' AND NOT EXISTS(SELECT 1 FROM native_notification_seals WHERE owner=?)'
        : '';
    database.execute(
      'UPDATE native_notification_owners SET state=? WHERE id=? AND owner=? AND payload=? AND state=?$activeFence',
      [
        state,
        row.id,
        row.owner,
        row.payload,
        current.state,
        if (state == 'ACTIVE') row.owner,
      ],
    );
    if (database.updatedRows != 1) throw StateError('NATIVE_OWNER_CHANGED');
  }

  void seal(LocalDatabaseIdentity identity) {
    _bound(identity);
    database.execute(
      'INSERT OR IGNORE INTO native_notification_seals VALUES (?)',
      [identity.namespace],
    );
  }

  bool matches(NativeNotificationOwnership row, String? observed) {
    if (observed == null ||
        !observed.startsWith(ownedNotificationPrefix) ||
        sha256.convert(utf8.encode(observed)).toString() != row.payload)
      return false;
    try {
      final d = jsonDecode(observed.substring(ownedNotificationPrefix.length));
      return d is Map &&
          d.length == 5 &&
          d['v'] == 2 &&
          d['owner'] == row.owner &&
          d['id'] == row.id &&
          d['nonce'] is String &&
          RegExp(r'^[A-Za-z0-9_-]{22}==$').hasMatch(d['nonce'] as String) &&
          (d['payload'] == null || d['payload'] is String);
    } catch (_) {
      return false;
    }
  }

  String? originalPayload(NativeNotificationOwnership row, String? observed) {
    if (!matches(row, observed)) throw StateError('NATIVE_OWNERSHIP_UNKNOWN');
    return (jsonDecode(observed!.substring(ownedNotificationPrefix.length))
            as Map)['payload']
        as String?;
  }

  void close() => database.close();
}

class NativeNotificationEffectGate {
  static Future<void> _tail = Future<void>.value();
  static Future<T> run<T>(Future<T> Function() action) {
    final run = _tail.then((_) => action());
    _tail = run.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return run;
  }
}
