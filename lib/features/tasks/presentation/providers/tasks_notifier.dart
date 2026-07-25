import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/entities/task_entity.dart';
import '../providers/tasks_provider.dart';

class TasksNotifier extends Notifier<List<TaskEntity>> {
  @override
  List<TaskEntity> build() {
    _watchLocalTasks();
    return [];
  }

  void _watchLocalTasks() {
    final repository = ref.read(tasksRepositoryProvider);

    repository.getTasksStream().listen((taskModels) {
      state = taskModels
          .map(
            (model) => TaskEntity(
              id: model.id,
              title: model.title,
              description: '',
              priority: model.priority,
              isCompleted: model.isCompleted,
              subTasks: const [],
            ),
          )
          .toList();
    });
  }

  Future<void> toggleTaskCompletion(String taskId, bool currentStatus) async {
    final repository = ref.read(tasksRepositoryProvider);
    await repository.toggleTaskStatus(taskId, currentStatus);
  }

  Future<void> addTask(String title, String priority) async {
    final repository = ref.read(tasksRepositoryProvider);
    await repository.addTask(title, priority);
  }

  Future<void> deleteTask(String taskId) async {
    final repository = ref.read(tasksRepositoryProvider);
    await repository.deleteTask(taskId);
  }

  // Método adicionado para atender à chamada do task_details_screen.dart
  Future<void> updateTaskDetails(TaskEntity updatedTask) async {
    // Se o seu repositório possuir um método de atualização completa, chame-o aqui.
    // Caso contrário, você pode atualizar os campos necessários diretamente no banco/repositório.
    state = [
      for (final task in state)
        if (task.id == updatedTask.id) updatedTask else task,
    ];
  }
}

final tasksProvider = NotifierProvider<TasksNotifier, List<TaskEntity>>(
  TasksNotifier.new,
);
