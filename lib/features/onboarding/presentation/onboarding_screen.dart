import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:life_os/features/onboarding/presentation/onboarding_provider.dart';
import 'package:life_os/features/settings/presentation/providers/analytics_provider.dart';

class OnboardingScreen extends ConsumerWidget {
  const OnboardingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final onboardingState = ref.watch(onboardingProvider);
    final analyticsState = ref.watch(analyticsPreferenceProvider);
    final canContinue =
        !onboardingState.operationInProgress &&
        !analyticsState.operationInProgress;

    Future<void> finishOnboarding() async {
      final completed = await ref
          .read(onboardingProvider.notifier)
          .completeOnboarding();
      if (completed && context.mounted) {
        context.go('/login');
      }
    }

    return Scaffold(
      backgroundColor: const Color(0xFF070B14),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 40),
              const Text(
                "Seu Life OS começa aqui",
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                "Um espaço para organizar sua rotina e acompanhar sua evolução.",
                style: TextStyle(color: Colors.white54, fontSize: 15),
              ),
              const SizedBox(height: 30),
              Expanded(
                child: ListView(
                  children: const [
                    _OnboardingPillar(
                      icon: Icons.calendar_today_outlined,
                      title: "Organize sua rotina",
                      description:
                          "Reúna tarefas, hábitos e estudos em um só lugar.",
                    ),
                    SizedBox(height: 14),
                    _OnboardingPillar(
                      icon: Icons.insights_outlined,
                      title: "Acompanhe sua evolução",
                      description:
                          "Visualize seu progresso com clareza ao longo do tempo.",
                    ),
                    SizedBox(height: 14),
                    _OnboardingPillar(
                      icon: Icons.shield_outlined,
                      title: "Mantenha seus dados sob controle",
                      description:
                          "Gerencie suas preferências e sua experiência no Life OS.",
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 20),
                child: Column(
                  children: [
                    SwitchListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 4,
                      ),
                      tileColor: const Color(0xFF11182E),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      title: const Text(
                        "Ajude a melhorar o Life OS",
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      subtitle: const Text(
                        "Compartilhar métricas de uso para nos ajudar a entender quais recursos são mais úteis. Nenhum conteúdo de saúde, finanças ou IA é enviado pelo Analytics.",
                        style: TextStyle(color: Colors.white54),
                      ),
                      value: analyticsState.isEnabled,
                      activeColor: const Color(0xFFB026FF),
                      onChanged:
                          analyticsState.status ==
                                  AnalyticsPreferenceStatus.loading ||
                              analyticsState.operationInProgress
                          ? null
                          : (enabled) async {
                              await ref
                                  .read(analyticsPreferenceProvider.notifier)
                                  .setEnabled(enabled);
                            },
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: canContinue
                              ? const Color(0xFF5D0EFF)
                              : const Color(0xFF11182E),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        onPressed: canContinue ? finishOnboarding : null,
                        child: Text(
                          "Continuar",
                          style: TextStyle(
                            color: canContinue ? Colors.white : Colors.white24,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: canContinue ? finishOnboarding : null,
                      child: const Text(
                        "Pular",
                        style: TextStyle(color: Colors.white54),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OnboardingPillar extends StatelessWidget {
  const _OnboardingPillar({
    required this.icon,
    required this.title,
    required this.description,
  });

  final IconData icon;
  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF11182E),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          const SizedBox(width: 2),
          Icon(icon, color: const Color(0xFFB026FF), size: 24),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: const TextStyle(color: Colors.white54, height: 1.35),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
