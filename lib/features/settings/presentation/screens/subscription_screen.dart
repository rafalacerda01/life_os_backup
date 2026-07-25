import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/features/auth/presentation/providers/auth_provider.dart';
import 'package:life_os/features/premium/presentation/premium_screen.dart';
import 'package:life_os/features/premium/presentation/premium_provider.dart';

class SubscriptionScreen extends ConsumerWidget {
  const SubscriptionScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authNotifierProvider);
    // ADICIONAMOS ESTA LINHA: Agora a tela escuta o status Premium em tempo real
    final premiumState = ref.watch(premiumProvider);

    return Scaffold(
      backgroundColor: const Color(0xFF070B14),
      appBar: AppBar(
        backgroundColor: const Color(0xFF11182E),
        title: const Text(
          "Assinatura Premium",
          style: TextStyle(color: Colors.white),
        ),
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: authState.maybeWhen(
            authenticated: (user) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // CORRIGIMOS AQUI: Passamos a usar a variável do premiumProvider
                _buildStatusCard(premiumState.isPremium),
                const SizedBox(height: 30),
                // CORRIGIMOS AQUI TAMBÉM
                if (premiumState.isPremium) ...[
                  _buildBenefitsSection(),
                ] else ...[
                  ElevatedButton(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const PremiumScreen(),
                      ),
                    ),
                    // ... (mantenha o resto do estilo do botão igual)
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.purpleAccent,
                      minimumSize: const Size(double.infinity, 50),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      elevation: 2,
                    ),
                    child: const Text(
                      "Tornar-se PRO agora",
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            orElse: () => const Center(
              child: Padding(
                padding: EdgeInsets.all(40),
                child: CircularProgressIndicator(color: Colors.purpleAccent),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStatusCard(bool isPremium) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: const Color(0xFF11182E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isPremium ? Colors.greenAccent : Colors.amberAccent,
          width: 1.5,
        ),
      ),
      child: Column(
        children: [
          Icon(
            isPremium ? Icons.verified : Icons.lock,
            color: isPremium ? Colors.greenAccent : Colors.amberAccent,
            size: 48,
          ),
          const SizedBox(height: 16),
          Text(
            isPremium ? "Plano PRO Ativo" : "Plano Gratuito",
            style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            isPremium
                ? "Você tem acesso total à IA e rituais avançados."
                : "Desbloqueie todo o poder da inteligência artificial do Life OS.",
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white54, fontSize: 14),
          ),
        ],
      ),
    );
  }

  Widget _buildBenefitsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          "O que está incluído no seu plano:",
          style: TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 16),
        _buildFeatureItem("IA Companion Ilimitada"),
        _buildFeatureItem("Disciplinas Infinitas"),
        _buildFeatureItem("Métricas Avançadas de Evolução"),
        _buildFeatureItem("Sincronização em Tempo Real"),
      ],
    );
  }

  Widget _buildFeatureItem(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          const Icon(
            Icons.check_circle_outline,
            color: Colors.greenAccent,
            size: 20,
          ),
          const SizedBox(width: 12),
          Text(
            text,
            style: const TextStyle(color: Colors.white70, fontSize: 14),
          ),
        ],
      ),
    );
  }
}
