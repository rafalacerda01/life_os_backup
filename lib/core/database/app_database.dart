import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import 'package:life_os/features/finance/data/local/transaction_table.dart';
import 'package:life_os/features/health/data/local/health_table.dart';
import 'package:life_os/features/health/data/local/medication_table.dart';
import 'package:life_os/features/habits/data/models/local/habit_table.dart';
import 'package:life_os/features/tasks/data/models/local/task_table.dart';
import 'package:life_os/features/study/data/models/local/study_table.dart';
import 'package:life_os/features/goals/data/models/local/goals_table.dart';
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
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  @override
  int get schemaVersion => 4; // 🚀 Subido para 4 para forçar a adição da coluna faltante

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
        // 🚀 Adiciona a coluna last_reviewed em bancos que já estavam na versão 3 ou inferior
        await m.addColumn(flashcards, flashcards.lastReviewed);
      }
    },
  );
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
        database.execute("PRAGMA journal_mode = WAL;");
        database.execute("PRAGMA foreign_keys = ON;");
      },
    );
  });
}
