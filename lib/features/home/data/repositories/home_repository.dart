import 'package:intl/intl.dart';

class HomeRepository {
  // Processa a busca pela próxima prova de forma isolada
  dynamic getNextExam(List<dynamic> subjects, DateTime now) {
    return subjects
        .where(
          (s) => s.hasExam && s.examDate != null && s.examDate!.isAfter(now),
        )
        .fold<dynamic>(null, (earliest, current) {
          if (earliest == null ||
              current.examDate!.compareTo(earliest.examDate!) < 0) {
            return current;
          }
          return earliest;
        });
  }

  // Processa a contagem de hábitos concluídos hoje
  int getCompletedHabitsCount(List<dynamic> habits, DateTime now) {
    final formattedToday = DateFormat('yyyy-MM-dd').format(now);
    return habits
        .where((h) => h.completedDates.contains(formattedToday))
        .length;
  }
}
