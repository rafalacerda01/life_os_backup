import 'dart:io';
import 'dart:async';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:life_os/core/database/database_encryption.dart';
import 'package:life_os/core/database/local_mutation_gate.dart';
import 'package:life_os/core/database/local_database_identity.dart';
import 'database_sync_policy.dart';
import 'package:life_os/core/db/db_key_manager.dart';
import 'package:life_os/features/checkin/data/local/checkin_table.dart';
import 'package:life_os/features/finance/data/local/transaction_table.dart';
import 'package:life_os/features/goals/data/models/local/goals_table.dart';
import 'package:life_os/features/habits/data/models/local/habit_table.dart';
import 'package:life_os/features/health/data/local/health_table.dart';
import 'package:life_os/features/health/data/local/water_v2_tables.dart';
import 'package:life_os/features/health/data/local/medication_table.dart';
import 'package:life_os/features/study/data/models/local/study_table.dart';
import 'package:life_os/features/tasks/data/models/local/task_table.dart';
import 'package:life_os/features/notifications/data/daos/notification_dao.dart';
import 'package:life_os/features/notifications/data/tables/notifications_table.dart';
import 'package:life_os/features/notifications/data/tables/notification_dismissals.dart';

part 'app_database.g.dart';

@DriftDatabase(
  tables: [
    HealthEntries,
    Medications,
    Transactions,
    TaskTable,
    Habits,
    StudyStats,
    Subjects,
    Flashcards,
    Goals,
    FocusLogs,
    CheckInTable,
    NotificationsTable,
    NotificationDismissals,
    SyncQueueTable,
    WaterV2DailyStates,
    WaterV2Intents,
    WaterV2Preferences,
  ],
  daos: [NotificationDao],
)
class AppDatabase extends _$AppDatabase {
  /// Permite injetar um executor, principalmente para testes.
  AppDatabase({QueryExecutor? executor})
    : this._(
        executor ?? _openConnection(),
        LocalMutationGate(),
        null,
        DatabaseSyncPolicy.remoteEnabled,
      );

  AppDatabase.forUser({
    required LocalDatabaseIdentity identity,
    required QueryExecutor executor,
    DatabaseSyncPolicy syncPolicy = DatabaseSyncPolicy.remoteEnabled,
  }) : this._(
         executor,
         _mutationGateFor(identity, syncPolicy),
         identity,
         syncPolicy,
       );

  static LocalMutationGate _mutationGateFor(
    LocalDatabaseIdentity identity,
    DatabaseSyncPolicy policy,
  ) {
    if (policy == DatabaseSyncPolicy.localOnly &&
        !identity.isLocalInstallation) {
      throw ArgumentError('LOCAL_PROFILE_IDENTITY_REQUIRED');
    }
    return LocalMutationGate(
      ownerUid: identity.uid,
      allowRemoteSends: policy == DatabaseSyncPolicy.remoteEnabled,
    );
  }

  AppDatabase._(
    QueryExecutor executor,
    this.localMutations,
    this.identity,
    this.syncPolicy,
  ) : super(
        executor
            .interceptWith(LocalMutationInterceptor(localMutations))
            .interceptWith(_TransactionCommitGuardInterceptor()),
      );

  final LocalMutationGate localMutations;
  final LocalDatabaseIdentity? identity;
  final DatabaseSyncPolicy syncPolicy;
  bool get isLocalOnly => syncPolicy == DatabaseSyncPolicy.localOnly;

  @override
  Future<T> transaction<T>(
    Future<T> Function() action, {
    bool requireNew = false,
    LocalMutationTicket? admission,
    bool waitForReopen = true,
  }) => localMutations.run(
    () => _withCommitGuards(
      () => super.transaction(action, requireNew: requireNew),
    ),
    ticket: admission,
    waitForReopen: waitForReopen,
  );

  /// Water ACKs retain remote admission until the outermost SQL commit,
  /// including when called within an existing transaction.
  Future<T> transactionWithCommitGuard<T>(
    Future<T> Function() action, {
    required LocalMutationTicket admission,
    required void Function() validateBeforeCommit,
    bool waitForReopen = false,
  }) => localMutations.run(
    () => _withCommitGuards(
      () => super.transaction(action),
      validateBeforeCommit: validateBeforeCommit,
    ),
    ticket: admission,
    waitForReopen: waitForReopen,
  );

  Future<T> _withCommitGuards<T>(
    Future<T> Function() action, {
    void Function()? validateBeforeCommit,
  }) {
    final inherited =
        Zone.current[_commitGuardKey] as _TransactionCommitGuards?;
    final guards = inherited?.database == this
        ? inherited!
        : _TransactionCommitGuards(this);
    if (validateBeforeCommit != null)
      guards.validators.add(validateBeforeCommit);
    if (identical(guards, inherited)) return action();
    return runZoned(action, zoneValues: {_commitGuardKey: guards});
  }

  static final Object _commitGuardKey = Object();

  // =========================================================================
  // CONFIGURAÇÃO DO SCHEMA
  // =========================================================================

  @override
  int get schemaVersion => currentSchemaVersion;

  static const currentSchemaVersion = 11;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (Migrator migrator) async {
      await migrator.createAll();
    },
    onUpgrade: (Migrator migrator, int from, int to) async {
      // A local-only connection never silently upgrades an imported database.
      // A separately qualified migration must authorize any existing schema.
      if (isLocalOnly)
        throw StateError('LOCAL_PROFILE_SCHEMA_MIGRATION_REQUIRED');
      // -----------------------------------------------------------------
      // V1 -> V2
      // -----------------------------------------------------------------
      if (from < 2) {
        await migrator.createTable(focusLogs);
      }

      // -----------------------------------------------------------------
      // V2 -> V3
      // -----------------------------------------------------------------
      if (from < 3) {
        await migrator.addColumn(flashcards, flashcards.subjectId);
      }

      // -----------------------------------------------------------------
      // V3 -> V4
      // -----------------------------------------------------------------
      if (from < 4) {
        await migrator.addColumn(flashcards, flashcards.lastReviewed);
      }

      // -----------------------------------------------------------------
      // V4 -> V5
      // -----------------------------------------------------------------
      if (from < 5) {
        await migrator.createTable(checkInTable);
      }

      // -----------------------------------------------------------------
      // V5 -> V6
      // -----------------------------------------------------------------
      if (from < 6) {
        await migrator.createTable(notificationsTable);
      }

      // -----------------------------------------------------------------
      // V6 -> V7
      // -----------------------------------------------------------------
      if (from < 7) {
        await migrator.createTable(syncQueueTable);
      } else if (from < 8) {
        // ---------------------------------------------------------------
        // V7 -> V8
        // ---------------------------------------------------------------
        await migrator.addColumn(syncQueueTable, syncQueueTable.ownerUid);
        await migrator.addColumn(syncQueueTable, syncQueueTable.status);
        await migrator.addColumn(syncQueueTable, syncQueueTable.lastErrorCode);
        await migrator.addColumn(syncQueueTable, syncQueueTable.attemptCount);
        await migrator.addColumn(syncQueueTable, syncQueueTable.lastAttemptAt);

        // Linhas legadas sem ownership permanecem em quarentena. Somente o
        // estado das operações já confirmadas pode ser inferido com segurança.
        await customStatement(
          "UPDATE sync_queue_table SET status = 'succeeded' "
          'WHERE is_synced = 1',
        );
      }
      if (from < 9) {
        // Pre-v6 databases receive this column with createTable above.
        if (from >= 6 &&
            (await customSelect(
              "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'notifications_table'",
            ).get()).isNotEmpty) {
          await migrator.addColumn(
            notificationsTable,
            notificationsTable.occurrenceKey,
          );
        }
        await migrator.createTable(notificationDismissals);
      }
      if (from < 10) {
        // Additive only: never derive V2 state or deltas from V1 absolutes.
        await transaction(() async {
          await migrator.createTable(waterV2DailyStates);
          await migrator.createTable(waterV2Intents);
        });
      }
      if (from < 11) await migrator.createTable(waterV2Preferences);
    },
    beforeOpen: (_) async {
      if (!isLocalOnly) return;
      // Per-connection SQLite enforcement also covers DAOs, raw SQL and batches.
      // Historical queue rows remain readable but cannot be changed or removed.
      // TEMP triggers do not modify the persisted schema or database version.
      for (final event in ['INSERT', 'UPDATE', 'DELETE']) {
        await customStatement(
          'CREATE TEMP TRIGGER IF NOT EXISTS life_os_local_queue_${event.toLowerCase()} '
          'BEFORE $event ON main.sync_queue_table BEGIN '
          "SELECT RAISE(ABORT, '${LocalRemoteSyncDisabled.code}'); END",
        );
      }
    },
  );

  // =========================================================================
  // CHECK-IN — OFFLINE FIRST
  // =========================================================================

  /// Observa todos os check-ins em tempo real.
  ///
  /// Os registros mais recentes aparecem primeiro.
  Stream<List> watchAllCheckIns() {
    return (select(checkInTable)..orderBy([
          (table) => OrderingTerm(
            expression: table.createdAt,
            mode: OrderingMode.desc,
          ),
        ]))
        .watch();
  }

  /// Insere um check-in localmente.
  ///
  /// O comportamento REPLACE é preservado porque o projeto
  /// utiliza o identificador do check-in como chave lógica.
  Future<int> insertCheckIn(CheckInTableCompanion entry) => localMutations.run(
    () => into(checkInTable).insert(entry, mode: InsertMode.replace),
  );

  /// Retorna somente os check-ins ainda não sincronizados.
  Future<List> getPendingCheckIns() {
    return (select(
      checkInTable,
    )..where((table) => table.isSynced.equals(false))).get();
  }

  /// Marca um check-in como sincronizado.
  Future<int> markCheckInAsSynced(String id, {String? ownerUid}) {
    final cleanId = id.trim();

    if (cleanId.isEmpty) {
      return Future.value(0);
    }

    return localMutations.systemWrite(
      ownerUid,
      () => (update(checkInTable)..where((table) => table.id.equals(cleanId)))
          .write(const CheckInTableCompanion(isSynced: Value(true))),
    );
  }

  // =========================================================================
  // SYNC QUEUE — OFFLINE FIRST
  // =========================================================================

  /// Insere uma operação na fila de sincronização.
  ///
  /// Esta operação deve acontecer junto da alteração local sempre que
  /// possível, preferencialmente dentro da mesma transaction.
  ///
  /// Exemplo:
  ///
  /// Local:
  ///   medication criado
  ///
  /// Queue:
  ///   CREATE / medications / abc123
  Future<int> insertSyncItem({
    required String ownerUid,
    required String collection,
    required String docId,
    required String operationType,
    required String payloadJson,
    int? createdAt,
  }) async {
    if (isLocalOnly) throw const LocalRemoteSyncDisabled();
    final cleanOwnerUid = ownerUid.trim();
    final cleanCollection = collection.trim();
    final cleanDocId = docId.trim();
    final cleanOperationType = operationType.trim();
    final cleanPayload = payloadJson.trim();

    if (cleanOwnerUid.isEmpty) {
      throw ArgumentError('O ownerUid da sincronização não pode estar vazio.');
    }

    if (cleanCollection.isEmpty) {
      throw ArgumentError(
        'A collection da sincronização não pode estar vazia.',
      );
    }

    if (cleanDocId.isEmpty) {
      throw ArgumentError('O docId da sincronização não pode estar vazio.');
    }

    if (cleanOperationType.isEmpty) {
      throw ArgumentError(
        'O operationType da sincronização não pode estar vazio.',
      );
    }

    if (cleanPayload.isEmpty) {
      throw ArgumentError('O payload da sincronização não pode estar vazio.');
    }

    final timestamp = createdAt ?? DateTime.now().millisecondsSinceEpoch;

    if (timestamp <= 0) {
      throw ArgumentError('O timestamp da sincronização é inválido.');
    }

    return into(syncQueueTable).insert(
      SyncQueueTableCompanion.insert(
        ownerUid: Value(cleanOwnerUid),
        collection: cleanCollection,
        docId: cleanDocId,
        operationType: cleanOperationType,
        payloadJson: cleanPayload,
        createdAt: timestamp,
      ),
    );
  }

  /// Retorna todas as operações ainda pendentes.
  ///
  /// A ordem FIFO é preservada pelo ID autoincremental.
  Future<List> getPendingSyncItems(String ownerUid) {
    final cleanOwnerUid = ownerUid.trim();

    if (cleanOwnerUid.isEmpty) {
      return Future.value(const []);
    }

    return (select(syncQueueTable)
          ..where(
            (table) =>
                table.ownerUid.equals(cleanOwnerUid) &
                table.status.equals(SyncQueuePersistenceStatus.pending),
          )
          ..orderBy([
            (table) =>
                OrderingTerm(expression: table.id, mode: OrderingMode.asc),
          ]))
        .get();
  }

  Future<bool> hasRejectedSyncItems(String ownerUid) async {
    final cleanOwnerUid = ownerUid.trim();
    if (cleanOwnerUid.isEmpty) return false;

    final item =
        await (select(syncQueueTable)
              ..where(
                (table) =>
                    table.ownerUid.equals(cleanOwnerUid) &
                    table.status.equals(SyncQueuePersistenceStatus.rejected),
              )
              ..limit(1))
            .getSingleOrNull();
    return item != null;
  }

  /// Retorna somente uma operação pendente específica.
  Future<dynamic> getSyncItemById(int id) {
    if (id <= 0) {
      return Future.value(null);
    }

    return (select(
      syncQueueTable,
    )..where((table) => table.id.equals(id))).getSingleOrNull();
  }

  Future<int> markSyncItemAsSucceeded(int id, String ownerUid) {
    return localMutations.systemWrite(
      ownerUid,
      () => _updateSyncItemState(
        id: id,
        ownerUid: ownerUid,
        status: SyncQueuePersistenceStatus.succeeded,
        isSynced: true,
      ),
    );
  }

  Future<int> markSyncItemRetryableFailure(
    int id,
    String ownerUid,
    String errorCode,
  ) {
    return localMutations.systemWrite(
      ownerUid,
      () => _updateSyncItemState(
        id: id,
        ownerUid: ownerUid,
        status: SyncQueuePersistenceStatus.pending,
        isSynced: false,
        errorCode: errorCode,
      ),
    );
  }

  Future<int> markSyncItemRejected(int id, String ownerUid, String errorCode) {
    return localMutations.systemWrite(
      ownerUid,
      () => _updateSyncItemState(
        id: id,
        ownerUid: ownerUid,
        status: SyncQueuePersistenceStatus.rejected,
        isSynced: false,
        errorCode: errorCode,
      ),
    );
  }

  Future<int> _updateSyncItemState({
    required int id,
    required String ownerUid,
    required String status,
    required bool isSynced,
    String? errorCode,
  }) async {
    final cleanOwnerUid = ownerUid.trim();

    if (id <= 0 || cleanOwnerUid.isEmpty) {
      return 0;
    }

    final item =
        await (select(syncQueueTable)..where(
              (table) =>
                  table.id.equals(id) & table.ownerUid.equals(cleanOwnerUid),
            ))
            .getSingleOrNull();

    if (item == null) {
      return 0;
    }

    final cleanErrorCode = _sanitizeSyncErrorCode(errorCode);

    return (update(syncQueueTable)..where(
          (table) => table.id.equals(id) & table.ownerUid.equals(cleanOwnerUid),
        ))
        .write(
          SyncQueueTableCompanion(
            status: Value(status),
            isSynced: Value(isSynced),
            lastErrorCode: Value(cleanErrorCode),
            attemptCount: Value(item.attemptCount + 1),
            lastAttemptAt: Value(DateTime.now().millisecondsSinceEpoch),
          ),
        );
  }

  /// Remove definitivamente uma operação já processada.
  ///
  /// Deve ser chamada somente depois de uma sincronização confirmada.
  Future<int> deleteSyncItem(int id) {
    if (id <= 0) {
      return Future.value(0);
    }

    return (delete(syncQueueTable)..where((table) => table.id.equals(id))).go();
  }

  /// Remove sucessos antigos do owner, preservando rejeições não resolvidas.
  Future<int> cleanupSucceededSyncItems(String ownerUid, int olderThanEpochMs) {
    final cleanOwnerUid = ownerUid.trim();
    if (cleanOwnerUid.isEmpty) return Future.value(0);

    return localMutations.systemWrite(
      ownerUid,
      () =>
          (delete(syncQueueTable)..where((table) {
                // Match Dart trim, including runtime-dependent U+0085, without
                // rewriting stored bytes. SQLite's default trim only strips spaces.
                final trimCharacters =
                    '\u0009\u000a\u000b\u000c\u000d\u0020\u0085\u00a0\u1680'
                            '\u180e\u2000\u2001\u2002\u2003\u2004\u2005\u2006\u2007'
                            '\u2008\u2009\u200a\u2028\u2029\u202f\u205f\u3000\ufeff'
                        .split('')
                        .where((character) => character.trim().isEmpty)
                        .join();
                Expression<String> normalizedTrim(Expression<String> value) =>
                    FunctionCallExpression<String>('trim', [
                      value,
                      Variable<String>(trimCharacters),
                    ]);
                final preservedStudyInfo =
                    normalizedTrim(table.collection).equals('study_info') &
                    normalizedTrim(table.docId).equals('main') &
                    normalizedTrim(
                      table.operationType,
                    ).lower().isIn(const ['create', 'update']);
                // Revisit only under a separately authorized disposition protocol.
                return table.ownerUid.equals(cleanOwnerUid) &
                    preservedStudyInfo.not() &
                    table.status.equals(SyncQueuePersistenceStatus.succeeded) &
                    // Preserve historical Health payloads until reviewed cleanup.
                    // Do not infer safe deletion from a legacy absolute or status.
                    table.collection.equals('health_info').not() &
                    (table.lastAttemptAt.isSmallerThanValue(olderThanEpochMs) |
                        (table.lastAttemptAt.isNull() &
                            table.createdAt.isSmallerThanValue(
                              olderThanEpochMs,
                            )));
              }))
              .go(),
    );
  }

  /// Remove todas as operações de sincronização de um documento.
  ///
  /// Útil quando uma operação posterior torna operações anteriores
  /// obsoletas.
  ///
  /// Exemplo:
  ///
  /// CREATE medicamento
  /// UPDATE medicamento
  /// DELETE medicamento
  ///
  /// O SyncManager pode decidir consolidar as operações antes
  /// do envio ao Firebase.
  Future<int> deleteSyncItemsForDocument({
    required String ownerUid,
    required String collection,
    required String docId,
  }) {
    final cleanOwnerUid = ownerUid.trim();
    final cleanCollection = collection.trim();
    final cleanDocId = docId.trim();

    if (cleanOwnerUid.isEmpty ||
        cleanCollection.isEmpty ||
        cleanDocId.isEmpty) {
      return Future.value(0);
    }

    return (delete(syncQueueTable)..where(
          (table) =>
              table.ownerUid.equals(cleanOwnerUid) &
              table.collection.equals(cleanCollection) &
              table.docId.equals(cleanDocId) &
              table.status.equals(SyncQueuePersistenceStatus.pending),
        ))
        .go();
  }

  /// Executa uma operação local + registro na fila de sincronização
  /// dentro da mesma transaction.
  ///
  /// Isso evita este estado inconsistente:
  ///
  ///   Drift atualizado
  ///   ↓
  ///   aplicativo fecha
  ///   ↓
  ///   operação nunca entrou na fila
  ///
  /// O callback recebe a transação atual e deve realizar a alteração
  /// local antes de inserir a operação de sync.
  Future<T> transactionWithSync<T>({
    required Future<T> Function() localOperation,
    required String ownerUid,
    required String collection,
    required String docId,
    required String operationType,
    required String payloadJson,
    LocalMutationTicket? admission,
  }) async {
    if (isLocalOnly) {
      if (ownerUid != identity!.uid) throw const LocalMutationUnavailable();
      return transaction(
        localOperation,
        admission: admission ?? localMutations.capture(expectedUid: ownerUid),
      );
    }
    final cleanOwnerUid = ownerUid.trim();
    final cleanCollection = collection.trim();
    final cleanDocId = docId.trim();
    final cleanOperationType = operationType.trim();
    final cleanPayload = payloadJson.trim();

    if (cleanOwnerUid.isEmpty) {
      throw ArgumentError('O ownerUid da sincronização não pode estar vazio.');
    }

    if (cleanCollection.isEmpty) {
      throw ArgumentError(
        'A collection da sincronização não pode estar vazia.',
      );
    }

    if (cleanDocId.isEmpty) {
      throw ArgumentError('O docId da sincronização não pode estar vazio.');
    }

    if (cleanOperationType.isEmpty) {
      throw ArgumentError(
        'O operationType da sincronização não pode estar vazio.',
      );
    }

    if (cleanPayload.isEmpty) {
      throw ArgumentError('O payload da sincronização não pode estar vazio.');
    }

    return transaction<T>(
      () async {
        // O Drift executa todo o callback dentro da transação.
        //
        // Nas versões atuais do Drift utilizadas pelo projeto,
        // transaction() não fornece um objeto Transaction ao callback.
        //
        // Portanto a operação local deve ser executada diretamente.
        final result = await localOperation();

        await into(syncQueueTable).insert(
          SyncQueueTableCompanion.insert(
            ownerUid: Value(cleanOwnerUid),
            collection: cleanCollection,
            docId: cleanDocId,
            operationType: cleanOperationType,
            payloadJson: cleanPayload,
            createdAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );

        return result;
      },
      admission:
          admission ?? localMutations.capture(expectedUid: cleanOwnerUid),
    );
  }

  // =========================================================================
  // LIMPEZA COMPLETA DO BANCO
  // =========================================================================

  /// Remove os dados locais de todas as tabelas.
  ///
  /// Utilizado principalmente durante logout ou troca de conta.
  ///
  /// IMPORTANTE:
  /// Esta operação é destrutiva e NÃO deve ser chamada durante
  /// um simples refresh de sessão.
  Future<void> clearAllData() async {
    await localMutations.cleanupWrite(
      () => exclusively(() async {
        try {
          // Keep the security cleanup commit durable without changing normal use.
          await customStatement('PRAGMA synchronous = FULL');
          try {
            // SQLite only applies foreign_keys changes outside a transaction.
            await customStatement('PRAGMA foreign_keys = OFF');
            await transaction(() async {
              for (final table in allTables) {
                await delete(table).go();
              }
            });
          } finally {
            await customStatement('PRAGMA foreign_keys = ON');
          }
        } finally {
          await customStatement('PRAGMA synchronous = NORMAL');
        }
      }),
    );
  }

  // =========================================================================
  // FECHAMENTO DO BANCO
  // =========================================================================

  /// Fecha corretamente a conexão com o banco.
  ///
  /// Útil em testes, logout completo ou encerramento controlado.
  Future<void> closeDatabase() async {
    await close();
  }
}

// =============================================================================
// TABELA DE LOGS DE FOCO
// =============================================================================
//
// Esta tabela é mantida aqui porque faz parte do schema principal do Drift.
//
// =============================================================================

class FocusLogs extends Table {
  /// ID local autoincremental.
  IntColumn get id => integer().autoIncrement()();

  /// ID da entidade relacionada ao foco.
  TextColumn get targetId => text()();

  /// Tipo da entidade relacionada.
  ///
  /// Exemplos:
  /// - task
  /// - habit
  /// - study
  /// - goal
  TextColumn get targetType => text()();

  /// Duração da sessão em segundos.
  IntColumn get durationSeconds => integer()();

  /// Timestamp Unix da sessão.
  IntColumn get timestamp => integer()();
}

// =============================================================================
// FILA GLOBAL DE SINCRONIZAÇÃO
// =============================================================================
//
// Esta tabela representa operações locais que ainda precisam chegar
// ao Firebase.
//
// Fluxo:
//
//   UI
//    ↓
//   Drift
//    ↓
//   SyncQueue
//    ↓
//   SyncManager
//    ↓
//   Firebase
//
// =============================================================================

class SyncQueueTable extends Table {
  /// ID local da operação de sincronização.
  ///
  /// Autoincremental para preservar a ordem FIFO.
  IntColumn get id => integer().autoIncrement()();

  /// UID autenticado que originou a operação.
  ///
  /// Nullable somente para preservar e quarentenar linhas legadas, cujo
  /// ownership não pode ser inferido de forma segura durante a migração.
  TextColumn get ownerUid => text().nullable()();

  /// Coleção lógica do Firebase.
  ///
  /// Exemplos:
  /// - medications
  /// - health_info
  /// - transactions
  /// - habits
  TextColumn get collection => text()();

  /// ID do documento no Firebase.
  TextColumn get docId => text()();

  /// Tipo da operação.
  ///
  /// Valores esperados:
  /// - create
  /// - update
  /// - delete
  TextColumn get operationType => text()();

  /// Dados necessários para executar a operação.
  ///
  /// Deve ser JSON válido.
  TextColumn get payloadJson => text()();

  /// Timestamp Unix em milissegundos.
  ///
  /// Utilizado para ordenação e auditoria.
  IntColumn get createdAt => integer()();

  /// Indica se a operação já foi processada com sucesso.
  BoolColumn get isSynced => boolean().withDefault(const Constant(false))();

  /// Estado persistente da entrega remota.
  TextColumn get status =>
      text().withDefault(const Constant(SyncQueuePersistenceStatus.pending))();

  /// Código estável da última falha, sem mensagem ou payload sensível.
  TextColumn get lastErrorCode => text().nullable()();

  /// Quantidade de tentativas remotas realizadas.
  IntColumn get attemptCount => integer().withDefault(const Constant(0))();

  /// Timestamp Unix da última tentativa, em milissegundos.
  IntColumn get lastAttemptAt => integer().nullable()();
}

abstract final class SyncQueuePersistenceStatus {
  static const String pending = 'pending';
  static const String succeeded = 'succeeded';
  static const String rejected = 'rejected';
}

String? _sanitizeSyncErrorCode(String? value) {
  final code = value?.trim().toUpperCase();

  if (code == null || code.isEmpty) {
    return null;
  }

  final sanitized = code.replaceAll(RegExp(r'[^A-Z0-9_-]'), '_');
  return sanitized.length <= 80 ? sanitized : sanitized.substring(0, 80);
}

// =============================================================================
// ABERTURA DO BANCO
// =============================================================================

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dbFolder = await getApplicationDocumentsDirectory();

    final file = File(p.join(dbFolder.path, 'life_os.sqlite'));

    final key = await DatabaseEncryptionBootstrap().prepare(
      databaseFile: file,
      keyProvider: ({required allowCreate}) =>
          DbKeyManager.getEncryptionKey(allowCreate: allowCreate),
    );

    return NativeDatabase.createInBackground(
      file,
      setup: (database) {
        DatabaseEncryptionBootstrap.configureEncryptedConnection(database, key);

        // -------------------------------------------------------------------
        // Configurações do SQLite
        // -------------------------------------------------------------------

        database.execute('PRAGMA journal_mode = WAL;');

        database.execute('PRAGMA synchronous = NORMAL;');

        database.execute('PRAGMA foreign_keys = ON;');
      },
    );
  });
}

/// Optional synchronous guard at the actual transaction commit boundary.
/// Existing callers have no guard and retain the original gate behavior.
class _TransactionCommitGuardInterceptor extends QueryInterceptor {
  @override
  Future<void> commitTransaction(TransactionExecutor inner) {
    (Zone.current[AppDatabase._commitGuardKey] as _TransactionCommitGuards?)
        ?.validate();
    return super.commitTransaction(inner);
  }
}

class _TransactionCommitGuards {
  _TransactionCommitGuards(this.database);
  final AppDatabase database;
  final validators = <void Function()>[];
  void validate() {
    for (final validator in validators) {
      validator();
    }
  }
}
