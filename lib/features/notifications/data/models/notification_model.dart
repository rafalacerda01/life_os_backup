import 'package:cloud_firestore/cloud_firestore.dart';

class NotificationModel {
  final String id;
  final String title;
  final String desc;
  final String iconCode;
  final DateTime createdAt;
  final bool isRead;

  const NotificationModel({
    required this.id,
    required this.title,
    required this.desc,
    required this.iconCode,
    required this.createdAt,
    required this.isRead,
  });

  factory NotificationModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>? ?? {};

    // Tratamento defensivo para evitar crashes de tipagem em produção
    DateTime parsedDate;
    final rawDate = data['createdAt'];
    if (rawDate is Timestamp) {
      parsedDate = rawDate.toDate();
    } else {
      parsedDate = DateTime.now();
    }

    return NotificationModel(
      id: doc.id,
      title: data['title'] as String? ?? '',
      desc: data['desc'] as String? ?? '',
      iconCode: data['iconCode'] as String? ?? 'notifications',
      createdAt: parsedDate,
      isRead: data['isRead'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'title': title,
      'desc': desc,
      'iconCode': iconCode,
      'createdAt': Timestamp.fromDate(createdAt),
      'isRead': isRead,
    };
  }
}
