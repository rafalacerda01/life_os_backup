import 'package:drift/drift.dart';

class Transactions extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get firestoreId =>
      text().nullable()(); // Salva o UUID definitivo gerado no Flutter
  TextColumn get title => text()();
  RealColumn get amount => real()();
  TextColumn get type => text()(); // 'income' ou 'expense'
  TextColumn get category => text()();
  DateTimeColumn get date => dateTime()();

  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();

  @override
  String get tableName => 'transactions';
}
