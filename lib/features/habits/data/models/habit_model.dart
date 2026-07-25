class HabitModel {
  final String id;
  final String title;
  final List<String> completedDates; // Guarda as datas concluídas: "yyyy-MM-dd"

  HabitModel({
    required this.id,
    required this.title,
    required this.completedDates,
  });

  // Converte do Firestore para o Dart
  factory HabitModel.fromMap(Map<String, dynamic> map, String documentId) {
    return HabitModel(
      id: documentId,
      title: map['title'] ?? '',
      completedDates: List<String>.from(map['completedDates'] ?? []),
    );
  }

  // Converte do Dart para o Firestore Map
  Map<String, dynamic> toMap() {
    return {
      'title': title,
      'completedDates': completedDates,
    };
  }
}