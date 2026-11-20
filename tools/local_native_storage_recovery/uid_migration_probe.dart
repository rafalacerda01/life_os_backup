import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/database_encryption.dart';
import 'package:life_os/core/database/database_sync_policy.dart';
import 'package:life_os/core/database/local_database_identity.dart';
import 'package:life_os/core/database/local_profile_admission.dart';
import 'package:life_os/core/database/user_database_factory.dart';
import 'package:life_os/core/db/user_db_key_manager.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import 'fixture_support.dart' as fixture;
import 'recovery_probe.dart' show same;
import 'uid_migration_preparation.dart';

const _issuer = 'stage19_synthetic_custody_issuer';
const _task = 'SYNTHETIC-CUSTODY-TASK';
const _subject = 'SYNTHETIC-CUSTODY-SUBJECT';
const _flashcard = 'SYNTHETIC-CUSTODY-FLASHCARD';
const _walIntent = 'SYNTHETIC-CUSTODY-WAL';

final class _Lab {
  _Lab(this.support, this.root);

  final Directory support;
  final Directory root;
  final keys = UserDbKeyManager(storage: fixture.proposed);
  final checks = <String, bool>{};
  final openWriters = <Database>[];
  static final _bound = LocalDatabaseIdentity.bound(
    projectId: 'synthetic-stage19-project',
    databaseId: '(default)',
    tenantId: 'synthetic-stage19-tenant',
    uid: 'synthetic-stage19-p1',
    generation: '00000000-0000-4000-8000-000000000019',
  );
  final identities = {
    'uid': FixtureCustody(
      id: LocalDatabaseIdentity('synthetic-stage19-uid'),
      project: 'synthetic-stage19-project',
      database: '(default)',
      tenant: null,
    ),
    'bound': FixtureCustody(
      id: _bound,
      project: _bound.projectId!,
      database: _bound.databaseId!,
      tenant: _bound.tenantId,
    ),
  };

  Directory get sources => Directory('${root.path}/sources');
  File marker(String name) => File('${root.path}/$name');
  File receipt(String label) => File('${root.path}/$label-custody.json');
  LocalProfileAdmission admission() => LocalProfileAdmission(
    sources,
    timeout: const Duration(milliseconds: 500),
  );

  void check(bool condition, String label) {
    checks[label] = condition;
    if (!condition) throw StateError(label);
  }

  Future<void> report(
    String scenario, {
    Map<String, Object?> extra = const {},
  }) async {
    final target = File('${support.path}/stage19-$scenario.json');
    final temp = File('${target.path}.tmp');
    await temp.writeAsString(
      jsonEncode({
        'module': 'uid-p1-migration-preparation',
        'scenario': scenario,
        'pid': pid,
        'checks': checks,
        ...extra,
      }),
      flush: true,
    );
    await temp.rename(target.path);
  }

  Future<void> waitForMarker(String name) async {
    final clock = Stopwatch()..start();
    while (!await marker(name).exists()) {
      if (clock.elapsed > const Duration(seconds: 120))
        throw StateError('COORDINATION_TIMEOUT_$name');
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  Future<String> issuerKey() async {
    final value = await fixture.proposed.read(key: _issuer);
    if (value == null || base64Url.decode(value).length != 32)
      throw StateError('CUSTODY_ISSUER_UNAVAILABLE');
    return value;
  }

  Future<bool> refuses(Future<void> Function() run, String code) async {
    try {
      await run();
      return false;
    } on StateError catch (error) {
      return error.message == code;
    }
  }

  Future<Map<String, Object?>> sourceEvidence() async => {
    for (final entry in identities.entries)
      entry.key: {
        'files': await fileFamily(entry.value.id.fileIn(sources)),
        'custodyReceipt': await fileDigest(receipt(entry.key)),
        'keyFingerprint': keyDigest(
          await keys.getEncryptionKey(entry.value.id, allowCreate: false),
        ),
      },
    'issuerFingerprint': keyDigest(await issuerKey()),
  };

  Future<void> authorize() async {
    final issuer = await issuerKey();
    for (final entry in identities.entries) {
      final key = await keys.getEncryptionKey(
        entry.value.id,
        allowCreate: false,
      );
      entry.value.authorize(
        jsonDecode(await receipt(entry.key).readAsString()),
        issuer,
        keyDigest(key),
      );
    }
  }

  Future<void> seedWriter() async {
    check(!await root.exists(), 'new-synthetic-root');
    await sources.create(recursive: true);
    final random = Random.secure();
    final issuer = base64UrlEncode(
      List.generate(32, (_) => random.nextInt(256)),
    );
    await fixture.proposed.write(key: _issuer, value: issuer);
    await admission().run(() async {
      for (final entry in identities.entries) {
        await _seed(entry.value.id);
        final key = await keys.getEncryptionKey(
          entry.value.id,
          allowCreate: false,
        );
        await receipt(entry.key).writeAsString(
          jsonEncode(
            FixtureCustody.issue(entry.value.claims(keyDigest(key)), issuer),
          ),
          flush: true,
        );
      }
      final source = await sourceEvidence();
      check(openWriters.length == 2, 'source-wal-connections-held-open');
      await report('writer', extra: {'source': source});
      await waitForMarker('release-writer');
    });
    await report('writer-released');
    await waitForMarker('capture-owns-lease');
    final before = await sourceEvidence();
    check(
      await refuses(
        () => admission().run(() async {
          for (final writer in openWriters) {
            writer.execute(
              "UPDATE task_table SET title='SYNTHETIC-WRITE-WOULD-BE-A-FAILURE'",
            );
          }
        }),
        'LOCAL_PROFILE_ADMISSION_BUSY',
      ),
      'capture-lease-refuses-competing-writer',
    );
    check(
      same(before, await sourceEvidence()),
      'competing-writer-touched-no-source-bytes',
    );
    await report('writer-blocked');
    // Keep the WAL connections alive until the Android executor kills the app.
    await waitForMarker('never-release-wal-during-proof');
  }

  Future<void> _seed(LocalDatabaseIdentity id) async {
    final db = await UserDatabaseFactory(
      keyManager: keys,
      directoryProvider: () async => sources,
    ).open(id);
    try {
      await db.transaction(() async {
        await db
            .into(db.taskTable)
            .insert(
              TaskTableCompanion.insert(
                id: _task,
                title: _task,
                priority: 'medium',
                date: DateTime.utc(2026, 11, 20),
              ),
            );
        await db
            .into(db.subjects)
            .insert(
              SubjectsCompanion.insert(
                id: _subject,
                title: _subject,
                cardsToReview: 1,
                streakDays: 2,
                progress: 0.5,
                hasExam: false,
              ),
            );
        await db
            .into(db.flashcards)
            .insert(
              FlashcardsCompanion.insert(
                id: _flashcard,
                subjectId: _subject,
                question: 'synthetic question',
                answer: 'synthetic answer',
              ),
            );
        await db
            .into(db.focusLogs)
            .insert(
              FocusLogsCompanion.insert(
                targetId: _task,
                targetType: 'task',
                durationSeconds: 900,
                timestamp: 1795132800,
              ),
            );
      });
    } finally {
      await db.closeDatabase();
    }
    final key = await keys.getEncryptionKey(id, allowCreate: false);
    final writer = openCopy(id.fileIn(sources), key, queryOnly: false);
    openWriters.add(writer);
    check(
      writer.select('PRAGMA journal_mode=WAL').single.values.single == 'wal',
      '${id.uid}-wal-mode',
    );
    writer.execute('PRAGMA synchronous=FULL');
    writer.execute('PRAGMA wal_autocheckpoint=0');
    check(
      writer.select('PRAGMA wal_checkpoint(TRUNCATE)').single.values.first == 0,
      '${id.uid}-baseline-checkpoint',
    );
    writer.execute('BEGIN IMMEDIATE');
    writer.execute(
      'INSERT INTO sync_queue_table (owner_uid,collection,doc_id,operation_type,payload_json,created_at) VALUES (?,?,?,?,?,?)',
      [id.uid, 'tasks', _walIntent, 'create', '{"synthetic":true}', 100],
    );
    writer.execute('UPDATE flashcards SET last_reviewed=? WHERE id=?', [
      1795132800123,
      _flashcard,
    ]);
    writer.execute('COMMIT');
  }

  Future<void> competingCapture() async {
    await authorize();
    final before = await sourceEvidence();
    check(
      await refuses(
        () => admission().run(() async {
          await marker(
            'unexpected-capture',
          ).writeAsString('invalid', flush: true);
        }),
        'LOCAL_PROFILE_ADMISSION_BUSY',
      ),
      'writer-lease-refuses-competing-capture',
    );
    check(
      !await marker('unexpected-capture').exists(),
      'blocked-capture-created-no-output',
    );
    check(
      same(before, await sourceEvidence()),
      'blocked-capture-touched-no-source-bytes',
    );
  }

  Future<Map<String, Object?>> prepare({required bool resumed}) async {
    await authorize();
    final before = await sourceEvidence();
    final oldAttempt = Directory('${root.path}/attempt-interrupted');
    Map<String, String>? oldHashes;
    if (resumed) {
      check(
        await File('${oldAttempt.path}/staged.json').exists() &&
            !await File('${oldAttempt.path}/ready.json').exists(),
        'interrupted-attempt-unpublished',
      );
      oldHashes = await _treeHashes(oldAttempt);
    }
    final attempt = resumed
        ? Directory('${root.path}/attempt-resumed')
        : oldAttempt;
    if (await attempt.exists()) throw StateError('ATTEMPT_MUST_BE_FRESH');
    await attempt.create();
    final issuer = await issuerKey();
    final sealed = <String, Map<String, String>>{};
    await admission().run(() async {
      if (!resumed) {
        await marker('capture-owns-lease').writeAsString('$pid', flush: true);
        final approval = File('${support.path}/stage19-writer-blocked.json');
        final timer = Stopwatch()..start();
        while (!await approval.exists()) {
          if (timer.elapsed > const Duration(seconds: 30))
            throw StateError('OTHER_WRITER_DID_NOT_REPORT');
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        final writer = jsonDecode(await approval.readAsString()) as Map;
        check(
          writer['pid'] != pid &&
              (writer['checks']
                      as Map)['capture-lease-refuses-competing-writer'] ==
                  true &&
              (writer['checks']
                      as Map)['competing-writer-touched-no-source-bytes'] ==
                  true,
          'independent-writer-refused-while-capture-held',
        );
      }
      for (final entry in identities.entries) {
        final key = await keys.getEncryptionKey(
          entry.value.id,
          allowCreate: false,
        );
        sealed[entry.key] = await sealSource(
          source: sources,
          archive: Directory('${attempt.path}/${entry.key}-sealed'),
          custody: entry.value,
          receipt: jsonDecode(await receipt(entry.key).readAsString()),
          issuerKey: issuer,
          sourceKey: key,
        );
        check(
          sealed[entry.key]!.length == 3,
          '${entry.key}-snapshot-includes-main-wal-shm',
        );
      }
    });
    check(
      same(before, await sourceEvidence()),
      'both-source-families-preserved-after-capture',
    );
    final destinations = <String, Object?>{};
    for (final entry in identities.entries) {
      destinations[entry.key] = await _candidate(
        attempt,
        entry.key,
        entry.value,
        sealed[entry.key]!,
        resumed,
      );
    }
    check(
      same(before, await sourceEvidence()),
      'original-databases-and-custody-preserved-after-comparison',
    );
    if (resumed) {
      await negativeCustody(attempt);
      check(
        same(oldHashes, await _treeHashes(oldAttempt)),
        'interrupted-attempt-never-reused-or-mutated',
      );
      check(
        !await File('${oldAttempt.path}/ready.json').exists(),
        'interrupted-attempt-remains-unpublished',
      );
    }
    final decision = {
      'source': before,
      'destinations': destinations,
      'attempt': attempt.path.split('/').last,
    };
    final staged = File('${attempt.path}/staged.json');
    await staged.writeAsString(jsonEncode(decision), flush: true);
    if (resumed) {
      final ready = File('${attempt.path}/ready.json.tmp');
      await ready.writeAsString(jsonEncode(decision), flush: true);
      await ready.rename('${attempt.path}/ready.json');
    }
    return {
      ...decision,
      'interruptedHashes': oldHashes ?? await _treeHashes(attempt),
    };
  }

  Future<Map<String, Object?>> _candidate(
    Directory attempt,
    String label,
    FixtureCustody custody,
    Map<String, String> hashes,
    bool resumed,
  ) async {
    final originKey = await keys.getEncryptionKey(
      custody.id,
      allowCreate: false,
    );
    final archive = custody.id.fileIn(
      Directory('${attempt.path}/$label-sealed'),
    );
    final mainOnly = await queryCopy(
      archive,
      Directory('${attempt.path}/$label-main-only'),
      includeWal: false,
    );
    final base = openCopy(mainOnly, originKey, queryOnly: true);
    try {
      requireIntegrity(base, AppDatabase.currentSchemaVersion);
      check(
        readRows(base, 'sync_queue_table').rows.isEmpty &&
            base
                    .select('SELECT last_reviewed FROM flashcards')
                    .single
                    .values
                    .single ==
                null,
        '$label-queue-and-review-absent-without-wal',
      );
    } finally {
      base.dispose();
    }
    final capture = await queryCopy(
      archive,
      Directory('${attempt.path}/$label-query'),
      includeWal: true,
    );
    final db = openCopy(capture, originKey, queryOnly: true);
    late final Map<String, EntityRows> entities;
    late final List<List<Object?>> sequence;
    try {
      requireIntegrity(db, AppDatabase.currentSchemaVersion);
      entities = readEntities(db);
      sequence = db
          .select('SELECT name,seq FROM sqlite_sequence ORDER BY name')
          .map((row) => row.values.toList())
          .toList();
      check(entities.length == 17, '$label-legacy-entity-inventory');
      check(
        db.select('SELECT doc_id FROM sync_queue_table').single.values.single ==
                _walIntent &&
            db
                    .select('SELECT last_reviewed FROM flashcards')
                    .single
                    .values
                    .single ==
                1795132800123,
        '$label-commits-recovered-from-wal',
      );
    } finally {
      db.dispose();
    }
    await verifySealed(archive, hashes);
    final local = LocalDatabaseIdentity('local-v1-${const Uuid().v4()}');
    final destDir = Directory('${attempt.path}/$label-destination');
    await destDir.create();
    final file = local.fileIn(destDir);
    final destKey = await DatabaseEncryptionBootstrap().prepare(
      databaseFile: file,
      keyProvider: ({required allowCreate}) =>
          keys.getEncryptionKey(local, allowCreate: allowCreate),
    );
    check(
      destKey != originKey && local.namespace != custody.id.namespace,
      '$label-destination-key-and-namespace-separated',
    );
    final schema = AppDatabase.forUser(
      identity: local,
      executor: NativeDatabase(
        file,
        setup: (db) => DatabaseEncryptionBootstrap.configureEncryptedConnection(
          db,
          destKey,
        ),
      ),
      syncPolicy: DatabaseSyncPolicy.localOnly,
    );
    try {
      await schema.customSelect('SELECT 1').getSingle();
    } finally {
      await schema.closeDatabase();
    }
    final dest = openCopy(file, destKey, queryOnly: false);
    try {
      importCandidate(dest, entities, sequence);
    } finally {
      dest.dispose();
    }
    final validate = openCopy(file, destKey, queryOnly: false);
    try {
      requireIntegrity(validate, AppDatabase.currentLocalSchemaVersion);
      check(
        !DatabaseEncryptionBootstrap.hasPlaintextHeader(file),
        '$label-destination-ciphertext-and-integrity',
      );
      check(
        same(
          entityProof(entities),
          entityProof(comparableDestination(validate)),
        ),
        '$label-all-entity-and-queue-digests-match',
      );
      check(
        same(
          sequence,
          validate
              .select('SELECT name,seq FROM sqlite_sequence ORDER BY name')
              .map((row) => row.values.toList())
              .toList(),
        ),
        '$label-autoincrement-sequences-match',
      );
      check(
        validate
                    .select(
                      'SELECT f.id FROM flashcards f JOIN subjects s ON f.subject_id=s.id WHERE s.id=?',
                      [_subject],
                    )
                    .single
                    .values
                    .single ==
                _flashcard &&
            validate
                    .select('SELECT target_id FROM focus_logs')
                    .single
                    .values
                    .single ==
                _task,
        '$label-relationships-and-focus-history-match',
      );
      check(
        _sqliteDeclines(
          validate,
          'INSERT INTO sync_queue_table SELECT * FROM $historicalQueue',
        ),
        '$label-blocked-queue-replay',
      );
      check(
        _sqliteDeclines(
          validate,
          "UPDATE $historicalQueue SET is_synced=1,status='succeeded'",
        ),
        '$label-blocked-fake-confirmation',
      );
      check(
        _sqliteDeclines(validate, 'DELETE FROM $historicalQueue'),
        '$label-blocked-queue-deletion',
      );
      check(
        same(
          entityProof(entities),
          entityProof(comparableDestination(validate)),
        ),
        '$label-protected-queue-unchanged',
      );
    } finally {
      validate.dispose();
    }
    if (resumed) {
      check(
        _encryptionRejects(file, originKey),
        '$label-destination-refuses-source-key',
      );
      final badSchema = await queryCopy(
        archive,
        Directory('${attempt.path}/$label-bad-schema'),
        includeWal: false,
      );
      final bad = openCopy(badSchema, originKey, queryOnly: false);
      try {
        bad.execute('PRAGMA user_version=10');
        check(
          await refuses(
            () async => requireIntegrity(bad, AppDatabase.currentSchemaVersion),
            'SCHEMA_UNSUPPORTED',
          ),
          '$label-unsupported-schema-refused',
        );
      } finally {
        bad.dispose();
      }
      final inconsistent = await queryCopy(
        archive,
        Directory('${attempt.path}/$label-inconsistent'),
        includeWal: true,
      );
      // This is a disposable query copy. The sealed family is never edited.
      await File('${inconsistent.path}-wal').writeAsString(
        'SYNTHETIC-CHANGED-WAL',
        mode: FileMode.append,
        flush: true,
      );
      await File('${archive.path}-shm').copy('${inconsistent.path}-shm');
      check(
        await refuses(
          () => verifySealed(inconsistent, hashes),
          'SNAPSHOT_HASH_MISMATCH',
        ),
        '$label-inconsistent-family-refused',
      );
      await verifySealed(archive, hashes);
    }
    return {
      'file': '$label-destination/${local.fileName}',
      'databaseHash': await fileDigest(file),
      'keyFingerprint': keyDigest(destKey),
      'entities': entityProof(entities),
    };
  }

  Future<void> negativeCustody(Directory attempt) async {
    final custody = identities['bound']!;
    final key = await keys.getEncryptionKey(custody.id, allowCreate: false);
    final issuer = await issuerKey();
    final fingerprint = keyDigest(key);
    final claims = custody.claims(fingerprint);
    final target = Directory('${attempt.path}/refused-before-capture');
    Future<void> capture(Object? receipt) async {
      await sealSource(
        source: sources,
        archive: target,
        custody: custody,
        receipt: receipt,
        issuerKey: issuer,
        sourceKey: key,
      );
    }

    for (final field in [
      'project',
      'database',
      'tenant',
      'uid',
      'generation',
      'namespace',
      'file',
      'keyFingerprint',
    ]) {
      final wrong = FixtureCustody.issue({
        ...claims,
        field: 'synthetic-other',
      }, issuer);
      check(
        await refuses(() => capture(wrong), 'CUSTODY_CLAIMS_MISMATCH'),
        'refused-divergent-$field',
      );
    }
    final unsigned = {...FixtureCustody.issue(claims, issuer), 'mac': '0' * 64};
    check(
      await refuses(() => capture(unsigned), 'CUSTODY_SIGNATURE_INVALID'),
      'refused-forged-custody',
    );
    final valid = FixtureCustody.issue(claims, issuer);
    check(
      await refuses(() => capture(valid), 'LOCAL_PROFILE_ADMISSION_REQUIRED'),
      'refused-capture-without-current-lease',
    );
    check(
      !await target.exists(),
      'custody-and-lease-refusals-created-no-snapshot',
    );
  }
}

bool _sqliteDeclines(Database db, String statement) {
  try {
    db.execute(statement);
  } on SqliteException catch (error) {
    return error.message.contains('HISTORICAL_QUEUE_FROZEN');
  }
  return false;
}

bool _encryptionRejects(File file, String key) {
  Database? db;
  try {
    db = openCopy(file, key, queryOnly: true);
    db.select('SELECT name FROM sqlite_schema');
    return false;
  } on SqliteException catch (error) {
    return error.resultCode == 26 || error.resultCode == 11;
  } finally {
    db?.dispose();
  }
}

Future<Map<String, String>> _treeHashes(Directory root) async {
  final types = await root.list(recursive: true, followLinks: false).toList();
  final files = types.whereType<File>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  return {
    for (final file in files)
      file.path.substring(root.path.length + 1): await fileDigest(file),
  };
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      home: Scaffold(body: Text('Synthetic UID/P1 custody lab')),
    ),
  );
  final scenario = await fixture.control.invokeMethod<String>('scenario');
  final support = await getApplicationSupportDirectory();
  final lab = _Lab(support, Directory('${support.path}/stage19'));
  try {
    switch (scenario) {
      case 'writer':
        await lab.seedWriter();
      case 'blocked':
        await lab.competingCapture();
        await lab.report('blocked');
      case 'interrupt':
        await lab.report('interrupt', extra: await lab.prepare(resumed: false));
        await lab.waitForMarker('never-publish-interrupted-attempt');
      case 'resume':
        await lab.report('resume', extra: await lab.prepare(resumed: true));
      default:
        throw StateError('UNKNOWN_SCENARIO');
    }
  } on StateError catch (error) {
    await lab.report('$scenario-error', extra: {'fatal': error.message});
  } on SqliteException catch (error) {
    await lab.report(
      '$scenario-error',
      extra: {'fatal': 'SQLITE_${error.extendedResultCode}'},
    );
  } catch (error) {
    await lab.report(
      '$scenario-error',
      extra: {'fatal': error.runtimeType.toString()},
    );
  }
}
