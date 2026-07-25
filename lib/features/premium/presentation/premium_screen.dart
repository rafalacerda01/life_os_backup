import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/features/premium/presentation/premium_provider.dart';
import 'package:life_os/features/premium/domain/entities/premium_status_entity.dart';

class PremiumScreen extends ConsumerWidget {
  const PremiumScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final premiumState = ref.watch(premiumProvider);

    return Scaffold(
      backgroundColor: const Color(0xFF070B14),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          "Acesso Cyber-Premium",
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          TextButton(
            onPressed: () {
              ref.read(premiumProvider.notifier).restorePurchase();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text("Histórico de compras verificado."),
                ),
              );
            },
            child: const Text(
              "Restaurar",
              style: TextStyle(color: Colors.white54),
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // CARD DE STATUS ATUAL
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF5D0EFF), Color(0xFFB026FF)],
                ),
                borderRadius: BorderRadius.circular(24),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    premiumState.isPremium
                        ? "SISTEMA OPERACIONAL DESBLOQUEADO"
                        : "NÍVEL DE ACESSO: FREE",
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    premiumState.isPremium
                        ? "Você possui acesso irrestrito a todos os módulos neurais."
                        : "Atualize sua licença para desbloquear a inteligência analítica e o motor de IA.",
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.8),
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 30),
            const Text(
              "Comparativo de Arquitetura",
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),

            // TABELA COMPARATIVA ATRIBUTOS
            _buildComparisonRow(
              "Acesso à IA do Sistema",
              "Bloqueado",
              "Ilimitado",
              true,
            ),
            _buildComparisonRow(
              "Gráficos Analytics Semanais",
              "Básico",
              "Avançado",
              false,
            ),
            _buildComparisonRow(
              "Módulos de Finanças & Estudos",
              "Apenas Leitura",
              "Escrita Total",
              false,
            ),
            _buildComparisonRow(
              "Suporte a Subtarefas e Anexos",
              "Não possui",
              "Ilimitado",
              false,
            ),

            const SizedBox(height: 35),

            // BOTÕES DE CHECKOUT PROTEGIDO
            if (!premiumState.isPremium) ...[
              _buildCheckoutButton(
                context,
                ref,
                tier: PremiumTier.monthly,
                title: "Assinar Mensal",
                subtitle: "R\$ 19,90 / mês",
                backgroundColor: const Color(0xFF1E2640),
                borderColor: Colors.white24,
              ),
              const SizedBox(height: 16),
              _buildCheckoutButton(
                context,
                ref,
                tier: PremiumTier.annual,
                title: "Assinar Anual (Recomendado)",
                subtitle: "R\$ 149,90 / ano",
                backgroundColor: const Color(0xFFB026FF),
                borderColor: Colors.transparent,
              ),
            ] else ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.greenAccent.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: Colors.greenAccent.withOpacity(0.4),
                  ),
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.verified, color: Colors.greenAccent),
                    SizedBox(width: 8),
                    Text(
                      "Sua assinatura está ativa e segura",
                      style: TextStyle(
                        color: Colors.greenAccent,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _showProcessingDialog(BuildContext context) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const AlertDialog(
        backgroundColor: Color(0xFF11182E),
        content: Row(
          children: [
            CircularProgressIndicator(color: Color(0xFF5D0EFF)),
            SizedBox(width: 20),
            Text(
              "Handshake de Segurança...",
              style: TextStyle(color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildComparisonRow(
    String feature,
    String freeVal,
    String premiumVal,
    bool highlight,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            feature,
            style: TextStyle(
              color: highlight ? const Color(0xFFB026FF) : Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                "Free: $freeVal",
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
              Text(
                "Premium: $premiumVal",
                style: const TextStyle(
                  color: Colors.greenAccent,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const Divider(color: Colors.white10, height: 20),
        ],
      ),
    );
  }

  Widget _buildCheckoutButton(
    BuildContext context,
    WidgetRef ref, {
    required PremiumTier tier,
    required String title,
    required String subtitle,
    required Color backgroundColor,
    required Color borderColor,
  }) {
    return ElevatedButton(
      style: ElevatedButton.styleFrom(
        backgroundColor: backgroundColor,
        minimumSize: const Size(double.infinity, 64),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: borderColor),
        ),
        elevation: tier == PremiumTier.annual ? 4 : 0,
      ),
      onPressed: () async {
        _showProcessingDialog(context);

        try {
          final success = await ref
              .read(premiumProvider.notifier)
              .processSecureCheckout(tier);

          if (context.mounted) {
            if (success) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text("Licença assinada com sucesso!"),
                  backgroundColor: Colors.green,
                ),
              );
            } else {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text("Erro ao contatar o servidor."),
                  backgroundColor: Colors.red,
                ),
              );
            }
          }
        } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text("Erro inesperado: $e")));
          }
        } finally {
          if (context.mounted) {
            Navigator.of(context, rootNavigator: true).pop();
          }
        }
      },
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ],
      ),
    );
  }
}
