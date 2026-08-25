import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/features/study/presentation/study_screen.dart';

void main() {
  test('prova marcada sem data retorna validação amigável', () {
    expect(
      validateSubjectExamDate(hasExam: true, examDate: null),
      'Selecione a data da prova.',
    );
  });

  test('disciplina sem prova ou com data válida passa na validação', () {
    expect(validateSubjectExamDate(hasExam: false, examDate: null), isNull);
    expect(
      validateSubjectExamDate(hasExam: true, examDate: DateTime(2026, 8, 25)),
      isNull,
    );
  });
}
