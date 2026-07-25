import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/features/focus/presentation/providers/providers/focus_provider.dart';
import 'package:life_os/features/focus/presentation/providers/screens/target_selection_screen.dart';

class FocusScreen extends ConsumerWidget {
  const FocusScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final focusState = ref.watch(focusProvider);

    final minutes = (focusState.durationRemaining ~/ 60).toString().padLeft(
      2,
      '0',
    );
    final seconds = (focusState.durationRemaining % 60).toString().padLeft(
      2,
      '0',
    );

    return Scaffold(
      backgroundColor: const Color(0xFF070B14),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Indicador do Alvo Selecionado
              GestureDetector(
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const TargetSelectionScreen(),
                    ),
                  );
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 15,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF11182E),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: focusState.activeTargetId == null
                          ? Colors.transparent
                          : Colors.purpleAccent,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.edit, color: Colors.white54, size: 18),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          focusState.activeTargetTitle ??
                              "Selecionar Tarefa ou Matéria",
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 32),

              // Timer Visual
              Container(
                width: 250,
                height: 250,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFF11182E),
                  border: Border.all(
                    color: focusState.isBreak
                        ? Colors.greenAccent
                        : const Color(0xFF5D0EFF),
                    width: 4,
                  ),
                ),
                alignment: Alignment.center,
                child: Text(
                  "$minutes:$seconds",
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 48,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'monospace',
                  ),
                ),
              ),

              const SizedBox(height: 24),

              // Seletor de Duração Personalizada (Atalhos rápidos de minutos)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "Duração da sessão:",
                    style: TextStyle(
                      color: Colors.white54,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _buildDurationChip(
                        ref,
                        focusState,
                        label: '1m',
                        minutes: 1,
                      ),
                      const SizedBox(width: 8),
                      _buildDurationChip(
                        ref,
                        focusState,
                        label: '3m',
                        minutes: 3,
                      ),
                      const SizedBox(width: 8),
                      _buildDurationChip(
                        ref,
                        focusState,
                        label: '10m',
                        minutes: 10,
                      ),
                      const SizedBox(width: 8),
                      _buildDurationChip(
                        ref,
                        focusState,
                        label: '25m',
                        minutes: 25,
                      ),
                      const SizedBox(width: 8),
                      _buildDurationChip(
                        ref,
                        focusState,
                        label: '45m',
                        minutes: 45,
                      ),
                    ],
                  ),
                ],
              ),

              const SizedBox(height: 32),

              // Controles
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    iconSize: 64,
                    icon: Icon(
                      focusState.isRunning
                          ? Icons.pause_circle
                          : Icons.play_circle,
                    ),
                    color: focusState.activeTargetId == null
                        ? Colors.white24
                        : const Color(0xFFB026FF),
                    onPressed: focusState.activeTargetId == null
                        ? () {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  "Selecione uma tarefa ou matéria primeiro!",
                                ),
                                duration: Duration(seconds: 2),
                              ),
                            );
                          }
                        : () => focusState.isRunning
                              ? ref.read(focusProvider.notifier).pauseTimer()
                              : ref.read(focusProvider.notifier).startTimer(),
                  ),
                  const SizedBox(width: 24),
                  IconButton(
                    iconSize: 44,
                    icon: const Icon(Icons.refresh),
                    color: Colors.white54,
                    onPressed: () =>
                        ref.read(focusProvider.notifier).resetTimer(),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Widget auxiliar para construir os botões de seleção de tempo com segurança
  Widget _buildDurationChip(
    WidgetRef ref,
    FocusState focusState, {
    required String label,
    required int minutes,
  }) {
    final currentMinutes = focusState.durationRemaining ~/ 60;
    final isSelected = currentMinutes == minutes && !focusState.isBreak;

    return ChoiceChip(
      label: Text(label),
      selected: isSelected,
      onSelected: focusState.isRunning
          ? null // Bloqueia alteração se o timer estiver rodando ativamente
          : (selected) {
              if (selected) {
                ref.read(focusProvider.notifier).setCustomDuration(minutes);
              }
            },
      selectedColor: const Color(0xFF5D0EFF),
      backgroundColor: const Color(0xFF11182E),
      labelStyle: TextStyle(
        color: isSelected ? Colors.white : Colors.white60,
        fontWeight: FontWeight.bold,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: isSelected ? Colors.purpleAccent : Colors.transparent,
        ),
      ),
    );
  }
}
