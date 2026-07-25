import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:life_os/features/onboarding/presentation/onboarding_provider.dart';

// Modelo para organizar as cores e ícones de cada área
class AreaConfig {
  final String name;
  final IconData icon;
  final Color color;

  AreaConfig(this.name, this.icon, this.color);
}

class OnboardingScreen extends ConsumerWidget {
  const OnboardingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final onboardingState = ref.watch(onboardingProvider);

    final List<AreaConfig> areas = [
      AreaConfig("Produtividade", Icons.track_changes, Colors.blueAccent),
      AreaConfig("Finanças", Icons.account_balance_wallet_outlined, Colors.greenAccent),
      AreaConfig("Estudos", Icons.school_outlined, Colors.orangeAccent),
      AreaConfig("Saúde", Icons.favorite_border, Colors.pinkAccent),
      AreaConfig("Relacionamentos", Icons.people_outline, Colors.cyanAccent),
      AreaConfig("Hábitos", Icons.refresh, Colors.purpleAccent),
    ];

    return Scaffold(
      backgroundColor: const Color(0xFF070B14),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 40),
              const Text("Vamos te conhecer melhor", 
                style: TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.bold)),
              const SizedBox(height: 10),
              const Text("Selecione as áreas que você quer melhorar na sua vida", 
                style: TextStyle(color: Colors.white54, fontSize: 15)),
              const SizedBox(height: 30),
              
              Expanded(
                child: GridView.builder(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2, 
                    crossAxisSpacing: 16, 
                    mainAxisSpacing: 16, 
                    childAspectRatio: 2.6, // Ajustado levemente para dar mais espaço
                  ),
                  itemCount: areas.length,
                  itemBuilder: (context, index) {
                    final area = areas[index];
                    final isSelected = onboardingState.selectedFocusAreas.contains(area.name);
                    
                    return InkWell(
                      onTap: () => ref.read(onboardingProvider.notifier).toggleArea(area.name),
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          color: isSelected ? area.color.withOpacity(0.15) : const Color(0xFF11182E),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: isSelected ? area.color : Colors.transparent, 
                            width: 2
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(area.icon, color: isSelected ? area.color : Colors.white60, size: 20),
                            const SizedBox(width: 8),
                            // ✅ AQUI ESTÁ A CORREÇÃO: O Expanded garante que o texto não cause overflow
                            Expanded(
                              child: Text(area.name, 
                                style: TextStyle(
                                  color: isSelected ? Colors.white : Colors.white70, 
                                  fontWeight: FontWeight.bold, 
                                  fontSize: 13 // Reduzi levemente a fonte para garantir caber
                                ),
                                overflow: TextOverflow.ellipsis, // Caso o texto seja muito longo
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              
              Padding(
                padding: const EdgeInsets.only(bottom: 20),
                child: Column(
                  children: [
                    SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: onboardingState.selectedFocusAreas.isEmpty 
                              ? const Color(0xFF11182E) 
                              : const Color(0xFF5D0EFF),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                        onPressed: onboardingState.selectedFocusAreas.isEmpty
                            ? null
                            : () async {
                                await ref.read(onboardingProvider.notifier).completeOnboarding();
                                if (context.mounted) {
                                  context.go('/login');
                                }
                              },
                        child: Text("Continuar", 
                          style: TextStyle(
                            color: onboardingState.selectedFocusAreas.isEmpty ? Colors.white24 : Colors.white, 
                            fontSize: 16, 
                            fontWeight: FontWeight.bold
                          )),
                      ),
                    ),
                    TextButton(
                      onPressed: () => context.go('/login'),
                      child: const Text("Pular", style: TextStyle(color: Colors.white54)),
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