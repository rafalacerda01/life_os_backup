import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/features/settings/presentation/providers/notification_provider.dart';

class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  Widget _buildSettingCard({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
    bool enabled = true,
  }) {
    return Opacity(
      opacity: enabled ? 1.0 : 0.5,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 15),
        child: SwitchListTile(
          // Passamos a cor e o formato diretamente para o Tile
          tileColor: const Color(0xFF11182E),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          title: Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
          subtitle: Text(
            subtitle,
            style: const TextStyle(color: Colors.white54),
          ),
          value: value,
          activeColor: Colors.purpleAccent,
          onChanged: enabled ? onChanged : null,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Escuta o estado global de notificações
    final state = ref.watch(notificationsProvider);
    final notifier = ref.read(notificationsProvider.notifier);

    return Scaffold(
      backgroundColor: const Color(0xFF070B14),
      appBar: AppBar(
        backgroundColor: const Color(0xFF11182E),
        title: const Text(
          "Notificações Inteligentes",
          style: TextStyle(color: Colors.white),
        ),
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _buildSettingCard(
            title: "Notificações Gerais",
            subtitle: "Habilitar todos os alertas do sistema",
            value: state.allNotifications,
            onChanged: (val) => notifier.toggleAll(val),
          ),
          const SizedBox(height: 10),
          _buildSettingCard(
            title: "Revisões do Anki",
            subtitle: "Alertas para suas sessões de repetição",
            value: state.ankiReminders,
            enabled: state.allNotifications,
            onChanged: (val) => notifier.toggleAnki(val),
          ),
          _buildSettingCard(
            title: "Lembretes de Foco",
            subtitle: "Alertas para seus blocos de trabalho",
            value: state.focusAlerts,
            enabled: state.allNotifications,
            onChanged: (val) => notifier.toggleFocus(val),
          ),
          _buildSettingCard(
            title: "Lembretes de Medicamentos",
            subtitle: "Alertas para seus medicamentos diários",
            value: state.medicationReminders,
            enabled: state.allNotifications,
            onChanged: (val) => notifier.toggleMedication(val),
          ),
        ],
      ),
    );
  }
}
