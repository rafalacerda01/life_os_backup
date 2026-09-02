import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:life_os/features/analytics/presentation/analytics_provider.dart';
import 'package:life_os/features/premium/presentation/premium_provider.dart';
import 'package:life_os/features/ai_companion/presentation/providers/ai_companion_provider.dart';
import 'package:life_os/features/ai_companion/presentation/ai_companion_screen.dart';
import 'package:life_os/features/premium/domain/services/feature_gate.dart';

class AnalyticsScreen extends ConsumerWidget {
  const AnalyticsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final analyticsData = ref.watch(analyticsProvider);
    final premiumStatus = ref.watch(premiumProvider);
    const featureGate = FeatureGate();

    final canAccessAdvancedAnalytics = featureGate.canAccess(
      status: premiumStatus,
      feature: PremiumFeature.analyticsAdvanced,
    );

    final canAccessAiCompanion = featureGate.canAccess(
      status: premiumStatus,
      feature: PremiumFeature.aiCompanion,
    );
    return Scaffold(
      backgroundColor: const Color(0xFF070B14),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          "Inteligência Analítica",
          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // CARD DO GRÁFICO DE EVOLUÇÃO SEMANAL
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFF11182E),
                borderRadius: BorderRadius.circular(24),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "Consistência Geral da Semana",
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Stack(
                    children: [
                      // Renderização do gráfico via injeção de layout nativo adaptável
                      SizedBox(
                        height: 160,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: analyticsData.weeklyEvolution.map((day) {
                            return Column(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                Container(
                                  width: 14,
                                  height: 110 * day.scorePercentage,
                                  decoration: BoxDecoration(
                                    gradient: const LinearGradient(
                                      begin: Alignment.bottomCenter,
                                      end: Alignment.topCenter,
                                      colors: [
                                        Color(0xFF5D0EFF),
                                        Color(0xFFB026FF),
                                      ],
                                    ),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  day.dayName,
                                  style: const TextStyle(
                                    color: Colors.white54,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            );
                          }).toList(),
                        ),
                      ),

                      // Proteção Server-Side Visual (Blur/Overlay se for Free)
                      if (!canAccessAdvancedAnalytics)
                        Positioned.fill(
                          child: Container(
                            decoration: BoxDecoration(
                              color: const Color(0xFF11182E).withOpacity(0.85),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(
                                  Icons.lock_outline,
                                  color: Color(0xFFB026FF),
                                  size: 28,
                                ),
                                const SizedBox(height: 8),
                                const Text(
                                  "Gráfico Semanal Premium",
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  "Desbloqueie o acesso na aba Premium.",
                                  style: TextStyle(
                                    color: Colors.white.withOpacity(0.4),
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(height: 25),
            const Text(
              "Índices de Consistência",
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),

            // SEÇÃO DE PROGRESSO DOS ÍNDICES INDIVIDUAIS
            _buildMetricProgressRow(
              "Produtividade Continuada",
              analyticsData.productivityIndex,
              Colors.purpleAccent,
            ),
            _buildMetricProgressRow(
              "Equilíbrio Biométrico (Saúde)",
              analyticsData.healthIndex,
              Colors.greenAccent,
            ),
            _buildMetricProgressRow(
              "Eficiência de Aporte Financeiro",
              analyticsData.financeIndex,
              Colors.blueAccent,
            ),
            _buildMetricProgressRow(
              "Retenção de Hábitos Criados",
              analyticsData.habitConsistency,
              Colors.amberAccent,
            ),

            const SizedBox(height: 25),

            // BOTÃO DO AI COACH INTEGRADO PARA USUÁRIOS PREMIUM
            if (canAccessAiCompanion) ...[
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () async {
                    final expectedUserId =
                        FirebaseAuth.instance.currentUser?.uid;
                    if (expectedUserId == null || expectedUserId.isEmpty) {
                      return;
                    }

                    final admittedAnalyticsData = ref.read(analyticsProvider);
                    final analyticsContext = {
                      "productivityIndex":
                          admittedAnalyticsData.productivityIndex,
                      "healthIndex": admittedAnalyticsData.healthIndex,
                      "financeIndex": admittedAnalyticsData.financeIndex,
                      "habitConsistency":
                          admittedAnalyticsData.habitConsistency,
                      "weeklyEvolution": admittedAnalyticsData.weeklyEvolution
                          .map(
                            (e) => {
                              "dayName": e.dayName,
                              "scorePercentage": e.scorePercentage,
                            },
                          )
                          .toList(),
                    };

                    await ref
                        .read(aiCompanionProvider.notifier)
                        .sendMessage(
                          "Faça uma análise detalhada da minha performance semanal com base nestes dados atuais do sistema.",
                          analyticsContext,
                          expectedUserId: expectedUserId,
                        );

                    if (context.mounted) {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const AICompanionScreen(),
                        ),
                      );
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF5D0EFF),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  icon: const Icon(Icons.auto_awesome),
                  label: const Text(
                    "Analisar meus dados com a IA",
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildMetricProgressRow(String label, double value, Color barColor) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12.0),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF11182E),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                Text(
                  "${NumberFormat('0.0', 'pt_BR').format(value)}%",
                  style: TextStyle(
                    color: barColor,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: (value / 100).clamp(0.0, 1.0),
                backgroundColor: Colors.white10,
                valueColor: AlwaysStoppedAnimation<Color>(barColor),
                minHeight: 6,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
