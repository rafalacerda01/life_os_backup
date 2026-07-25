import 'package:cloud_firestore/cloud_firestore.dart';

class StudyModel {
  final int streak;
  final int reviewQueue;
  final double progress;
  final DateTime? lastStudyDate;

  StudyModel({
    required this.streak,
    required this.reviewQueue,
    required this.progress,
    this.lastStudyDate,
  });

  // O MÉTODO COPYWITH
  StudyModel copyWith({
    int? streak,
    int? reviewQueue,
    double? progress,
    DateTime? lastStudyDate,
  }) {
    return StudyModel(
      streak: streak ?? this.streak,
      reviewQueue: reviewQueue ?? this.reviewQueue,
      progress: progress ?? this.progress,
      lastStudyDate: lastStudyDate ?? this.lastStudyDate,
    );
  }

  // Restante dos seus métodos (fromMap, toMap, initial...) permanecem iguais
  factory StudyModel.fromMap(Map<String, dynamic> map) {
    return StudyModel(
      streak: map['streak'] ?? 0,
      reviewQueue: map['reviewQueue'] ?? 0,
      progress: (map['progress'] ?? 0.0).toDouble(),
      lastStudyDate: map['lastStudyDate'] != null 
          ? (map['lastStudyDate'] as Timestamp).toDate() 
          : null,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'streak': streak,
      'reviewQueue': reviewQueue,
      'progress': progress,
      'lastStudyDate': lastStudyDate != null ? Timestamp.fromDate(lastStudyDate!) : null,
    };
  }

  factory StudyModel.initial() {
    return StudyModel(
      streak: 0,
      reviewQueue: 10,
      progress: 0.0,
    );
  }
}