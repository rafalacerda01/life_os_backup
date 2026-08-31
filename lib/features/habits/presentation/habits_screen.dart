import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:life_os/features/habits/presentation/providers/habits_provider.dart';
import 'package:life_os/features/premium/domain/services/plan_limits.dart';
import 'package:life_os/features/premium/domain/services/quota_service.dart';
import 'package:life_os/features/premium/presentation/plan_limits_provider.dart';

class HabitsScreen extends ConsumerWidget {
  const HabitsScreen({super.key});

  void _showAddHabitDialog(BuildContext context, WidgetRef ref) {
    final controller = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF11182E),
        title: const Text(
          "Monitorar Novo Hábito",
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: TextField(
          controller: controller,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            labelText: 'Ex: Treinar, Meditar, Ler...',
            labelStyle: const TextStyle(color: Colors.white54),
            filled: true,
            fillColor: const Color(0xFF070B14),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              "Cancelar",
              style: TextStyle(color: Colors.white54),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.cyanAccent),
            onPressed: () async {
              final title = controller.text.trim();

              if (title.isEmpty) {
                return;
              }

              final habitsAsync = ref.read(habitsStreamProvider);

              if (!habitsAsync.hasValue) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Não foi possível verificar seus hábitos agora. Tente novamente.',
                      ),
                    ),
                  );
                }
                return;
              }

              final habits = habitsAsync.requireValue;

              final limits = ref.read(planLimitsProvider);
              const quotaService = QuotaService();

              final canCreate = quotaService.canCreate(
                limit: limits.limitFor(QuotaResource.habits),
                currentCount: habits.length,
              );

              if (!canCreate) {
                final limit = limits.limitFor(QuotaResource.habits);

                final message = switch (limit.mode) {
                  QuotaMode.disabled =>
                    'Este recurso não está disponível no seu plano.',
                  QuotaMode.limited =>
                    'Você atingiu o limite de ${limit.maximum} hábitos do seu plano.',
                  QuotaMode.unlimited => 'Você não possui limite de hábitos.',
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

              await ref.read(habitsRepositoryProvider).addHabit(title);

              if (context.mounted) {
                Navigator.pop(context);
              }
            },
            child: const Text(
              "Iniciar",
              style: TextStyle(
                color: Colors.black,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // 🚀 NOVO: Diálogo de Confirmação antes de excluir o hábito
  void _showDeleteConfirmationDialog(
    BuildContext context,
    WidgetRef ref,
    String habitId,
    String habitTitle,
  ) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF11182E),
        title: const Text(
          "Excluir Hábito",
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: Text(
          "Deseja realmente excluir o hábito \"$habitTitle\"? Todo o histórico de progresso será perdido.",
          style: const TextStyle(color: Colors.white70, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              "Cancelar",
              style: TextStyle(color: Colors.white54),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () async {
              // Passa o id e o título para garantir a limpeza completa
              await ref
                  .read(habitsRepositoryProvider)
                  .deleteHabit(habitId, habitTitle);
              if (context.mounted) Navigator.pop(context);
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
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final habitsAsync = ref.watch(habitsStreamProvider);
    final todayStr = DateFormat('yyyy-MM-dd').format(DateTime.now());

    // Algoritmo para descobrir as datas da semana atual (Segunda a Domingo)
    final now = DateTime.now();
    final monday = now.subtract(Duration(days: now.weekday - 1));
    final weekDays = List.generate(
      7,
      (index) => monday.add(Duration(days: index)),
    );

    return Scaffold(
      backgroundColor: const Color(0xFF070B14),
      floatingActionButton: FloatingActionButton(
        backgroundColor: Colors.cyanAccent,
        onPressed: () => _showAddHabitDialog(context, ref),
        child: const Icon(Icons.add, color: Colors.black),
      ),
      body: SafeArea(
        child: habitsAsync.when(
          loading: () => const Center(
            child: CircularProgressIndicator(color: Colors.cyanAccent),
          ),
          error: (err, stack) => Center(
            child: Text(
              "Erro: $err",
              style: const TextStyle(color: Colors.red),
            ),
          ),
          data: (habits) {
            // 🚀 Cálculo do Progresso de Hoje para o Banner Superior
            final totalHabits = habits.length;
            final completedTodayCount = habits
                .where((h) => h.completedDates.contains(todayStr))
                .length;
            final progressPercent = totalHabits > 0
                ? completedTodayCount / totalHabits
                : 0.0;

            return Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "Rastreador de Hábitos",
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    "Construa consistência através de rituais diários",
                    style: TextStyle(color: Colors.white54, fontSize: 14),
                  ),
                  const SizedBox(height: 20),

                  // 🚀 NOVO: Banner de Resumo Diário
                  if (totalHabits > 0)
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF11182E),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: Colors.cyanAccent.withOpacity(0.2),
                        ),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  "Progresso de Hoje",
                                  style: TextStyle(
                                    color: Colors.white54,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  "$completedTodayCount de $totalHabits concluídos",
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Stack(
                            alignment: Alignment.center,
                            children: [
                              CircularProgressIndicator(
                                value: progressPercent,
                                backgroundColor: Colors.white10,
                                color: Colors.cyanAccent,
                                strokeWidth: 6,
                              ),
                              Text(
                                "${(progressPercent * 100).toInt()}%",
                                style: const TextStyle(
                                  color: Colors.cyanAccent,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),

                  const SizedBox(height: 20),

                  Expanded(
                    child: totalHabits == 0
                        ? const Center(
                            child: Text(
                              "Nenhum ritual ativo. Clique no + para começar! ⚡",
                              style: TextStyle(color: Colors.white38),
                              textAlign: TextAlign.center,
                            ),
                          )
                        : ListView.builder(
                            itemCount: habits.length,
                            itemBuilder: (context, index) {
                              final habit = habits[index];
                              bool isDoneToday = habit.completedDates.contains(
                                todayStr,
                              );

                              return Container(
                                margin: const EdgeInsets.only(bottom: 16),
                                padding: const EdgeInsets.all(16),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF11182E),
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(
                                    color: isDoneToday
                                        ? Colors.cyanAccent.withOpacity(0.3)
                                        : Colors.white10,
                                  ),
                                ),
                                child: Column(
                                  children: [
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      children: [
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                habit.title,
                                                style: TextStyle(
                                                  color: isDoneToday
                                                      ? Colors.cyanAccent
                                                      : Colors.white,
                                                  fontSize: 18,
                                                  fontWeight: FontWeight.bold,
                                                  decoration: isDoneToday
                                                      ? TextDecoration
                                                            .lineThrough
                                                      : null,
                                                ),
                                              ),
                                              const SizedBox(height: 4),
                                              // Indicador simples de dias concluidos totais
                                              Row(
                                                children: [
                                                  const Icon(
                                                    Icons
                                                        .local_fire_department_rounded,
                                                    color: Colors.orangeAccent,
                                                    size: 14,
                                                  ),
                                                  const SizedBox(width: 4),
                                                  Text(
                                                    "${habit.completedDates.length} dias no total",
                                                    style: const TextStyle(
                                                      color: Colors.white38,
                                                      fontSize: 11,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ],
                                          ),
                                        ),
                                        Row(
                                          children: [
                                            IconButton(
                                              icon: Icon(
                                                isDoneToday
                                                    ? Icons.check_box
                                                    : Icons
                                                          .check_box_outline_blank,
                                                color: isDoneToday
                                                    ? Colors.cyanAccent
                                                    : Colors.white54,
                                                size: 28,
                                              ),
                                              onPressed: () async {
                                                await ref
                                                    .read(
                                                      habitsRepositoryProvider,
                                                    )
                                                    .toggleHabitToday(
                                                      habit.id,
                                                      habit.completedDates,
                                                    );
                                              },
                                            ),
                                            IconButton(
                                              icon: const Icon(
                                                Icons.delete_outline,
                                                color: Colors.white24,
                                                size: 20,
                                              ),
                                              onPressed: () =>
                                                  _showDeleteConfirmationDialog(
                                                    context,
                                                    ref,
                                                    habit.id,
                                                    habit.title,
                                                  ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                    const Divider(
                                      color: Colors.white10,
                                      height: 20,
                                    ),

                                    // 🚀 Matriz dos 7 dias da Semana INTERATIVA
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      children: weekDays.map((day) {
                                        final dayStr = DateFormat(
                                          'yyyy-MM-dd',
                                        ).format(day);
                                        final isCompleted = habit.completedDates
                                            .contains(dayStr);
                                        final isDayToday = dayStr == todayStr;
                                        final dayLetter =
                                            DateFormat('E', 'pt_BR')
                                                .format(day)
                                                .substring(0, 1)
                                                .toUpperCase();

                                        return GestureDetector(
                                          onTap: () async {
                                            // Permite alternar o status de qualquer dia da semana atual
                                            List<String> updatedDates =
                                                List.from(habit.completedDates);
                                            if (isCompleted) {
                                              updatedDates.remove(dayStr);
                                            } else {
                                              updatedDates.add(dayStr);
                                            }
                                            // Utiliza o método de atualização do repositório para salvar a lista modificada
                                            await ref
                                                .read(habitsRepositoryProvider)
                                                .updateHabitDates(
                                                  habit.id,
                                                  updatedDates,
                                                );
                                          },
                                          child: Column(
                                            children: [
                                              Text(
                                                dayLetter,
                                                style: TextStyle(
                                                  color: isDayToday
                                                      ? Colors.cyanAccent
                                                      : Colors.white38,
                                                  fontSize: 11,
                                                  fontWeight: isDayToday
                                                      ? FontWeight.bold
                                                      : FontWeight.normal,
                                                ),
                                              ),
                                              const SizedBox(height: 6),
                                              Container(
                                                width: 26,
                                                height: 26,
                                                decoration: BoxDecoration(
                                                  color: isCompleted
                                                      ? Colors.cyanAccent
                                                      : const Color(0xFF070B14),
                                                  borderRadius:
                                                      BorderRadius.circular(6),
                                                  border: Border.all(
                                                    color: isDayToday
                                                        ? Colors.cyanAccent
                                                        : Colors.white10,
                                                    width: isDayToday ? 1.5 : 1,
                                                  ),
                                                ),
                                                child: isCompleted
                                                    ? const Icon(
                                                        Icons.check,
                                                        color: Colors.black,
                                                        size: 16,
                                                      )
                                                    : null,
                                              ),
                                            ],
                                          ),
                                        );
                                      }).toList(),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
