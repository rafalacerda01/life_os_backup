import 'package:drift/drift.dart';


@DataClassName('HealthEntry')
class HealthEntries extends Table {
  TextColumn get docId => text()(); // O ID da data (ex: '2026-07-08')
  TextColumn get mood => text().withDefault(const Constant('—'))();
  IntColumn get waterIntakeMl => integer().withDefault(const Constant(0))();
  BoolColumn get hasTakenPillToday => boolean().withDefault(const Constant(false))();
  
  // Para armazenar JSON complexo (como o ciclo menstrual), usamos o tipo Text
  // e depois convertemos para mapa no código.
  TextColumn get menstrualCycleJson => text().nullable()();
  
  DateTimeColumn get date => dateTime()();

  @override
  Set<Column> get primaryKey => {docId};
}