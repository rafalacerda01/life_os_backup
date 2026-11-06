import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import '../database/app_database.dart';
import '../database/local_account_session.dart';
import '../database/local_database_identity.dart';

/// Canonical JSON numbers follow the server's finite IEEE-754 representation.
/// Unsafe integral values, non-finite values and numeric strings are not coerced.
String httpCanonical(Object? value) {
  if (value == null || value is String || value is bool)
    return jsonEncode(value);
  if (value is int && value.abs() <= 9007199254740991) return jsonEncode(value);
  if (value is double && value.isFinite && value.abs() <= 9007199254740991) {
    // JSON does not distinguish -0 or 1.0 from 0 and 1. No invalid integer is
    // rounded into range. Domain counters still require safe integer validation.
    if (value == value.truncateToDouble()) return value.toInt().toString();
    final text = value.toString().toLowerCase();
    if (!text.contains('e')) return text;
    final parts = text.split('e'), exponent = int.parse(parts[1]);
    final coefficient = parts[0].endsWith('.0')
        ? parts[0].substring(0, parts[0].length - 2)
        : parts[0];
    // ECMAScript emits plain notation at 1e-6 and scientific below it.
    if (exponent >= -6 && exponent < 0) {
      final negative = coefficient.startsWith('-');
      final digits = (negative ? coefficient.substring(1) : coefficient)
          .replaceAll('.', '');
      return '${negative ? '-' : ''}0.${'0' * (-exponent - 1)}$digits';
    }
    return '${coefficient}e${exponent < 0 ? '' : '+'}$exponent';
  }
  if (value is List) return '[${value.map(httpCanonical).join(',')}]';
  if (value is Map<String, dynamic>) {
    final keys = value.keys.toList()..sort();
    return '{${keys.map((k) => '${jsonEncode(k)}:${httpCanonical(value[k])}').join(',')}}';
  }
  throw StateError('HTTP_CUSTODY_BODY_UNSUPPORTED');
}

String httpDigest(Object? value) =>
    sha256.convert(utf8.encode(httpCanonical(value))).toString();

final class GenerationalHttpIntent {
  const GenerationalHttpIntent._(
    this.operationId,
    this.route,
    this.bodyJson,
    this.bindingJson,
    this.syncFingerprint,
    this.syncId,
    this.protocolVersion,
  );
  final String operationId, route, bodyJson, bindingJson;
  final String? syncFingerprint;
  final int? syncId;
  final int protocolVersion;
  Map<String, dynamic> get body => jsonDecode(bodyJson) as Map<String, dynamic>;
  Map<String, dynamic> get context => {
    'v': protocolVersion,
    'binding': jsonDecode(bindingJson),
    'operationId': operationId,
    'route': route,
    'bodyHash': httpDigest(body),
  };
}

/// Durable journal in the SAME encrypted, generation-scoped SQLite file.
/// No tokens are persisted. Versioned extension table never adopts UID-only DBs.
class GenerationalHttpStore {
  GenerationalHttpStore(this.database)
    : identity =
          database.identity ??
          (throw StateError('HTTP_BOUND_DATABASE_REQUIRED')) {
    if (!identity.isBound) throw StateError('HTTP_BOUND_DATABASE_REQUIRED');
  }
  final AppDatabase database;
  final LocalDatabaseIdentity identity;
  static const _table = 'generational_http_intents_v1';
  Future<void> _schema() async {
    await database.customStatement(
      '''CREATE TABLE IF NOT EXISTS $_table (
      operation_id TEXT NOT NULL PRIMARY KEY, route TEXT NOT NULL,
      body_json TEXT NOT NULL, binding_json TEXT NOT NULL,
      sync_fingerprint TEXT, sync_id INTEGER, phase TEXT NOT NULL,
      response_json TEXT, ack_json TEXT, intent_key TEXT UNIQUE, protocol_version INTEGER NOT NULL)''',
    );
    var columns = await database
        .customSelect('PRAGMA table_info($_table)')
        .get();
    // Old IDs may already have been sent and collided in another installation.
    // Preserve every byte of those intents; a null key requires review, never
    // replay, automatic reassignment or an ACK from an ambiguous old receipt.
    const legacy =
        'operation_id,route,body_json,binding_json,sync_fingerprint,sync_id,phase,response_json,ack_json';
    if (columns.map((r) => r.read<String>('name')).join(',') == legacy) {
      await database.customStatement(
        'ALTER TABLE $_table ADD COLUMN intent_key TEXT',
      );
      columns = await database.customSelect('PRAGMA table_info($_table)').get();
    }
    if (columns.map((r) => r.read<String>('name')).join(',') ==
        '$legacy,intent_key') {
      // Missing protocol metadata means v1, including acknowledged records.
      // Never relabel a possibly dispatched context during a local upgrade.
      await database.customStatement(
        'ALTER TABLE $_table ADD COLUMN protocol_version INTEGER NOT NULL DEFAULT 1',
      );
      columns = await database.customSelect('PRAGMA table_info($_table)').get();
    }
    if (columns.map((r) => r.read<String>('name')).join(',') !=
        '$legacy,intent_key,protocol_version') {
      throw StateError('HTTP_OUTBOX_SCHEMA_CONFLICT');
    }
    await database.customStatement(
      'CREATE UNIQUE INDEX IF NOT EXISTS http_intent_key_v2 ON $_table(intent_key)',
    );
  }

  static String fingerprint(SyncQueueTableData row) => httpDigest({
    'id': row.id,
    'owner': row.ownerUid,
    'collection': row.collection,
    'docId': row.docId,
    'type': row.operationType,
    'payload': row.payloadJson,
    'createdAt': row.createdAt,
  });
  Future<GenerationalHttpIntent> prepare({
    required String stableKey,
    required String route,
    required Map<String, dynamic> body,
    SyncQueueTableData? syncRow,
  }) async {
    if (stableKey.isEmpty ||
        stableKey.length > 200 ||
        !{
          'sync',
          'activity/task-complete',
          'focus/start',
          'focus/finish',
          'focus/cancel',
          'focus/status',
        }.contains(route) ||
        (syncRow != null &&
            (route != 'sync' ||
                syncRow.ownerUid != identity.uid ||
                syncRow.status != SyncQueuePersistenceStatus.pending ||
                syncRow.isSynced))) {
      throw StateError('HTTP_INTENT_INVALID');
    }
    final binding = httpCanonical(identity.toBinding()),
        payload = httpCanonical(body);
    final legacyId = httpDigest({
      'binding': identity.toBinding(),
      'key': stableKey,
    });
    final fp = syncRow == null ? null : fingerprint(syncRow);
    return database.transaction(() async {
      await _schema();
      final legacy = await database
          .customSelect(
            'SELECT operation_id FROM $_table WHERE operation_id = ? AND intent_key IS NULL',
            variables: [Variable<String>(legacyId)],
          )
          .getSingleOrNull();
      if (legacy != null)
        throw StateError('HTTP_LEGACY_INTENT_REVIEW_REQUIRED');
      final keyed = await database
          .customSelect(
            'SELECT operation_id FROM $_table WHERE intent_key = ?',
            variables: [Variable<String>(stableKey)],
          )
          .getSingleOrNull();
      final existing = keyed == null
          ? null
          : await _read(keyed.read<String>('operation_id'));
      if (existing != null) {
        if (existing.protocolVersion != 2)
          throw StateError('HTTP_LEGACY_INTENT_REVIEW_REQUIRED');
        if (existing.route != route ||
            existing.bodyJson != payload ||
            existing.bindingJson != binding ||
            existing.syncFingerprint != fp ||
            existing.syncId != syncRow?.id) {
          throw StateError('HTTP_INTENT_CONFLICT');
        }
        if (syncRow != null) await _checkRow(syncRow.id, fp!);
        return existing;
      }
      if (syncRow != null) await _checkRow(syncRow.id, fp!);
      // 256 bits of OS entropy identify an intention, not its authority. SQL
      // persists the immutable ID before dispatch; retries find it by local key.
      final random = Random.secure();
      final id = List.generate(
        32,
        (_) => random.nextInt(256),
      ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      await database.customStatement(
        'INSERT INTO $_table (operation_id,route,body_json,binding_json,sync_fingerprint,sync_id,phase,intent_key,protocol_version) VALUES (?,?,?,?,?,?,?,?,?)',
        [id, route, payload, binding, fp, syncRow?.id, 'PENDING', stableKey, 2],
      );
      return GenerationalHttpIntent._(
        id,
        route,
        payload,
        binding,
        fp,
        syncRow?.id,
        2,
      );
    });
  }

  Future<GenerationalHttpIntent?> _read(String id) async {
    final row = await database
        .customSelect(
          'SELECT * FROM $_table WHERE operation_id = ?',
          variables: [Variable<String>(id)],
        )
        .getSingleOrNull();
    if (row == null) return null;
    return GenerationalHttpIntent._(
      row.read<String>('operation_id'),
      row.read<String>('route'),
      row.read<String>('body_json'),
      row.read<String>('binding_json'),
      row.readNullable<String>('sync_fingerprint'),
      row.readNullable<int>('sync_id'),
      row.read<int>('protocol_version'),
    );
  }

  Future<void> verify(GenerationalHttpIntent intent) =>
      database.transaction(() async {
        await _schema();
        final key = await database
            .customSelect(
              'SELECT intent_key FROM $_table WHERE operation_id = ?',
              variables: [Variable<String>(intent.operationId)],
            )
            .getSingleOrNull();
        if (key != null && key.readNullable<String>('intent_key') == null) {
          throw StateError('HTTP_LEGACY_INTENT_REVIEW_REQUIRED');
        }
        final saved = await _read(intent.operationId);
        if (saved != null && saved.protocolVersion != 2) {
          throw StateError('HTTP_LEGACY_INTENT_REVIEW_REQUIRED');
        }
        if (saved == null ||
            saved.bindingJson != httpCanonical(identity.toBinding()) ||
            httpCanonical(saved.context) != httpCanonical(intent.context) ||
            saved.syncFingerprint != intent.syncFingerprint ||
            saved.syncId != intent.syncId) {
          throw StateError('HTTP_INTENT_CONFLICT');
        }
        if (intent.syncId != null)
          await _checkRow(intent.syncId!, intent.syncFingerprint!);
      });
  Future<List<GenerationalHttpIntent>>
  pending() => database.transaction(() async {
    await _schema();
    final ids = await database
        .customSelect(
          "SELECT operation_id FROM $_table WHERE phase = 'PENDING' ORDER BY rowid",
        )
        .get();
    return [
      for (final r in ids) (await _read(r.read<String>('operation_id')))!,
    ];
  });

  /// Passive review inventory only. Old confirmed results may themselves be
  /// ambiguous; this API never reopens a queue row or grants another dispatch.
  Future<List<GenerationalHttpIntent>>
  legacyForReview() => database.transaction(() async {
    await _schema();
    final ids = await database
        .customSelect(
          'SELECT operation_id FROM $_table WHERE protocol_version != 2 OR intent_key IS NULL ORDER BY rowid',
        )
        .get();
    return [
      for (final row in ids) (await _read(row.read<String>('operation_id')))!,
    ];
  });

  Future<void> _checkRow(int id, String expected) async {
    final row = await (database.select(
      database.syncQueueTable,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    if (row == null ||
        row.ownerUid != identity.uid ||
        row.status != SyncQueuePersistenceStatus.pending ||
        row.isSynced ||
        fingerprint(row) != expected)
      throw StateError('HTTP_SYNC_ROW_CONFLICT');
  }

  Future<void> acknowledge(
    GenerationalHttpIntent intent,
    Map<String, dynamic> response,
    Map<String, dynamic> ack,
    LocalAccountLease lease, {
    void Function()? validateSession,
    Future<void> Function()? acknowledgeDomain,
  }) async {
    lease.requireCurrent();
    if (acknowledgeDomain != null && intent.syncId == null) {
      throw StateError('HTTP_DOMAIN_ACK_REQUIRES_QUEUE');
    }
    if (lease.identity.namespace != identity.namespace ||
        ack['operationReplay'] is! bool ||
        ack['status'] != 200 ||
        httpCanonical(ack) !=
            httpCanonical({
              ...intent.context,
              'status': 200,
              'responseHash': httpDigest(response),
              'operationReplay': ack['operationReplay'],
            })) {
      throw StateError('HTTP_ACK_BINDING_MISMATCH');
    }
    final ticket = database.localMutations.capture();
    await database.transactionWithCommitGuard(
      () async {
        await verify(intent);
        if (intent.syncId != null) {
          await _checkRow(intent.syncId!, intent.syncFingerprint!);
          await acknowledgeDomain?.call();
          final changed = await database.markSyncItemAsSucceeded(
            intent.syncId!,
            identity.uid,
          );
          if (changed != 1) throw StateError('HTTP_SYNC_ACK_CONFLICT');
        }
        await database.customStatement(
          "UPDATE $_table SET phase='CONFIRMED',response_json=?,ack_json=? WHERE operation_id=?",
          [httpCanonical(response), httpCanonical(ack), intent.operationId],
        );
      },
      admission: ticket,
      validateBeforeCommit: () {
        lease.requireCurrent();
        validateSession?.call();
      },
    );
  }
}
