import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/features/auth/presentation/providers/auth_provider.dart';
import 'package:life_os/features/settings/presentation/providers/analytics_provider.dart';
import 'package:life_os/features/settings/presentation/providers/biometric_provider.dart';

class SecurityPrivacyScreen extends ConsumerWidget {
  const SecurityPrivacyScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Escuta apenas o estado reativo da biometria
    final biometricState = ref.watch(biometricProvider);
    final analyticsState = ref.watch(analyticsPreferenceProvider);

    return Scaffold(
      backgroundColor: const Color(0xFF070B14),
      appBar: AppBar(
        backgroundColor: const Color(0xFF11182E),
        title: const Text(
          "Segurança & Privacidade",
          style: TextStyle(color: Colors.white),
        ),
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _buildSectionHeader("Acesso"),
          SwitchListTile(
            title: const Text(
              "Biometria",
              style: TextStyle(color: Colors.white),
            ),
            subtitle: const Text(
              "Exigir FaceID/Impressão Digital",
              style: TextStyle(color: Colors.white54),
            ),
            value: biometricState.isEnabled,
            activeColor: Colors.purpleAccent,
            onChanged:
                biometricState.status == BiometricLockStatus.loading ||
                    biometricState.authenticationInProgress
                ? null
                : (val) async {
                    final success = await ref
                        .read(biometricProvider.notifier)
                        .toggleBiometrics(val);

                    if (!context.mounted) return;

                    if (!success) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            "Não foi possível confirmar a biometria. A configuração foi mantida.",
                          ),
                        ),
                      );
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            val
                                ? "Biometria ativada!"
                                : "Biometria desativada.",
                          ),
                        ),
                      );
                    }
                  },
            tileColor: const Color(0xFF11182E),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),

          const SizedBox(height: 24),
          _buildSectionHeader("Privacidade"),
          // Mantido estático por enquanto conforme escopo focado
          SwitchListTile(
            title: const Text(
              "Modo Privacidade",
              style: TextStyle(color: Colors.white),
            ),
            subtitle: const Text(
              "Ocultar valores sensíveis na tela",
              style: TextStyle(color: Colors.white54),
            ),
            value: false,
            activeColor: Colors.purpleAccent,
            onChanged: (val) {},
            tileColor: const Color(0xFF11182E),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),

          const SizedBox(height: 12),
          SwitchListTile(
            title: const Text(
              "Métricas de uso",
              style: TextStyle(color: Colors.white),
            ),
            subtitle: const Text(
              "Compartilhar métricas de uso para ajudar a melhorar o Life OS",
              style: TextStyle(color: Colors.white54),
            ),
            value: analyticsState.isEnabled,
            activeColor: Colors.purpleAccent,
            onChanged:
                analyticsState.status == AnalyticsPreferenceStatus.loading ||
                    analyticsState.operationInProgress
                ? null
                : (enabled) async {
                    final success = await ref
                        .read(analyticsPreferenceProvider.notifier)
                        .setEnabled(enabled);
                    if (!context.mounted) return;

                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          success
                              ? enabled
                                    ? "Métricas de uso ativadas."
                                    : "Métricas de uso desativadas."
                              : "Não foi possível concluir a alteração das métricas de uso.",
                        ),
                      ),
                    );
                  },
            tileColor: const Color(0xFF11182E),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),

          const SizedBox(height: 40),
          _buildSectionHeader("Zona Crítica"),
          ListTile(
            leading: const Icon(Icons.delete_forever, color: Colors.redAccent),
            title: const Text(
              "Excluir conta permanentemente",
              style: TextStyle(color: Colors.redAccent),
            ),
            tileColor: const Color(0xFF11182E),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            onTap: () => _confirmDeleteAccount(context, ref),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10, left: 5),
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(
          color: Colors.purpleAccent,
          fontSize: 12,
          fontWeight: FontWeight.bold,
          letterSpacing: 1,
        ),
      ),
    );
  }

  void _confirmDeleteAccount(BuildContext context, WidgetRef ref) {
    final TextEditingController confirmController = TextEditingController();
    bool isButtonEnabled = false;

    showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF11182E),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: const Text(
            "Excluir Conta",
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "Esta ação é irreversível. Todos os seus dados serão permanentemente apagados dos servidores.",
                style: TextStyle(color: Colors.white54),
              ),
              const SizedBox(height: 20),
              const Text(
                "Digite 'EXCLUIR' para confirmar:",
                style: TextStyle(color: Colors.white, fontSize: 12),
              ),
              TextField(
                controller: confirmController,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: Colors.redAccent),
                  ),
                ),
                onChanged: (val) {
                  setDialogState(() {
                    isButtonEnabled = val.trim().toUpperCase() == "EXCLUIR";
                  });
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text(
                "Cancelar",
                style: TextStyle(color: Colors.white70),
              ),
            ),
            TextButton(
              onPressed: isButtonEnabled
                  ? () {
                      Navigator.pop(dialogContext);
                      ref.read(authNotifierProvider.notifier).deleteAccount();
                    }
                  : null,
              child: Text(
                "EXCLUIR DEFINITIVAMENTE",
                style: TextStyle(
                  color: isButtonEnabled ? Colors.redAccent : Colors.grey,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
