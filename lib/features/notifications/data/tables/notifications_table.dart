import 'package:drift/drift.dart';

class NotificationsTable extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  TextColumn get description => text()();
  TextColumn get priority =>
      text()(); // 'high', 'today', 'upcoming', 'completed'
  TextColumn get moduleType =>
      text()(); // 'health', 'habits', 'studies', 'finances', 'dashboard'
  TextColumn get route => text()();
  BoolColumn get isRead => boolean().withDefault(const Constant(false))();
  BoolColumn get isCompleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get dueDate => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}
