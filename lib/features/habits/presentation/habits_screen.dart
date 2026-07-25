import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:life_os/features/habits/presentation/providers/habits_provider.dart';

class HabitsScreen extends ConsumerWidget {
  const HabitsScreen({super.key});

  void _showAddHabitDialog(BuildContext context, WidgetRef ref) {
    final controller = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF11182E),
        title: const Text("Monitorar Novo Hábito", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
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
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancelar", style: TextStyle(color: Colors.white54))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.cyanAccent),
            onPressed: () async {
              if (controller.text.isNotEmpty) {
                await ref.read(habitsRepositoryProvider).addHabit(controller.text);
                if (context.mounted) Navigator.pop(context);
              }
            },
            child: const Text("Iniciar", style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
          )
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
    final weekDays = List.generate(7, (index) => monday.add(Duration(days: index)));

    return Scaffold(
      backgroundColor: const Color(0xFF070B14),
      floatingActionButton: FloatingActionButton(
        backgroundColor: Colors.cyanAccent,
        onPressed: () => _showAddHabitDialog(context, ref),
        child: const Icon(Icons.add, color: Colors.black),
      ),
      body: SafeArea(
        child: habitsAsync.when(
          loading: () => const Center(child: CircularProgressIndicator(color: Colors.cyanAccent)),
          error: (err, stack) => Center(child: Text("Erro: $err", style: const TextStyle(color: Colors.red))),
          data: (habits) {
            return Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text("Rastreador de Hábitos", style: TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  const Text("Construa consistência através de rituais diários", style: TextStyle(color: Colors.white54, fontSize: 14)),
                  const SizedBox(height: 25),

                  Expanded(
                    child: habits.isEmpty
                        ? const Center(child: Text("Nenhum ritual ativo. Clique no + para começar! ⚡", style: TextStyle(color: Colors.white38)))
                        : ListView.builder(
                            itemCount: habits.length,
                            itemBuilder: (context, index) {
                              final habit = habits[index];
                              bool isDoneToday = habit.completedDates.contains(todayStr);

                              return Container(
                                margin: const EdgeInsets.only(bottom: 16),
                                padding: const EdgeInsets.all(16),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF11182E),
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(color: isDoneToday ? Colors.cyanAccent.withOpacity(0.3) : Colors.white10),
                                ),
                                child: Column(
                                  children: [
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        Expanded(
                                          child: Text(
                                            habit.title,
                                            style: TextStyle(
                                              color: isDoneToday ? Colors.cyanAccent : Colors.white,
                                              fontSize: 18,
                                              fontWeight: FontWeight.bold,
                                              decoration: isDoneToday ? TextDecoration.lineThrough : null,
                                            ),
                                          ),
                                        ),
                                        Row(
                                          children: [
                                            IconButton(
                                              icon: Icon(
                                                isDoneToday ? Icons.check_box : Icons.check_box_outline_blank,
                                                color: isDoneToday ? Colors.cyanAccent : Colors.white54,
                                                size: 28,
                                              ),
                                              onPressed: () async {
                                                await ref.read(habitsRepositoryProvider).toggleHabitToday(habit.id, habit.completedDates);
                                              },
                                            ),
                                            IconButton(
                                              icon: const Icon(Icons.delete_outline, color: Colors.white24, size: 20),
                                              onPressed: () async {
                                                await ref.read(habitsRepositoryProvider).deleteHabit(habit.id);
                                              },
                                            ),
                                          ],
                                        )
                                      ],
                                    ),
                                    const Divider(color: Colors.white10, height: 20),
                                    
                                    // Matriz dos 7 dias da Semana
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: weekDays.map((day) {
                                        final dayStr = DateFormat('yyyy-MM-dd').format(day);
                                        final isCompleted = habit.completedDates.contains(dayStr);
                                        final isDayToday = dayStr == todayStr;
                                        final dayLetter = DateFormat('E').format(day).substring(0, 1).toUpperCase();

                                        return Column(
                                          children: [
                                            Text(dayLetter, style: TextStyle(color: isDayToday ? Colors.cyanAccent : Colors.white38, fontSize: 11, fontWeight: isDayToday ? FontWeight.bold : FontWeight.normal)),
                                            const SizedBox(height: 6),
                                            Container(
                                              width: 24,
                                              height: 24,
                                              decoration: BoxDecoration(
                                                color: isCompleted ? Colors.cyanAccent : const Color(0xFF070B14),
                                                borderRadius: BorderRadius.circular(6),
                                                border: Border.all(color: isDayToday ? Colors.cyanAccent : Colors.white10),
                                              ),
                                              child: isCompleted ? const Icon(Icons.check, color: Colors.black, size: 14) : null,
                                            ),
                                          ],
                                        );
                                      }).toList(),
                                    )
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