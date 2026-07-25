import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/features/tasks/presentation/providers/tasks_provider.dart';
import 'package:life_os/features/tasks/data/models/task_model.dart';

class TasksScreen extends ConsumerWidget {
  const TasksScreen({super.key});

  // Modal para cadastrar tarefa com seletor de prioridade corrigido
  void _showAddTaskDialog(BuildContext context, WidgetRef ref) {
    final titleController = TextEditingController();
    String selectedPriority =
        'medium'; // Escopo correto: retém o estado durante os rebuilds do modal

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF11182E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom,
                left: 20,
                right: 20,
                top: 24,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "Nova Tarefa Focada",
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    controller: titleController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: 'O que você vai executar?',
                      labelStyle: const TextStyle(color: Colors.white54),
                      filled: true,
                      fillColor: const Color(0xFF070B14),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    "Nível de Prioridade:",
                    style: TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                  const SizedBox(height: 10),

                  // SELETORES DIRETOS: Modificam a variável real do escopo pai
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      ChoiceChip(
                        label: const Text('Baixa'),
                        selected: selectedPriority == 'low',
                        selectedColor: Colors.blueAccent.withOpacity(0.2),
                        labelStyle: TextStyle(
                          color: selectedPriority == 'low'
                              ? Colors.blueAccent
                              : Colors.white54,
                          fontWeight: selectedPriority == 'low'
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ),
                        onSelected: (val) {
                          if (val) {
                            setModalState(() {
                              selectedPriority = 'low';
                            });
                          }
                        },
                      ),
                      ChoiceChip(
                        label: const Text('Média'),
                        selected: selectedPriority == 'medium',
                        selectedColor: Colors.amberAccent.withOpacity(0.2),
                        labelStyle: TextStyle(
                          color: selectedPriority == 'medium'
                              ? Colors.amberAccent
                              : Colors.white54,
                          fontWeight: selectedPriority == 'medium'
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ),
                        onSelected: (val) {
                          if (val) {
                            setModalState(() {
                              selectedPriority = 'medium';
                            });
                          }
                        },
                      ),
                      ChoiceChip(
                        label: const Text('Alta'),
                        selected: selectedPriority == 'high',
                        selectedColor: Colors.redAccent.withOpacity(0.2),
                        labelStyle: TextStyle(
                          color: selectedPriority == 'high'
                              ? Colors.redAccent
                              : Colors.white54,
                          fontWeight: selectedPriority == 'high'
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ),
                        onSelected: (val) {
                          if (val) {
                            setModalState(() {
                              selectedPriority = 'high';
                            });
                          }
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 25),

                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.purpleAccent,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: () async {
                        if (titleController.text.isNotEmpty) {
                          await ref
                              .read(tasksRepositoryProvider)
                              .addTask(titleController.text, selectedPriority);
                          if (context.mounted) Navigator.pop(context);
                        }
                      },
                      child: const Text(
                        "Adicionar à Rotina",
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    String taskId,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF11182E),
        title: const Text(
          "Excluir Tarefa",
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          "Deseja remover esta tarefa?",
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("Cancelar"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text(
              "Excluir",
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true && context.mounted) {
      await ref.read(tasksRepositoryProvider).deleteTask(taskId);

      // Agora, se quiser, pode mostrar um feedback sem medo de crash
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("Tarefa removida.")));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // ADIÇÃO: Dispara a sincronização automaticamente quando a tela carrega
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(tasksRepositoryProvider).syncTasksFromFirebaseToLocal();
    });

    final tasksAsync = ref.watch(tasksStreamProvider);

    return Scaffold(
      backgroundColor: const Color(0xFF070B14),
      floatingActionButton: FloatingActionButton(
        backgroundColor: Colors.purpleAccent,
        onPressed: () => _showAddTaskDialog(context, ref),
        child: const Icon(Icons.add_task, color: Colors.white),
      ),
      body: SafeArea(
        child: tasksAsync.when(
          loading: () => const Center(
            child: CircularProgressIndicator(color: Colors.purpleAccent),
          ),
          error: (err, stack) => Center(
            child: Text(
              "Erro nas tarefas: $err",
              style: const TextStyle(color: Colors.red),
            ),
          ),
          data: (tasks) {
            final completedCount = tasks.where((t) => t.isCompleted).length;

            return CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.all(20),
                  sliver: SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          "Central de Produtividade",
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 26,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          "Você concluiu $completedCount de ${tasks.length} metas hoje",
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 20),
                      ],
                    ),
                  ),
                ),

                tasks.isEmpty
                    ? const SliverToBoxAdapter(
                        child: Center(
                          child: Padding(
                            padding: EdgeInsets.only(top: 60),
                            child: Text(
                              "Nenhuma tarefa para hoje. Logs limpos! 🧠",
                              style: TextStyle(color: Colors.white38),
                            ),
                          ),
                        ),
                      )
                    : SliverPadding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        sliver: SliverList(
                          delegate: SliverChildBuilderDelegate((
                            context,
                            index,
                          ) {
                            final task = tasks[index];

                            Color priorityColor = Colors.amberAccent;
                            if (task.priority == 'high')
                              priorityColor = Colors.redAccent;
                            if (task.priority == 'low')
                              priorityColor = Colors.blueAccent;

                            return Container(
                              margin: const EdgeInsets.only(bottom: 12),
                              decoration: BoxDecoration(
                                color: const Color(0xFF11182E),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: task.isCompleted
                                      ? Colors.transparent
                                      : priorityColor.withOpacity(0.15),
                                  width: 1,
                                ),
                              ),
                              child: ListTile(
                                leading: IconButton(
                                  icon: Icon(
                                    task.isCompleted
                                        ? Icons.check_circle
                                        : Icons.radio_button_unchecked,
                                    color: task.isCompleted
                                        ? Colors.purpleAccent
                                        : priorityColor,
                                  ),
                                  onPressed: () async {
                                    await ref
                                        .read(tasksRepositoryProvider)
                                        .toggleTaskStatus(
                                          task.id,
                                          task.isCompleted,
                                        );
                                  },
                                ),
                                title: Text(
                                  task.title,
                                  style: TextStyle(
                                    color: task.isCompleted
                                        ? Colors.white38
                                        : Colors.white,
                                    fontWeight: FontWeight.bold,
                                    decoration: task.isCompleted
                                        ? TextDecoration.lineThrough
                                        : null,
                                  ),
                                ),
                                trailing: IconButton(
                                  icon: const Icon(
                                    Icons.delete_outline,
                                    color: Colors.white24,
                                    size: 20,
                                  ),
                                  onPressed: () =>
                                      _confirmDelete(context, ref, task.id),
                                ),
                              ),
                            );
                          }, childCount: tasks.length),
                        ),
                      ),
              ],
            );
          },
        ),
      ),
    );
  }
}
