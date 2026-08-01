import 'package:drift/drift.dart';

@TableIndex(name: 'idx_checkin_created_at', columns: {#createdAt})
@TableIndex(name: 'idx_checkin_is_synced', columns: {#isSynced})
@DataClassName('CheckInEntry')
class CheckInTable extends Table {
  // Usamos TextColumn para suportar o formato UUID v4 e manter compatibilidade com o Firestore
  TextColumn get id => text()();

  RealColumn get energy => real()();
  RealColumn get focus => real()();
  RealColumn get motivation => real()();

  DateTimeColumn get createdAt => dateTime()();

  // A flag fundamental para o modo Offline-First
  BoolColumn get isSynced => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}
