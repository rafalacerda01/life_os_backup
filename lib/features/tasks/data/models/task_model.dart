import 'package:cloud_firestore/cloud_firestore.dart';

class TaskModel {
  final String id;
  final String title;
  final String priority; // 'high', 'medium', 'low'
  final bool isCompleted;
  final DateTime date;

  TaskModel({
    required this.id,
    required this.title,
    required this.priority,
    required this.isCompleted,
    required this.date,
  });

  // Converte do Firestore para o Dart
  factory TaskModel.fromMap(Map<String, dynamic> map, String documentId) {
    return TaskModel(
      id: documentId,
      title: map['title'] ?? '',
      priority: map['priority'] ?? 'medium',
      isCompleted: map['isCompleted'] ?? false,
      date: map['date'] != null ? (map['date'] as Timestamp).toDate() : DateTime.now(),
    );
  }

  // Converte do Dart para o Firestore Map
  Map<String, dynamic> toMap() {
    return {
      'title': title,
      'priority': priority,
      'isCompleted': isCompleted,
      'date': Timestamp.fromDate(date),
    };
  }
}