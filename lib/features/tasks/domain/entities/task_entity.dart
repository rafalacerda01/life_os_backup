import 'package:equatable/equatable.dart';

class SubTask extends Equatable {
  final String id;
  final String title;
  final bool isCompleted;

  const SubTask({required this.id, required this.title, required this.isCompleted});

  @override
  List<Object?> get props => [id, title, isCompleted];
}

class TaskEntity extends Equatable {
  final String id;
  final String title;
  final String description;
  final String priority; // 'HIGH', 'MEDIUM', 'LOW'
  final bool isCompleted;
  final List<SubTask> subTasks;

  const TaskEntity({
    required this.id,
    required this.title,
    required this.description,
    required this.priority,
    required this.isCompleted,
    required this.subTasks,
  });

  @override
  List<Object?> get props => [id, title, description, priority, isCompleted, subTasks];
}