import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
}
