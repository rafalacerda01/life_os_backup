import 'package:flutter/material.dart';
import 'package:life_os/core/runtime/app_runtime_mode.dart';
import 'providers/check_in_provider.dart';
import 'package:life_os/core/services/emulator_account_runtime.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'providers/checkin_controller.dart';

class CheckInScreen extends ConsumerWidget {
  const CheckInScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 1. Escuta o estado atual vindo do Controller
    final isLocal =
        ref.watch(appRuntimeModeProvider) == AppRuntimeMode.localFirst;
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
            if (isLocal)
              const _LocalCheckInHistory()
            else if (ref.watch(emulatorAccountRuntimeProvider) != null)
              ref
                  .watch(checkInHistoryProvider)
                  .when(
                    data: (entries) => Text(
                      entries.isEmpty
                          ? 'Sem registros anteriores.'
                          : 'Último registro: ${entries.first.energy} / ${entries.first.focus} / ${entries.first.motivation}',
                      key: const ValueKey('checkin-history'),
                    ),
                    loading: () => const Text('Carregando registros…'),
                    error: (e, s) => const Text('Histórico indisponível.'),
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
                              content: Text("Check-in salvo."),
                              backgroundColor: Colors.green,
                            ),
                          );
                          if (!isLocal &&
                              ref.read(emulatorAccountRuntimeProvider) ==
                                  null &&
                              Navigator.canPop(context))
                            Navigator.pop(context);
                        },
                        onError: () {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                "Não foi possível registrar seu check-in. Tente novamente.",
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
                key: ValueKey(label),
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

class _LocalCheckInHistory extends ConsumerWidget {
  const _LocalCheckInHistory();
  @override
  Widget build(BuildContext context, WidgetRef ref) => Row(
    children: [
      Expanded(
        child: ref
            .watch(checkInHistoryProvider)
            .when(
              data: (entries) => Text(
                entries.isEmpty
                    ? 'Sem registros anteriores.'
                    : 'Último registro: ${entries.first.energy} / ${entries.first.focus} / ${entries.first.motivation}',
                key: const ValueKey('checkin-history'),
                maxLines: 2,
              ),
              loading: () => const Text('Carregando registros…'),
              error: (error, stack) => const Text('Histórico indisponível.'),
            ),
      ),
      TextButton(
        key: const ValueKey('checkin-open-history'),
        onPressed: () => showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          builder: (sheetContext) => SizedBox(
            height: MediaQuery.sizeOf(context).height * .65,
            child: SafeArea(
              child: Consumer(
                builder: (context, ref, child) => ref
                    .watch(checkInHistoryProvider)
                    .when(
                      loading: () =>
                          const Center(child: CircularProgressIndicator()),
                      error: (error, stack) =>
                          const Center(child: Text('Histórico indisponível.')),
                      data: (entries) => entries.isEmpty
                          ? const Center(
                              child: Text('Sem check-ins registrados.'),
                            )
                          : ListView.builder(
                              itemCount: entries.length,
                              itemBuilder: (context, index) {
                                final entry = entries[index];
                                return ListTile(
                                  title: Text(entry.id),
                                  subtitle: Text(
                                    '${entry.energy} / ${entry.focus} / ${entry.motivation}',
                                  ),
                                  trailing: IconButton(
                                    key: ValueKey('checkin-delete-${entry.id}'),
                                    tooltip: 'Excluir check-in',
                                    icon: const Icon(Icons.delete_outline),
                                    onPressed: () async {
                                      final confirmed = await showDialog<bool>(
                                        context: context,
                                        builder: (context) => AlertDialog(
                                          title: const Text('Excluir check-in'),
                                          content: Text(
                                            'Excluir o registro local de ${entry.id}?',
                                          ),
                                          actions: [
                                            TextButton(
                                              onPressed: () =>
                                                  Navigator.pop(context, false),
                                              child: const Text('Cancelar'),
                                            ),
                                            TextButton(
                                              onPressed: () =>
                                                  Navigator.pop(context, true),
                                              child: const Text('Excluir'),
                                            ),
                                          ],
                                        ),
                                      );
                                      if (confirmed != true || !context.mounted)
                                        return;
                                      try {
                                        await ref
                                            .read(checkInRepositoryProvider)
                                            .deleteLocalDailyMetrics(entry.id);
                                      } catch (error) {
                                        if (context.mounted)
                                          ScaffoldMessenger.of(
                                            context,
                                          ).showSnackBar(
                                            const SnackBar(
                                              content: Text(
                                                'Não foi possível excluir o registro. Tente novamente.',
                                              ),
                                            ),
                                          );
                                      }
                                    },
                                  ),
                                );
                              },
                            ),
                    ),
              ),
            ),
          ),
        ),
        child: const Text('Histórico'),
      ),
    ],
  );
}
