import 'package:drift/drift.dart';

class Goals extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  TextColumn get period => text()();
  IntColumn get currentValue => integer()();
  IntColumn get targetValue => integer()();
  IntColumn get createdAt => integer()(); // Armazenar como Epoch
  IntColumn get lastReset => integer()(); // Armazenar como Epoch

  @override
  Set<Column> get primaryKey => {id};
}
