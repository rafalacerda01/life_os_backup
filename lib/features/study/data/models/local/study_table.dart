import 'package:drift/drift.dart';

// Tabela de Estatísticas Gerais (documento 'main')
class StudyStats extends Table {
  TextColumn get id => text()(); // 'main'
  IntColumn get streak => integer()();
  IntColumn get reviewQueue => integer()();
  RealColumn get progress => real()();
  IntColumn get lastStudyDate => integer().nullable()(); // Timestamp como Epoch

  @override
  Set<Column> get primaryKey => {id};
}

// Tabela de Disciplinas
class Subjects extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  IntColumn get cardsToReview => integer()();
  IntColumn get streakDays => integer()();
  RealColumn get progress => real()();
  BoolColumn get hasExam => boolean()();
  IntColumn get examDate => integer().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

// Tabela de Flashcards
class Flashcards extends Table {
  TextColumn get id => text()();

  // 🚀 Chave estrangeira ligada à tabela Subjects com exclusão em cascata
  TextColumn get subjectId =>
      text().references(Subjects, #id, onDelete: KeyAction.cascade)();

  TextColumn get question => text()();
  TextColumn get answer => text()();

  // 🚀 Novo campo para controlar o agendamento/revisão (armazena timestamp em millisegundos)
  IntColumn get lastReviewed => integer().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}
