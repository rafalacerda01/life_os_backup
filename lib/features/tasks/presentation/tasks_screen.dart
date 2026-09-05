import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/features/tasks/presentation/providers/tasks_provider.dart';
import 'package:life_os/features/tasks/data/models/task_model.dart';
import 'package:life_os/features/premium/domain/services/plan_limits.dart';
import 'package:life_os/features/premium/domain/services/quota_service.dart';
import 'package:life_os/features/premium/presentation/plan_limits_provider.dart';

class TasksScreen extends ConsumerStatefulWidget {
  const TasksScreen({super.key});

  @override
  ConsumerState<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends ConsumerState<TasksScreen> {
  @override
  void initState() {
    super.initState();
    // 🛡️ CORREÇÃO: O sync agora roda APENAS UMA VEZ ao abrir a tela, evitando o loop infinito no terminal.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(tasksRepositoryProvider).syncTasksFromFirebaseToLocal();
    });
  }

  // Modal para cadastrar tarefa com seletor de prioridade e design premium
  void _showAddTaskDialog(BuildContext context, WidgetRef ref) {
    final titleController = TextEditingController();
    String selectedPriority = 'medium';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Container(
              decoration: const BoxDecoration(
                color: Color(0xFF11182E),
                borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
              ),
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom + 24,
                left: 24,
                right: 24,
                top: 12,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    "Nova Tarefa Focada",
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    controller: titleController,
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                    autofocus: true,
                    decoration: InputDecoration(
                      hintText: 'O que você vai executar?',
                      hintStyle: const TextStyle(color: Colors.white38),
                      filled: true,
                      fillColor: const Color(0xFF070B14),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 18,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: const BorderSide(
                          color: Colors.purpleAccent,
                          width: 1.5,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    "Nível de Prioridade",
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      _buildPriorityChip(
                        label: 'Baixa',
                        value: 'low',
                        color: Colors.blueAccent,
                        selectedValue: selectedPriority,
                        onSelected: (val) =>
                            setModalState(() => selectedPriority = val),
                      ),
                      const SizedBox(width: 12),
                      _buildPriorityChip(
                        label: 'Média',
                        value: 'medium',
                        color: Colors.amberAccent,
                        selectedValue: selectedPriority,
                        onSelected: (val) =>
                            setModalState(() => selectedPriority = val),
                      ),
                      const SizedBox(width: 12),
                      _buildPriorityChip(
                        label: 'Alta',
                        value: 'high',
                        color: Colors.redAccent,
                        selectedValue: selectedPriority,
                        onSelected: (val) =>
                            setModalState(() => selectedPriority = val),
                      ),
                    ],
                  ),
                  const SizedBox(height: 32),
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.purpleAccent,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      onPressed: () async {
                        FocusManager.instance.primaryFocus?.unfocus();

                        final title = titleController.text.trim();

                        if (title.isEmpty) {
                          return;
                        }

                        final tasksAsync = ref.read(tasksStreamProvider);

                        if (!tasksAsync.hasValue) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Não foi possível verificar suas tarefas agora. Tente novamente.',
                                ),
                              ),
                            );
                          }
                          return;
                        }

                        final tasks = tasksAsync.requireValue;

                        final limits = ref.read(planLimitsProvider);
                        const quotaService = QuotaService();

                        final taskLimit = limits.limitFor(QuotaResource.tasks);

                        final canCreate = quotaService.canCreate(
                          limit: taskLimit,
                          currentCount: tasks.length,
                        );

                        if (!canCreate) {
                          final message = switch (taskLimit.mode) {
                            QuotaMode.disabled =>
                              'Este recurso não está disponível no seu plano.',
                            QuotaMode.limited =>
                              'Você atingiu o limite de ${taskLimit.maximum} tarefas do seu plano.',
                            QuotaMode.unlimited =>
                              'Você não possui limite de tarefas.',
                            QuotaMode.notConfigured =>
                              'O limite deste recurso ainda não está configurado.',
                          };

                          if (context.mounted) {
                            ScaffoldMessenger.of(
                              context,
                            ).showSnackBar(SnackBar(content: Text(message)));
                          }

                          return;
                        }

                        await ref
                            .read(tasksRepositoryProvider)
                            .addTask(title, selectedPriority);

                        if (context.mounted) {
                          Navigator.pop(context);
                        }
                      },
                      child: const Text(
                        "Adicionar à Rotina",
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildPriorityChip({
    required String label,
    required String value,
    required Color color,
    required String selectedValue,
    required Function(String) onSelected,
  }) {
    final isSelected = selectedValue == value;
    return Expanded(
      child: GestureDetector(
        onTap: () => onSelected(value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: isSelected
                ? color.withOpacity(0.15)
                : const Color(0xFF070B14),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected ? color : Colors.transparent,
              width: 1.5,
            ),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              color: isSelected ? color : Colors.white54,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    String taskId,
  ) async {
    FocusManager.instance.primaryFocus?.unfocus();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF11182E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text(
          "Excluir Tarefa",
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: const Text(
          "Deseja remover esta tarefa permanentemente?",
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text(
              "Cancelar",
              style: TextStyle(color: Colors.white54),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent.withOpacity(0.2),
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text(
              "Excluir",
              style: TextStyle(
                color: Colors.redAccent,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      await ref.read(tasksRepositoryProvider).deleteTask(taskId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text("Tarefa removida com sucesso."),
            backgroundColor: const Color(0xFF11182E),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tasksAsync = ref.watch(tasksStreamProvider);

    return Scaffold(
      backgroundColor: const Color(0xFF070B14),
      floatingActionButton: FloatingActionButton(
        backgroundColor: Colors.purpleAccent,
        elevation: 4,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        onPressed: () => _showAddTaskDialog(context, ref),
        child: const Icon(Icons.add, color: Colors.white, size: 28),
      ),
      body: SafeArea(
        child: tasksAsync.when(
          loading: () => const Center(
            child: CircularProgressIndicator(color: Colors.purpleAccent),
          ),
          error: (err, stack) => Center(
            child: Text(
              "Erro ao carregar tarefas:\n$err",
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.redAccent),
            ),
          ),
          data: (tasks) {
            final completedCount = tasks.where((t) => t.isCompleted).length;
            final progress = tasks.isEmpty
                ? 0.0
                : (completedCount / tasks.length);

            return CustomScrollView(
              physics: const BouncingScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 40, 24, 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          "Produtividade",
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 32,
                            fontWeight: FontWeight.bold,
                            letterSpacing: -1,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          tasks.isEmpty
                              ? "Nenhuma tarefa cadastrada."
                              : "Você concluiu $completedCount de ${tasks.length} tarefas",
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(height: 24),
                        if (tasks.isNotEmpty)
                          ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: Container(
                              height: 8,
                              width: double.infinity,
                              color: const Color(0xFF11182E),
                              child: TweenAnimationBuilder<double>(
                                tween: Tween<double>(begin: 0, end: progress),
                                duration: const Duration(milliseconds: 800),
                                curve: Curves.easeOutCubic,
                                builder: (context, value, _) {
                                  return FractionallySizedBox(
                                    alignment: Alignment.centerLeft,
                                    widthFactor: value,
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: Colors.purpleAccent,
                                        borderRadius: BorderRadius.circular(10),
                                        boxShadow: [
                                          BoxShadow(
                                            color: Colors.purpleAccent
                                                .withOpacity(0.5),
                                            blurRadius: 6,
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                tasks.isEmpty
                    ? SliverFillRemaining(
                        hasScrollBody: false,
                        child: Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.fact_check_outlined,
                                size: 80,
                                color: Colors.white.withOpacity(0.1),
                              ),
                              const SizedBox(height: 20),
                              const Text(
                                "Tudo limpo por aqui! 🧠",
                                style: TextStyle(
                                  color: Colors.white54,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(height: 8),
                              const Text(
                                "Adicione uma nova tarefa focada\npara começar.",
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Colors.white38,
                                  fontSize: 14,
                                ),
                              ),
                              const SizedBox(height: 80),
                            ],
                          ),
                        ),
                      )
                    : SliverPadding(
                        padding: const EdgeInsets.only(
                          left: 24,
                          right: 24,
                          bottom: 100,
                        ),
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

                            return AnimatedOpacity(
                              duration: const Duration(milliseconds: 300),
                              opacity: task.isCompleted ? 0.4 : 1.0,
                              child: Container(
                                margin: const EdgeInsets.only(bottom: 16),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF11182E),
                                  borderRadius: BorderRadius.circular(16),
                                  boxShadow: [
                                    if (!task.isCompleted)
                                      BoxShadow(
                                        color: Colors.black.withOpacity(0.2),
                                        blurRadius: 8,
                                        offset: const Offset(0, 4),
                                      ),
                                  ],
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(16),
                                  child: Material(
                                    color: Colors.transparent,
                                    child: InkWell(
                                      onTap: () async {
                                        await ref.read(
                                          manualTaskStatusToggleProvider,
                                        )(task.id, task.isCompleted);
                                      },
                                      child: Container(
                                        decoration: BoxDecoration(
                                          border: Border(
                                            left: BorderSide(
                                              color: task.isCompleted
                                                  ? Colors.transparent
                                                  : priorityColor,
                                              width: 4,
                                            ),
                                          ),
                                        ),
                                        child: ListTile(
                                          contentPadding:
                                              const EdgeInsets.symmetric(
                                                horizontal: 16,
                                                vertical: 8,
                                              ),
                                          leading: AnimatedSwitcher(
                                            duration: const Duration(
                                              milliseconds: 300,
                                            ),
                                            transitionBuilder: (child, anim) =>
                                                ScaleTransition(
                                                  scale: anim,
                                                  child: child,
                                                ),
                                            child: Icon(
                                              task.isCompleted
                                                  ? Icons.check_circle
                                                  : Icons.circle_outlined,
                                              key: ValueKey(task.isCompleted),
                                              color: task.isCompleted
                                                  ? Colors.purpleAccent
                                                  : priorityColor.withOpacity(
                                                      0.7,
                                                    ),
                                              size: 28,
                                            ),
                                          ),
                                          title: Text(
                                            task.title,
                                            style: TextStyle(
                                              color: Colors.white,
                                              fontSize: 16,
                                              fontWeight: task.isCompleted
                                                  ? FontWeight.normal
                                                  : FontWeight.w600,
                                              decoration: task.isCompleted
                                                  ? TextDecoration.lineThrough
                                                  : null,
                                              decorationColor: Colors.white54,
                                            ),
                                          ),
                                          trailing: IconButton(
                                            icon: const Icon(
                                              Icons.delete_outline,
                                              color: Colors.white38,
                                              size: 22,
                                            ),
                                            onPressed: () => _confirmDelete(
                                              context,
                                              ref,
                                              task.id,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
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
