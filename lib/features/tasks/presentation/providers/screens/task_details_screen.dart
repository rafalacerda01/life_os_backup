import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:life_os/features/tasks/domain/entities/task_entity.dart';
import 'package:life_os/features/tasks/presentation/providers/tasks_notifier.dart';

class TaskDetailsScreen extends ConsumerStatefulWidget {
  final TaskEntity task;
  const TaskDetailsScreen({super.key, required this.task});

  @override
  ConsumerState<TaskDetailsScreen> createState() => _TaskDetailsScreenState();
}

class _TaskDetailsScreenState extends ConsumerState<TaskDetailsScreen> {
  late TextEditingController _titleController;
  late TextEditingController _descController;
  late String _priority;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.task.title);
    _descController = TextEditingController(text: widget.task.description);
    _priority = widget.task.priority;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF070B14),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          "Detalhes da Tarefa",
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            icon: const Icon(
              Icons.check_circle_outline,
              color: Colors.greenAccent,
            ),
            onPressed: () {
              final updated = TaskEntity(
                id: widget.task.id,
                title: _titleController.text,
                description: _descController.text,
                priority: _priority,
                isCompleted: widget.task.isCompleted,
                subTasks: widget.task.subTasks,
              );
              ref.read(tasksProvider.notifier).updateTaskDetails(updated);
              context.pop();
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "Título",
              style: TextStyle(color: Colors.white54, fontSize: 14),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _titleController,
              style: const TextStyle(color: Colors.white, fontSize: 18),
              decoration: InputDecoration(
                filled: true,
                fillColor: const Color(0xFF11182E),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              "Prioridade",
              style: TextStyle(color: Colors.white54, fontSize: 14),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              value: _priority,
              dropdownColor: const Color(0xFF11182E),
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                filled: true,
                fillColor: const Color(0xFF11182E),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
              items: const [
                DropdownMenuItem(value: "HIGH", child: Text("Alta Prioridade")),
                DropdownMenuItem(
                  value: "MEDIUM",
                  child: Text("Média Prioridade"),
                ),
                DropdownMenuItem(value: "LOW", child: Text("Baixa Prioridade")),
              ],
              onChanged: (val) {
                if (val != null) setState(() => _priority = val);
              },
            ),
            const SizedBox(height: 20),
            const Text(
              "Descrição",
              style: TextStyle(color: Colors.white54, fontSize: 14),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _descController,
              maxLines: 4,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                filled: true,
                fillColor: const Color(0xFF11182E),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
