import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/features/focus/presentation/providers/providers/focus_provider.dart';
import 'package:life_os/features/tasks/presentation/providers/tasks_provider.dart';
import 'package:life_os/features/study/presentation/providers/study_provider.dart';

class TargetSelectionScreen extends ConsumerWidget {
  const TargetSelectionScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref.watch(tasksStreamProvider);
    final subjects = ref.watch(subjectsStreamProvider);

    return Scaffold(
      backgroundColor: const Color(0xFF070B14),
      appBar: AppBar(
        backgroundColor: const Color(0xFF11182E),
        title: const Text(
          "O que vamos focar?",
          style: TextStyle(color: Colors.white),
        ),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // --- SEÇÃO DE TAREFAS ---
          _buildSectionTitle("Minhas Tarefas"),
          tasks.when(
            data: (list) => Column(
              children: list
                  .map(
                    (t) => _buildItem(
                      context,
                      ref,
                      t.id,
                      t.title,
                      FocusTargetType.task,
                      Icons.check_circle_outline,
                    ),
                  )
                  .toList(),
            ),
            loading: () => const Padding(
              padding: EdgeInsets.all(20),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (error, stack) => const SizedBox(),
          ),

          const SizedBox(height: 30),

          // --- SEÇÃO DE MATÉRIAS DE ESTUDO ---
          _buildSectionTitle("Matérias de Estudo"),
          subjects.when(
            data: (list) => Column(
              children: list
                  .map(
                    (s) => _buildItem(
                      context,
                      ref,
                      s.id,
                      s.title,
                      FocusTargetType.subject,
                      Icons.menu_book,
                    ),
                  )
                  .toList(),
            ),
            loading: () => const SizedBox(),
            error: (error, stack) => const SizedBox(),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 8, bottom: 10),
      child: Text(
        title,
        style: const TextStyle(
          color: Colors.white54,
          fontWeight: FontWeight.bold,
          fontSize: 14,
        ),
      ),
    );
  }

  Widget _buildItem(
    BuildContext context,
    WidgetRef ref,
    String id,
    String title,
    FocusTargetType targetType,
    IconData icon,
  ) {
    return Card(
      color: const Color(0xFF11182E),
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        leading: Icon(icon, color: Colors.purpleAccent),
        title: Text(title, style: const TextStyle(color: Colors.white)),
        trailing: const Icon(Icons.chevron_right, color: Colors.white24),
        onTap: () {
          ref.read(focusProvider.notifier).selectTarget(id, title, targetType);
          Navigator.pop(context); // Retorna ao timer
        },
      ),
    );
  }
}
