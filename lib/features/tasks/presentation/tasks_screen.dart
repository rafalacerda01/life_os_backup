import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:life_os/core/theme/app_colors.dart';
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

  Color _priorityColor(String priority) => switch (priority) {
    'high' => Colors.redAccent,
    'low' => Colors.blueAccent,
    _ => Colors.amberAccent,
  };

  String _priorityLabel(String priority) => switch (priority) {
    'high' => 'ALTA',
    'low' => 'BAIXA',
    _ => 'MÉDIA',
  };

  Widget _buildTaskList(List<TaskModel> tasks) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      sliver: SliverList(
        delegate: SliverChildBuilderDelegate((context, index) {
          final task = tasks[index];
          final priorityColor = _priorityColor(task.priority);

          return AnimatedOpacity(
            duration: const Duration(milliseconds: 240),
            opacity: task.isCompleted ? 0.55 : 1,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 240),
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(
                color: task.isCompleted
                    ? AppColors.cardBackground.withOpacity(0.72)
                    : AppColors.cardBackground,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: task.isCompleted
                      ? Colors.white.withOpacity(0.04)
                      : priorityColor.withOpacity(0.16),
                ),
              ),
              child: Material(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(18),
                child: InkWell(
                  borderRadius: BorderRadius.circular(18),
                  onTap: () async {
                    await ref.read(manualTaskStatusToggleProvider)(
                      task.id,
                      task.isCompleted,
                    );
                  },
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
                    child: Row(
                      children: [
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 240),
                          transitionBuilder: (child, animation) =>
                              ScaleTransition(scale: animation, child: child),
                          child: Icon(
                            task.isCompleted
                                ? Icons.check_circle_rounded
                                : Icons.radio_button_unchecked_rounded,
                            key: ValueKey(task.isCompleted),
                            color: task.isCompleted
                                ? AppColors.primary
                                : priorityColor,
                            size: 25,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                task.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: AppColors.textMain,
                                  fontSize: 15,
                                  height: 1.25,
                                  fontWeight: task.isCompleted
                                      ? FontWeight.w500
                                      : FontWeight.w600,
                                  decoration: task.isCompleted
                                      ? TextDecoration.lineThrough
                                      : null,
                                  decorationColor: AppColors.textSecondary,
                                ),
                              ),
                              const SizedBox(height: 7),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: priorityColor.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: priorityColor.withOpacity(0.24),
                                  ),
                                ),
                                child: Text(
                                  _priorityLabel(task.priority),
                                  style: TextStyle(
                                    color: priorityColor,
                                    fontSize: 9,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 0.7,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: 'Excluir tarefa',
                          icon: const Icon(
                            Icons.delete_outline_rounded,
                            color: AppColors.textHint,
                            size: 21,
                          ),
                          onPressed: () =>
                              _confirmDelete(context, ref, task.id),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        }, childCount: tasks.length),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tasksAsync = ref.watch(tasksStreamProvider);

    return Scaffold(
      backgroundColor: const Color(0xFF070B14),
      floatingActionButton: FloatingActionButton(
        tooltip: 'Nova tarefa',
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        elevation: 6,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(17)),
        onPressed: () => _showAddTaskDialog(context, ref),
        child: const Icon(Icons.add_rounded, size: 28),
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
            final pendingTasks = tasks
                .where((task) => !task.isCompleted)
                .toList();
            final completedTasks = tasks
                .where((task) => task.isCompleted)
                .toList();
            final pendingCount = pendingTasks.length;
            final progress = tasks.isEmpty
                ? 0.0
                : (completedCount / tasks.length);

            return TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 360),
              curve: Curves.easeOutCubic,
              builder: (context, value, child) => Opacity(
                opacity: value,
                child: Transform.translate(
                  offset: Offset(0, 10 * (1 - value)),
                  child: child,
                ),
              ),
              child: CustomScrollView(
                physics: const BouncingScrollPhysics(),
                slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 28, 20, 22),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const _TasksHeader(),
                          const SizedBox(height: 22),
                          _ProductivityHero(
                            totalCount: tasks.length,
                            pendingCount: pendingCount,
                            completedCount: completedCount,
                            progress: progress,
                          ),
                          const SizedBox(height: 14),
                          _FocusCta(onTap: () => context.push('/focus')),
                        ],
                      ),
                    ),
                  ),
                  if (tasks.isEmpty)
                    const SliverFillRemaining(
                      hasScrollBody: false,
                      child: _TasksEmptyState(),
                    )
                  else ...[
                    SliverToBoxAdapter(
                      child: _TaskSectionHeader(
                        title: 'PRÓXIMAS AÇÕES',
                        count: pendingCount,
                      ),
                    ),
                    if (pendingTasks.isEmpty)
                      const SliverToBoxAdapter(child: _NoPendingTasksState())
                    else
                      _buildTaskList(pendingTasks),
                    if (completedTasks.isNotEmpty) ...[
                      SliverToBoxAdapter(
                        child: _TaskSectionHeader(
                          title: 'CONCLUÍDAS',
                          count: completedCount,
                          topPadding: 18,
                        ),
                      ),
                      _buildTaskList(completedTasks),
                    ],
                    const SliverToBoxAdapter(child: SizedBox(height: 100)),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _TasksHeader extends StatelessWidget {
  const _TasksHeader();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Produtividade',
          style: TextStyle(
            color: AppColors.textMain,
            fontSize: 30,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.9,
          ),
        ),
        SizedBox(height: 5),
        Text(
          'Execute o que importa.',
          style: TextStyle(color: AppColors.textSecondary, fontSize: 15),
        ),
      ],
    );
  }
}

class _ProductivityHero extends StatelessWidget {
  final int totalCount;
  final int pendingCount;
  final int completedCount;
  final double progress;

  const _ProductivityHero({
    required this.totalCount,
    required this.pendingCount,
    required this.completedCount,
    required this.progress,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('productivity-hero'),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: AppColors.primary.withOpacity(0.2)),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppColors.cardBackground,
            AppColors.secondary.withOpacity(0.14),
            AppColors.primary.withOpacity(0.07),
          ],
        ),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withOpacity(0.07),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'SEU RITMO',
            style: TextStyle(
              color: AppColors.primary,
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.4,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '${(progress * 100).round()}%',
            style: const TextStyle(
              color: AppColors.textMain,
              fontSize: 42,
              height: 1,
              fontWeight: FontWeight.w800,
              letterSpacing: -1.5,
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: _RhythmStat(value: totalCount, label: 'Total'),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _RhythmStat(value: pendingCount, label: 'Pendentes'),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _RhythmStat(value: completedCount, label: 'Concluídas'),
              ),
            ],
          ),
          const SizedBox(height: 18),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: progress),
              duration: const Duration(milliseconds: 700),
              curve: Curves.easeOutCubic,
              builder: (context, value, _) => LinearProgressIndicator(
                value: value,
                minHeight: 7,
                backgroundColor: Colors.white.withOpacity(0.06),
                color: AppColors.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RhythmStat extends StatelessWidget {
  final int value;
  final String label;

  const _RhythmStat({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.035),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$value',
            style: const TextStyle(
              color: AppColors.textMain,
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              label,
              maxLines: 1,
              style: const TextStyle(
                color: AppColors.textHint,
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FocusCta extends StatelessWidget {
  final VoidCallback onTap;

  const _FocusCta({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      key: const ValueKey('productivity-focus-cta'),
      color: AppColors.cardBackground,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppColors.primary.withOpacity(0.16)),
          ),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [AppColors.secondary, AppColors.primary],
                  ),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(
                  Icons.track_changes_rounded,
                  color: Colors.white,
                  size: 21,
                ),
              ),
              const SizedBox(width: 13),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Entrar em foco',
                      style: TextStyle(
                        color: AppColors.textMain,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SizedBox(height: 3),
                    Text(
                      'Escolha uma tarefa e concentre-se nela.',
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(
                Icons.chevron_right_rounded,
                color: AppColors.textHint,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TaskSectionHeader extends StatelessWidget {
  final String title;
  final int count;
  final double topPadding;

  const _TaskSectionHeader({
    required this.title,
    required this.count,
    this.topPadding = 0,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(20, topPadding, 20, 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 10.5,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.2,
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: AppColors.primary.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '$count',
              style: const TextStyle(
                color: AppColors.primary,
                fontSize: 10,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TasksEmptyState extends StatelessWidget {
  const _TasksEmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(28, 8, 28, 100),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 68,
              height: 68,
              decoration: BoxDecoration(
                color: AppColors.primary.withOpacity(0.08),
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.primary.withOpacity(0.16)),
              ),
              child: const Icon(
                Icons.fact_check_outlined,
                color: AppColors.primary,
                size: 30,
              ),
            ),
            const SizedBox(height: 18),
            const Text(
              'Nenhuma tarefa cadastrada.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textMain,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 7),
            const Text(
              'Adicione uma nova tarefa focada\npara começar.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoPendingTasksState extends StatelessWidget {
  const _NoPendingTasksState();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.fromLTRB(20, 2, 20, 4),
      child: Row(
        children: [
          Icon(Icons.check_circle_outline_rounded, color: AppColors.health),
          SizedBox(width: 9),
          Expanded(
            child: Text(
              'Todas as próximas ações foram concluídas.',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
