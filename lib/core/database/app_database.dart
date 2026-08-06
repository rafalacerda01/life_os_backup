import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
// 🚀 NOTIFICATIONS CENTER: Imports mantidos
import '../../features/notifications/data/tables/notifications_table.dart';
import '../../features/notifications/data/daos/notification_dao.dart';
import 'package:life_os/features/finance/data/local/transaction_table.dart';
import 'package:life_os/features/health/data/local/health_table.dart';
import 'package:life_os/features/health/data/local/medication_table.dart';
import 'package:life_os/features/habits/data/models/local/habit_table.dart';
import 'package:life_os/features/tasks/data/models/local/task_table.dart';
import 'package:life_os/features/study/data/models/local/study_table.dart';
import 'package:life_os/features/goals/data/models/local/goals_table.dart';
import 'package:life_os/features/checkin/data/local/checkin_table.dart';
import '../db/db_key_manager.dart';

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
    NotificationsTable, // 🚀 NOTIFICATIONS CENTER: Tabela adicionada
  ],
  daos: [
    NotificationDao, // 🚀 NOTIFICATIONS CENTER: DAO adicionado
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase({QueryExecutor? executor}) : super(executor ?? _openConnection());

  @override
  int get schemaVersion => 6; // 🚀 NOTIFICATIONS CENTER: Subido para 6

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
    },
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        await m.createTable(focusLogs);
      }
      if (from < 3) {
        await m.addColumn(flashcards, flashcards.subjectId);
      }
      if (from < 4) {
        await m.addColumn(flashcards, flashcards.lastReviewed);
      }
      if (from < 5) {
        await m.createTable(checkInTable);
      }
      if (from < 6) {
        // 🚀 NOTIFICATIONS CENTER: Migração para criar a tabela de notificações
        await m.createTable(notificationsTable);
      }
    },
  );

  // ===========================================================================
  // QUERIES PARA O MÓDULO DE CHECK-IN (OFFLINE-FIRST)
  // ===========================================================================

  /// Observa todos os check-ins em tempo real (A UI vai consumir isso)
  Stream<List<CheckInEntry>> watchAllCheckIns() {
    return (select(checkInTable)..orderBy([
          (t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
        ]))
        .watch();
  }

  /// Insere um novo Check-in localmente
  Future<void> insertCheckIn(CheckInTableCompanion entry) {
    return into(checkInTable).insert(entry, mode: InsertMode.replace);
  }

  /// Busca apenas os check-ins que ainda não foram para a nuvem
  Future<List<CheckInEntry>> getPendingCheckIns() {
    return (select(checkInTable)..where((t) => t.isSynced.equals(false))).get();
  }

  /// Marca um check-in específico como sincronizado após sucesso no Firebase
  Future<void> markCheckInAsSynced(String id) {
    return (update(checkInTable)..where((t) => t.id.equals(id))).write(
      const CheckInTableCompanion(isSynced: Value(true)),
    );
  }

  // ===========================================================================
  // POLÍTICA DE LOGOUT E LIMPEZA DE DADOS
  // ===========================================================================

  /// 🚀 Limpa todos os dados de todas as tabelas (Usado no Logout)
  Future<void> clearAllData() async {
    await customStatement('PRAGMA foreign_keys = OFF');
    try {
      await transaction(() async {
        for (final table in allTables) {
          await delete(table).go();
        }
      });
    } finally {
      await customStatement('PRAGMA foreign_keys = ON');
    }
  }
}

// Definição da tabela FocusLogs
class FocusLogs extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get targetId => text()();
  TextColumn get targetType => text()();
  IntColumn get durationSeconds => integer()();
  IntColumn get timestamp => integer()();
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dbFolder = await getApplicationDocumentsDirectory();
    final file = File(p.join(dbFolder.path, 'life_os.sqlite'));
    final key = await DbKeyManager.getEncryptionKey();
    final sanitizedKey = key.replaceAll("'", "''");

    return NativeDatabase.createInBackground(
      file,
      setup: (database) {
        database.execute("PRAGMA key = '$sanitizedKey';");
        database.execute("PRAGMA cipher_page_size = 4096;");
        database.execute("PRAGMA journal_mode = WAL;");
        database.execute("PRAGMA synchronous = NORMAL;");
        database.execute("PRAGMA foreign_keys = ON;");
      },
    );
  });
}
