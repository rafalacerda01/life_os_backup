import 'package:drift/drift.dart';

class Medications extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get firestoreId => text().nullable()(); // Importante para saber qual documento no Firebase é esse
  TextColumn get name => text()();
  DateTimeColumn get startDate => dateTime()();
  IntColumn get durationDays => integer().nullable()();
  DateTimeColumn get endDate => dateTime().nullable()();
}