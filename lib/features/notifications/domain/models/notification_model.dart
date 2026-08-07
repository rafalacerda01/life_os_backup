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

  const NotificationModel({
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

  factory NotificationModel.fromFirestore(DocumentSnapshot doc) {
    final raw = doc.data();
    final data = raw is Map<String, dynamic> ? raw : <String, dynamic>{};

    return NotificationModel(
      id: doc.id,
      title: data['title']?.toString() ?? '',
      description: data['description']?.toString() ?? '',
      priority: data['priority']?.toString() ?? 'normal',
      moduleType: data['moduleType']?.toString() ?? 'general',
      route: data['route']?.toString() ?? '/',
      isRead: data['isRead'] == true,
      isCompleted: data['isCompleted'] == true,
      dueDate: _timestampToDateTime(data['dueDate']),
      createdAt: _timestampToDateTime(data['createdAt']) ?? DateTime.now(),
    );
  }

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

  Map<String, Object?> toFirestore() {
    return {
      'title': title,
      'description': description,
      'priority': priority,
      'moduleType': moduleType,
      'route': route,
      'isRead': isRead,
      'isCompleted': isCompleted,
      'dueDate': dueDate == null ? null : Timestamp.fromDate(dueDate!),
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': FieldValue.serverTimestamp(),
    };
  }

  NotificationModel copyWith({
    String? id,
    String? title,
    String? description,
    String? priority,
    String? moduleType,
    String? route,
    bool? isRead,
    bool? isCompleted,
    DateTime? dueDate,
    DateTime? createdAt,
  }) {
    return NotificationModel(
      id: id ?? this.id,
      title: title ?? this.title,
      description: description ?? this.description,
      priority: priority ?? this.priority,
      moduleType: moduleType ?? this.moduleType,
      route: route ?? this.route,
      isRead: isRead ?? this.isRead,
      isCompleted: isCompleted ?? this.isCompleted,
      dueDate: dueDate ?? this.dueDate,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  static DateTime? _timestampToDateTime(Object? value) {
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    return null;
  }
}
