import 'package:drift/drift.dart';

class TaskTable extends Table {
  TextColumn get id => text()(); // ID do Firestore ou UUID local
  TextColumn get title => text()();
  TextColumn get priority => text()();
  BoolColumn get isCompleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get date => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}
