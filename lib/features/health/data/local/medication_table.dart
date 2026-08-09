import 'package:drift/drift.dart';

class Medications extends Table {
  /// Identificador local autoincrementável.
  ///
  /// Usado pelo Drift/UI para operações locais.
  IntColumn get id => integer().autoIncrement()();

  /// Identificador definitivo do medicamento no Firebase.
  ///
  /// O HealthRepository gera esse UUID antes de salvar o medicamento
  /// localmente e utiliza o mesmo valor como ID do documento no Firestore.
  ///
  /// Deve ser único para impedir que o mesmo medicamento seja
  /// duplicado durante sincronizações.
  TextColumn get firestoreId => text().unique()();

  /// Nome do medicamento.
  TextColumn get name => text()();

  /// Data/hora de início do medicamento.
  DateTimeColumn get startDate => dateTime()();

  /// Duração do tratamento em dias.
  ///
  /// Null significa que não foi definida uma duração.
  IntColumn get durationDays => integer().nullable()();

  /// Data/hora de término do tratamento.
  ///
  /// Null quando o tratamento não possui data de término.
  DateTimeColumn get endDate => dateTime().nullable()();
}
