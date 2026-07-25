import 'package:drift/drift.dart';

class Habits extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  // SQLite não guarda List<String>, então salvamos como JSON string
  TextColumn get completedDates => text()();

  @override
  Set<Column> get primaryKey => {id};
}
