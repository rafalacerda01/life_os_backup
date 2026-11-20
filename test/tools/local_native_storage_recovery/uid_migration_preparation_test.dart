import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/local_database_identity.dart';
import 'package:life_os/core/database/local_profile_admission.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../../tools/local_native_storage_recovery/uid_migration_preparation.dart';

final _issuer = base64UrlEncode(List.filled(32, 1));
final _dbKey = base64UrlEncode(List.filled(32, 2));

FixtureCustody _custody() => FixtureCustody(
  id: LocalDatabaseIdentity.bound(
    projectId: 'synthetic',
    databaseId: '(default)',
    tenantId: 'synthetic-tenant',
    uid: 'synthetic-user',
    generation: '00000000-0000-4000-8000-000000000019',
  ),
  project: 'synthetic',
  database: '(default)',
  tenant: 'synthetic-tenant',
);

Matcher _refused(String code) =>
    throwsA(isA<StateError>().having((e) => e.message, 'message', code));

void main() {
  test('custody binds every field including native key fingerprint', () {
    final custody = _custody();
    final fingerprint = keyDigest(_dbKey);
    final valid = custody.claims(fingerprint);
    custody.authorize(
      FixtureCustody.issue(valid, _issuer),
      _issuer,
      fingerprint,
    );
    for (final field in valid.keys) {
      expect(
        () => custody.authorize(
          FixtureCustody.issue({...valid, field: 'changed'}, _issuer),
          _issuer,
          fingerprint,
        ),
        _refused('CUSTODY_CLAIMS_MISMATCH'),
      );
    }
    expect(
      () => custody.authorize(
        FixtureCustody.issue(valid, _dbKey),
        _issuer,
        fingerprint,
      ),
      _refused('CUSTODY_SIGNATURE_INVALID'),
    );
    expect(
      () => FixtureCustody(
        id: custody.id,
        project: 'other',
        database: '(default)',
        tenant: 'synthetic-tenant',
      ),
      _refused('CUSTODY_BINDING_INVALID'),
    );
  });

  test('capture requires verified custody and a live source lease', () async {
    final folder = await Directory.systemTemp.createTemp(
      'stage19-uid-fixture-',
    );
    final archive = Directory('${folder.path}/archive');
    final source = Directory('${folder.path}/source');
    await source.create();
    final custody = _custody();
    final claims = custody.claims(keyDigest(_dbKey));
    final receipt = FixtureCustody.issue(claims, _issuer);
    Future<Map<String, String>> capture(Object? withReceipt) => sealSource(
      source: source,
      archive: archive,
      custody: custody,
      receipt: withReceipt,
      issuerKey: _issuer,
      sourceKey: _dbKey,
    );
    await expectLater(capture(null), _refused('CUSTODY_RECEIPT_INVALID'));
    await expectLater(
      capture(receipt),
      _refused('LOCAL_PROFILE_ADMISSION_REQUIRED'),
    );
    expect(await archive.exists(), isFalse);
    final original = custody.id.fileIn(source);
    await original.writeAsBytes(List.filled(32, 4), flush: true);
    await File('${original.path}-wal').writeAsString('synthetic wal');
    await expectLater(
      LocalProfileAdmission(source).run(() => capture(receipt)),
      _refused('SOURCE_FAMILY_INCOMPLETE'),
    );
    await File('${original.path}-shm').writeAsString('synthetic shm');
    final sealed = await LocalProfileAdmission(
      source,
    ).run(() => capture(receipt));
    expect(sealed, await fileFamily(original));
    await File(
      '${custody.id.fileIn(archive).path}-wal',
    ).writeAsString('changed copy');
    await expectLater(
      verifySealed(custody.id.fileIn(archive), sealed),
      _refused('SNAPSHOT_HASH_MISMATCH'),
    );
    expect(sealed, await fileFamily(original));
  });

  test('historical queue is frozen and stays out of the active queue', () {
    final db = _emptyCandidate();
    addTearDown(db.dispose);
    final rows = _fixtureRows();
    importCandidate(db, rows, [
      ['sync_queue_table', 7],
    ]);
    expect(entityProof(comparableDestination(db)), entityProof(rows));
    expect(readRows(db, 'sync_queue_table').rows, isEmpty);
    final frozen = throwsA(
      isA<SqliteException>().having(
        (e) => e.message,
        'message',
        contains('HISTORICAL_QUEUE_FROZEN'),
      ),
    );
    expect(
      () => db.execute(
        'INSERT INTO sync_queue_table SELECT * FROM $historicalQueue',
      ),
      frozen,
    );
    expect(
      () => db.execute("UPDATE $historicalQueue SET status='succeeded'"),
      frozen,
    );
    expect(() => db.execute('DELETE FROM $historicalQueue'), frozen);
    expect(entityProof(comparableDestination(db)), entityProof(rows));
  });

  test(
    'incompatible entity shape and broken relation roll back the entire candidate',
    () {
      for (final badRows in [
        EntityRows(
          ['id', 'unknown_column'],
          [
            ['f1', 's1'],
          ],
        ),
        EntityRows(
          ['id', 'subject_id'],
          [
            ['f1', 'unknown-subject'],
          ],
        ),
      ]) {
        final db = _emptyCandidate();
        try {
          final source = _fixtureRows()..['flashcards'] = badRows;
          expect(() => importCandidate(db, source, []), throwsStateError);
          final after = readEntities(db);
          expect(after, isNot(contains(historicalQueue)));
          expect(after.values.every((rows) => rows.rows.isEmpty), isTrue);
        } finally {
          db.dispose();
        }
      }
    },
  );
}

Map<String, EntityRows> _fixtureRows() => {
  'subjects': EntityRows(
    ['id'],
    [
      ['s1'],
    ],
  ),
  'flashcards': EntityRows(
    ['id', 'subject_id'],
    [
      ['f1', 's1'],
    ],
  ),
  'sync_queue_table': EntityRows(
    ['id', 'status'],
    [
      [7, 'pending'],
    ],
  ),
};

Database _emptyCandidate() {
  final db = sqlite3.openInMemory();
  db.execute('PRAGMA foreign_keys=ON');
  db.execute('CREATE TABLE subjects(id TEXT PRIMARY KEY)');
  db.execute(
    'CREATE TABLE flashcards(id TEXT PRIMARY KEY, subject_id TEXT REFERENCES subjects(id))',
  );
  db.execute(
    'CREATE TABLE sync_queue_table(id INTEGER PRIMARY KEY AUTOINCREMENT, status TEXT)',
  );
  db.execute('CREATE TABLE market_items(id TEXT PRIMARY KEY)');
  db.execute('CREATE TABLE market_purchases(id TEXT PRIMARY KEY)');
  return db;
}
