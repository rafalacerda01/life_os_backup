import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:drift/drift.dart' hide JsonKey;
import 'package:life_os/core/database/app_database.dart';

class NotificationModel {
  final String id;
  final String title;
  final String description;
  final String priority;
  final String moduleType;
  final String route;
  final bool isRead;
  final bool isCompleted;
  final DateTime? dueDate;
  final DateTime createdAt;

  NotificationModel({
    required this.id,
    required this.title,
    required this.description,
    required this.priority,
    required this.moduleType,
    required this.route,
    required this.isRead,
    required this.isCompleted,
    this.dueDate,
    required this.createdAt,
  });

  // ☁️ Construtor do Firestore
  factory NotificationModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return NotificationModel(
      id: doc.id,
      title: data['title'] ?? '',
      description: data['description'] ?? '',
      priority: data['priority'] ?? 'normal',
      moduleType: data['moduleType'] ?? 'general',
      route: data['route'] ?? '/',
      isRead: data['isRead'] ?? false,
      isCompleted: data['isCompleted'] ?? false,
      dueDate: data['dueDate'] != null
          ? (data['dueDate'] as Timestamp).toDate()
          : null,
      createdAt: data['createdAt'] != null
          ? (data['createdAt'] as Timestamp).toDate()
          : DateTime.now(),
    );
  }

  // 📱 Construtor do Drift (Offline-First)
  factory NotificationModel.fromDrift(NotificationsTableData data) {
    return NotificationModel(
      id: data.id,
      title: data.title,
      description: data.description,
      priority: data.priority,
      moduleType: data.moduleType,
      route: data.route,
      isRead: data.isRead,
      isCompleted: data.isCompleted,
      dueDate: data.dueDate,
      createdAt: data.createdAt,
    );
  }

  // 📱 Conversor para salvar no Drift
  static NotificationsTableCompanion toCompanion(NotificationModel model) {
    return NotificationsTableCompanion.insert(
      id: model.id,
      title: model.title,
      description: model.description,
      priority: model.priority,
      moduleType: model.moduleType,
      route: model.route,
      isRead: Value(model.isRead),
      isCompleted: Value(model.isCompleted),
      dueDate: Value(model.dueDate),
      createdAt: model.createdAt,
    );
  }
}
