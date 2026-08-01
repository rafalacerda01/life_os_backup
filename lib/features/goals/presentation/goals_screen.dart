import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/features/goals/presentation/goals_provider.dart';
import 'package:life_os/core/security/input_sanitizer.dart';

class GoalsScreen extends ConsumerStatefulWidget {
  const GoalsScreen({super.key});

  @override
  ConsumerState<GoalsScreen> createState() => _GoalsScreenState();
}

class _GoalsScreenState extends ConsumerState<GoalsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(goalRepositoryProvider).syncGoalsFromFirebaseToLocal();
    });
  }

  // --- MÉTODOS AUXILIARES ---

  void _showDeleteConfirmationDialog(
    BuildContext context,
    WidgetRef ref,
    String goalId,
    String goalTitle,
  ) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF11182E),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: const Text(
            "Excluir Meta?",
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          content: Text(
            "Tem certeza que deseja apagar a meta \"$goalTitle\"? Essa ação não pode ser desfeita.",
            style: const TextStyle(color: Colors.white70, fontSize: 14),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text(
                "Cancelar",
                style: TextStyle(color: Colors.white38),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent,
              ),
              onPressed: () {
                ref.read(goalRepositoryProvider).removeGoal(goalId);
                Navigator.pop(context);
              },
              child: const Text(
                "Excluir",
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  void _showAddGoalModal(BuildContext context, WidgetRef ref) {
    final titleController = TextEditingController();
    final targetController = TextEditingController();
    String selectedTimeframe = "DIÁRIA";

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
                bottom: MediaQuery.of(context).viewInsets.bottom + 24,
                top: 24,
                left: 24,
                right: 24,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    "Nova Meta Estratégica",
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
                    decoration: const InputDecoration(
                      labelText: "Título da Meta",
                      labelStyle: TextStyle(color: Colors.white38),
                      filled: true,
                      fillColor: Color(0xFF070B14),
                    ),
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    value: selectedTimeframe,
                    dropdownColor: const Color(0xFF11182E),
                    items: ["DIÁRIA", "SEMANAL", "MENSAL"]
                        .map(
                          (s) => DropdownMenuItem(
                            value: s,
                            child: Text(
                              s,
                              style: const TextStyle(color: Colors.white),
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (v) =>
                        setModalState(() => selectedTimeframe = v!),
                  ),
                  TextField(
                    controller: targetController,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      labelText: "Meta numérica",
                    ),
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton(
                    onPressed: () async {
                      final title = InputSanitizer.sanitize(
                        titleController.text,
                      );
                      final target = int.tryParse(targetController.text) ?? 1;
                      if (title.isNotEmpty) {
                        await ref
                            .read(goalRepositoryProvider)
                            .createGoal(title, selectedTimeframe, target);
                        if (context.mounted) Navigator.pop(context);
                      }
                    },
                    child: const Text("Ativar Meta"),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // --- BUILD ---

  @override
  Widget build(BuildContext context) {
    final goalsAsync = ref.watch(goalsStreamProvider);

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        backgroundColor: const Color(0xFF070B14),
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          title: const Text(
            "Metas Estratégicas",
            style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
          ),
          bottom: const TabBar(
            indicatorColor: Color(0xFFB026FF),
            labelColor: Colors.white,
            tabs: [
              Tab(text: "Diárias"),
              Tab(text: "Semanais"),
              Tab(text: "Mensais"),
            ],
          ),
        ),
        body: goalsAsync.when(
          loading: () => const Center(
            child: CircularProgressIndicator(color: Color(0xFFB026FF)),
          ),
          error: (err, _) => Center(
            child: Text(
              "Erro: $err",
              style: const TextStyle(color: Colors.red),
            ),
          ),
          data: (goalsList) {
            // Lógica de Reset
            final now = DateTime.now();
            for (var goal in goalsList) {
              bool precisaResetar = false;
              final lastReset = goal.lastReset;
              if (goal.period == 'DIÁRIA') {
                precisaResetar =
                    lastReset.day != now.day ||
                    lastReset.month != now.month ||
                    lastReset.year != now.year;
              } else if (goal.period == 'MENSAL') {
                precisaResetar =
                    lastReset.month != now.month || lastReset.year != now.year;
              } else if (goal.period == 'SEMANAL') {
                final deSegunda = lastReset.subtract(
                  Duration(days: lastReset.weekday - 1),
                );
                final hojeSegunda = now.subtract(
                  Duration(days: now.weekday - 1),
                );
                precisaResetar =
                    deSegunda.day != hojeSegunda.day ||
                    deSegunda.month != hojeSegunda.month ||
                    deSegunda.year != hojeSegunda.year;
              }
              if (precisaResetar && goal.currentValue != 0) {
                Future.microtask(
                  () =>
                      ref.read(goalRepositoryProvider).resetGoalCycle(goal.id),
                );
              }
            }

            return TabBarView(
              children: ["DIÁRIA", "SEMANAL", "MENSAL"].map((timeframe) {
                final filteredGoals = goalsList
                    .where((g) => g.period == timeframe)
                    .toList();
                if (filteredGoals.isEmpty)
                  return const Center(
                    child: Text(
                      "Nenhuma meta definida.",
                      style: TextStyle(color: Colors.white38),
                    ),
                  );

                return ListView.builder(
                  padding: const EdgeInsets.all(20),
                  itemCount: filteredGoals.length,
                  itemBuilder: (context, index) {
                    final goal = filteredGoals[index];
                    final double progress = goal.targetValue > 0
                        ? goal.currentValue / goal.targetValue
                        : 0.0;
                    final bool isCompleted =
                        goal.currentValue >= goal.targetValue;

                    return Container(
                      margin: const EdgeInsets.only(bottom: 16),
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF11182E),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                goal.title,
                                style: TextStyle(
                                  color: isCompleted
                                      ? Colors.white38
                                      : Colors.white,
                                  fontWeight: FontWeight.bold,
                                  decoration: isCompleted
                                      ? TextDecoration.lineThrough
                                      : null,
                                ),
                              ),
                              Text(
                                "${goal.currentValue}/${goal.targetValue}",
                                style: const TextStyle(
                                  color: Color(0xFFB026FF),
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: LinearProgressIndicator(
                                  value: progress,
                                  minHeight: 10,
                                  valueColor:
                                      const AlwaysStoppedAnimation<Color>(
                                        Color(0xFFB026FF),
                                      ),
                                ),
                              ),
                              IconButton(
                                icon: const Icon(
                                  Icons.remove_circle_outline,
                                  color: Colors.white60,
                                ),
                                onPressed: goal.currentValue > 0
                                    ? () => ref
                                          .read(goalRepositoryProvider)
                                          .updateGoalProgress(
                                            goal.id,
                                            goal.currentValue - 1,
                                          )
                                    : null,
                              ),
                              IconButton(
                                icon: const Icon(
                                  Icons.add_circle,
                                  color: Color(0xFF5D0EFF),
                                ),
                                onPressed: goal.currentValue < goal.targetValue
                                    ? () => ref
                                          .read(goalRepositoryProvider)
                                          .updateGoalProgress(
                                            goal.id,
                                            goal.currentValue + 1,
                                          )
                                    : null,
                              ),
                              IconButton(
                                icon: const Icon(
                                  Icons.delete_outline,
                                  color: Colors.redAccent,
                                ),
                                onPressed: () => _showDeleteConfirmationDialog(
                                  context,
                                  ref,
                                  goal.id,
                                  goal.title,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    );
                  },
                );
              }).toList(),
            );
          },
        ),
        floatingActionButton: FloatingActionButton(
          backgroundColor: const Color(0xFFB026FF),
          onPressed: () => _showAddGoalModal(context, ref),
          child: const Icon(Icons.add, color: Colors.white),
        ),
      ),
    );
  }
}
