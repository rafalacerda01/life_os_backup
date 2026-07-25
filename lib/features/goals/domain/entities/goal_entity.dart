import 'package:cloud_firestore/cloud_firestore.dart';

class GoalEntity {
  final String id;
  final String title;
  final String period;
  final int currentValue;
  final int targetValue;
  final DateTime createdAt;
  final DateTime lastReset;

  GoalEntity({
    required this.id,
    required this.title,
    required this.period,
    required this.currentValue,
    required this.targetValue,
    required this.createdAt,
    required this.lastReset,
  });

  factory GoalEntity.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>? ?? {};
    
    // Helper para converter Firestore Timestamp para DateTime
    DateTime toDate(dynamic val) {
      if (val is Timestamp) return val.toDate();
      return DateTime.now();
    }

    final createdAt = toDate(data['createdAt']);
    
    // Fallback: Se lastReset não existir (ex: metas antigas), 
    // usamos o createdAt como base para evitar comportamentos inesperados.
    final lastReset = data['lastReset'] != null 
        ? toDate(data['lastReset']) 
        : createdAt;

    return GoalEntity(
      id: doc.id,
      title: data['title'] ?? 'Meta Sem Nome',
      period: data['period'] ?? 'DIÁRIA',
      currentValue: (data['currentValue'] ?? 0).toInt(),
      targetValue: (data['targetValue'] ?? 100).toInt(),
      createdAt: createdAt,
      lastReset: lastReset,
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'title': title,
      'period': period,
      'currentValue': currentValue,
      'targetValue': targetValue,
      'createdAt': Timestamp.fromDate(createdAt),
      'lastReset': Timestamp.fromDate(lastReset),
    };
  }
}