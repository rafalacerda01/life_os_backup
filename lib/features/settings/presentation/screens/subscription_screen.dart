import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:life_os/features/auth/presentation/providers/auth_provider.dart';
import 'package:life_os/features/premium/domain/entities/premium_status_entity.dart';
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
                _buildStatusCard(premiumState),
                const SizedBox(height: 30),
                // CORRIGIMOS AQUI TAMBÉM
                if (premiumState.isPremium) ...[
                  _buildBenefitsSection(),
                  const SizedBox(height: 20),
                  OutlinedButton.icon(
                    onPressed: () => _manageSubscription(context, ref),
                    icon: const Icon(Icons.open_in_new_rounded),
                    label: const Text('Gerenciar assinatura na Google Play'),
                  ),
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
                      "Assinar Premium",
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

  Widget _buildStatusCard(PremiumStatusEntity status) {
    final isPremium = status.isPremium;
    final plan = switch (status.tier) {
      PremiumTier.monthly => 'Plano Premium mensal',
      PremiumTier.annual => 'Plano Premium anual',
      PremiumTier.free => 'Plano gratuito',
    };
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
            plan,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            isPremium
                ? _premiumExpiryText(status.expirationDate)
                : 'Use os recursos essenciais ou conheça os planos Premium.',
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
        _buildFeatureItem('Companion IA disponível com limites de uso'),
        _buildFeatureItem('Limites de criação ampliados'),
        _buildFeatureItem('Análises avançadas de evolução'),
        _buildFeatureItem('Focus e check-ins incluídos'),
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

  String _premiumExpiryText(DateTime? expirationDate) {
    if (expirationDate == null) return 'Assinatura validada pela Google Play.';
    return 'Válida até '
        '${DateFormat('dd/MM/yyyy').format(expirationDate.toLocal())}.';
  }

  Future<void> _manageSubscription(BuildContext context, WidgetRef ref) async {
    final opened = await ref.read(subscriptionManagementLauncherProvider)();
    if (context.mounted && !opened) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Não foi possível abrir a Google Play.')),
      );
    }
  }
}
