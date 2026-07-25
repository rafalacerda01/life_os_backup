import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:equatable/equatable.dart';

class StudySubjectEntity extends Equatable {
  final String id;
  final String title;
  final int cardsToReview;
  final int streakDays;
  final double progress;
  final bool hasExam;         // 🚀 Novo campo
  final DateTime? examDate;   // 🚀 Novo campo

  const StudySubjectEntity({
    required this.id,
    required this.title,
    required this.cardsToReview,
    required this.streakDays,
    required this.progress,
    this.hasExam = false,
    this.examDate,
  });

  factory StudySubjectEntity.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>? ?? {};
    
    // Converte o Timestamp do Firestore para DateTime (se existir)
    DateTime? examDate;
    if (data['examDate'] != null) {
      examDate = (data['examDate'] as Timestamp).toDate();
    }

    return StudySubjectEntity(
      id: doc.id,
      title: data['title'] ?? 'Sem nome',
      cardsToReview: (data['cardsToReview'] ?? 0).toInt(),
      streakDays: (data['streakDays'] ?? 0).toInt(),
      progress: (data['progress'] ?? 0.0).toDouble(),
      hasExam: data['hasExam'] ?? false, // 🚀 Ler do Firestore
      examDate: examDate,                // 🚀 Ler do Firestore
    );
  }

  @override
  List<Object?> get props => [id, title, cardsToReview, streakDays, progress, hasExam, examDate];
}