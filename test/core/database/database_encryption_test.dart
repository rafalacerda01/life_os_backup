import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/database_encryption.dart';
import 'package:sqlite3/sqlite3.dart';

const _correctKey = 'QmxvY29CLXRlc3Qta2V5LTMyaW5kZXBlbmRlbnQtYnl0ZXM=';
const _wrongKey = 'V3JvbmctQmxvY29CLXRlc3Qta2V5LTMyaW5kZXBlbmRlbnQ=';

void main() {
  late Directory temporaryDirectory;
  late File databaseFile;

  setUp(() {
    temporaryDirectory = Directory.systemTemp.createTempSync(
      'life_os_database_encryption_',
    );
    databaseFile = File('${temporaryDirectory.path}/life_os.sqlite');
  });

  tearDown(() {
    if (temporaryDirectory.existsSync()) {
      temporaryDirectory.deleteSync(recursive: true);
    }
  });

  test(
    'primeira instalação cria banco criptografado e permite a chave correta',
    () async {
      final allowCreateCalls = <bool>[];

      await DatabaseEncryptionBootstrap().prepare(
        databaseFile: databaseFile,
        keyProvider: ({required allowCreate}) async {
          allowCreateCalls.add(allowCreate);
          return _correctKey;
        },
      );

      expect(allowCreateCalls, [true]);
      expect(databaseFile.existsSync(), isTrue);
      expect(
        DatabaseEncryptionBootstrap.hasPlaintextHeader(databaseFile),
        isFalse,
      );

      final database = _openWithKey(databaseFile, _correctKey);
      database.execute('CREATE TABLE proof (value TEXT NOT NULL);');
      database.execute("INSERT INTO proof VALUES ('preserved');");
      database.dispose();

      final reopened = _openWithKey(databaseFile, _correctKey);
      expect(
        reopened.select('SELECT value FROM proof;').single['value'],
        'preserved',
      );
      reopened.dispose();
    },
  );

  test(
    'banco criptografado rejeita ausência de chave e chave errada',
    () async {
      await _createEncryptedDatabase(databaseFile);

      expect(
        () => _readWithoutKey(databaseFile),
        throwsA(isA<SqliteException>()),
      );
      expect(
        () => _readWithWrongKey(databaseFile),
        throwsA(isA<SqliteException>()),
      );

      final database = _openWithKey(databaseFile, _correctKey);
      expect(database.select('PRAGMA quick_check;').single.values.first, 'ok');
      database.dispose();
    },
  );

  test(
    'plaintext v8 migra preservando dados, user_version e SyncQueue',
    () async {
      _createPlaintextVersion8(databaseFile);
      expect(
        DatabaseEncryptionBootstrap.hasPlaintextHeader(databaseFile),
        isTrue,
      );

      final bootstrap = DatabaseEncryptionBootstrap();
      final firstCalls = <bool>[];
      await bootstrap.prepare(
        databaseFile: databaseFile,
        keyProvider: ({required allowCreate}) async {
          firstCalls.add(allowCreate);
          return _correctKey;
        },
      );

      expect(firstCalls, [true]);
      expect(
        DatabaseEncryptionBootstrap.hasPlaintextHeader(databaseFile),
        isFalse,
      );

      var database = _openWithKey(databaseFile, _correctKey);
      expect(database.select('PRAGMA user_version;').single.values.first, 8);
      expect(
        database.select('SELECT value FROM preserved_data;').single['value'],
        'offline-value',
      );
      final queue = database.select('SELECT * FROM sync_queue_table;').single;
      expect(queue['id'], 41);
      expect(queue['owner_uid'], 'user-a');
      expect(queue['doc_id'], 'offline-task');
      expect(queue['payload_json'], '{"title":"Offline"}');
      expect(queue['status'], 'pending');
      database.dispose();

      final secondCalls = <bool>[];
      await bootstrap.prepare(
        databaseFile: databaseFile,
        keyProvider: ({required allowCreate}) async {
          secondCalls.add(allowCreate);
          return _correctKey;
        },
      );

      expect(secondCalls, [false]);
      database = _openWithKey(databaseFile, _correctKey);
      expect(
        database
            .select('SELECT count(*) FROM preserved_data;')
            .single
            .values
            .first,
        1,
      );
      expect(
        database
            .select('SELECT count(*) FROM sync_queue_table;')
            .single
            .values
            .first,
        1,
      );
      database.dispose();
    },
  );

  test('falha durante substituição restaura o plaintext original', () async {
    _createPlaintextVersion8(databaseFile);
    final bootstrap = DatabaseEncryptionBootstrap(
      migrationObserver: (stage) {
        if (stage == DatabaseEncryptionMigrationStage.sourceBackedUp) {
          throw StateError('SIMULATED_MIGRATION_FAILURE');
        }
      },
    );

    await expectLater(
      bootstrap.prepare(
        databaseFile: databaseFile,
        keyProvider: ({required allowCreate}) async => _correctKey,
      ),
      throwsA(isA<StateError>()),
    );

    expect(
      DatabaseEncryptionBootstrap.hasPlaintextHeader(databaseFile),
      isTrue,
    );
    final database = sqlite3.open(databaseFile.path, mode: OpenMode.readOnly);
    expect(
      database.select('SELECT value FROM preserved_data;').single['value'],
      'offline-value',
    );
    database.dispose();
    expect(
      File('${databaseFile.path}.encryption-candidate').existsSync(),
      isFalse,
    );
    expect(File('${databaseFile.path}.plaintext-backup').existsSync(), isFalse);
  });

  test('banco criptografado sem chave falha fechado', () async {
    await _createEncryptedDatabase(databaseFile);
    final allowCreateCalls = <bool>[];

    await expectLater(
      DatabaseEncryptionBootstrap().prepare(
        databaseFile: databaseFile,
        keyProvider: ({required allowCreate}) async {
          allowCreateCalls.add(allowCreate);
          throw StateError('DATABASE_KEY_MISSING');
        },
      ),
      throwsA(isA<StateError>()),
    );

    expect(allowCreateCalls, [false]);
    expect(
      DatabaseEncryptionBootstrap.hasPlaintextHeader(databaseFile),
      isFalse,
    );
    final database = _openWithKey(databaseFile, _correctKey);
    expect(database.select('PRAGMA quick_check;').single.values.first, 'ok');
    database.dispose();
  });
}

Future<void> _createEncryptedDatabase(File file) {
  return DatabaseEncryptionBootstrap().prepare(
    databaseFile: file,
    keyProvider: ({required allowCreate}) async => _correctKey,
  );
}

Database _openWithKey(File file, String key) {
  final database = sqlite3.open(file.path);
  DatabaseEncryptionBootstrap.configureEncryptedConnection(database, key);
  database.select('SELECT count(*) FROM sqlite_master;');
  return database;
}

Never _readWithoutKey(File file) {
  final database = sqlite3.open(file.path, mode: OpenMode.readOnly);

  try {
    database.select('SELECT count(*) FROM sqlite_master;');
    throw StateError('ENCRYPTED_DATABASE_OPENED_WITHOUT_KEY');
  } finally {
    database.dispose();
  }
}

Never _readWithWrongKey(File file) {
  final database = sqlite3.open(file.path, mode: OpenMode.readOnly);

  try {
    DatabaseEncryptionBootstrap.configureEncryptedConnection(
      database,
      _wrongKey,
    );
    database.select('SELECT count(*) FROM sqlite_master;');
    throw StateError('ENCRYPTED_DATABASE_OPENED_WITH_WRONG_KEY');
  } finally {
    database.dispose();
  }
}

void _createPlaintextVersion8(File file) {
  final database = sqlite3.open(file.path);

  try {
    database.execute('PRAGMA journal_mode = WAL;');
    database.execute('CREATE TABLE preserved_data (value TEXT NOT NULL);');
    database.execute("INSERT INTO preserved_data VALUES ('offline-value');");
    database.execute('''
      CREATE TABLE sync_queue_table (
        id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
        owner_uid TEXT,
        collection TEXT NOT NULL,
        doc_id TEXT NOT NULL,
        operation_type TEXT NOT NULL,
        payload_json TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        is_synced INTEGER NOT NULL DEFAULT 0,
        status TEXT NOT NULL DEFAULT 'pending',
        last_error_code TEXT,
        attempt_count INTEGER NOT NULL DEFAULT 0,
        last_attempt_at INTEGER
      );
    ''');
    database.execute('''
      INSERT INTO sync_queue_table (
        id,
        owner_uid,
        collection,
        doc_id,
        operation_type,
        payload_json,
        created_at,
        status
      ) VALUES (
        41,
        'user-a',
        'tasks',
        'offline-task',
        'create',
        '{"title":"Offline"}',
        1,
        'pending'
      );
    ''');
    database.execute('PRAGMA user_version = 8;');
  } finally {
    database.dispose();
  }
}
