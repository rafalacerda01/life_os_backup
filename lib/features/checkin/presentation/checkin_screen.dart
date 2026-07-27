import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'providers/checkin_controller.dart';

class CheckInScreen extends ConsumerWidget {
  const CheckInScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 1. Escuta o estado atual vindo do Controller
    final state = ref.watch(checkInControllerProvider);
    // 2. Acesso aos métodos do Controller (sem disparar rebuilds)
    final controller = ref.read(checkInControllerProvider.notifier);

    return Scaffold(
      backgroundColor: const Color(0xFF070B14),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          "Check-in de Estado",
          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
        ),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "Como está seu alinhamento hoje?",
              style: TextStyle(color: Colors.white70, fontSize: 14),
            ),
            const SizedBox(height: 30),

            // Reagindo e enviando ações para o Controller
            _buildSliderRow(
              "Nível de Energia ⚡",
              state.energy,
              controller.updateEnergy,
            ),
            const SizedBox(height: 24),
            _buildSliderRow(
              "Capacidade de Foco 🎯",
              state.focus,
              controller.updateFocus,
            ),
            const SizedBox(height: 24),
            _buildSliderRow(
              "Motivação Interna 🚀",
              state.motivation,
              controller.updateMotivation,
            ),
            const Spacer(),

            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF5D0EFF),
                minimumSize: const Size(double.infinity, 56),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              // Desabilita o botão se estiver carregando
              onPressed: state.isLoading
                  ? null
                  : () {
                      // Dispara a lógica de negócio no controller
                      controller.submitCheckIn(
                        onSuccess: () {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                "Estado sincronizado no ecossistema.",
                              ),
                              backgroundColor: Colors.green,
                            ),
                          );
                          Navigator.pop(context);
                        },
                        onError: (error) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                "Erro ao registrar métricas: $error",
                              ),
                              backgroundColor: Colors.red,
                            ),
                          );
                        },
                      );
                    },
              child: state.isLoading
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2.5,
                      ),
                    )
                  : const Text(
                      "Registrar Métricas",
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSliderRow(
    String label,
    double value,
    ValueChanged<double> onChanged,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 15,
          ),
        ),
        Row(
          children: [
            const Text(
              "Min",
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
            Expanded(
              child: Slider(
                value: value,
                min: 1.0,
                max: 5.0,
                divisions: 4,
                activeColor: const Color(0xFFB026FF),
                inactiveColor: Colors.white10,
                onChanged: onChanged,
              ),
            ),
            const Text(
              "Max",
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
          ],
        ),
      ],
    );
  }
}
