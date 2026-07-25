import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/core/theme/app_colors.dart'; // <-- IMPORT DO SEU TEMA
import 'package:life_os/features/circles/presentation/circles_provider.dart';
import 'package:life_os/features/circles/presentation/create_circle_screen.dart';
import 'package:life_os/features/circles/data/repositories/circles_repository.dart';
import 'package:life_os/features/circles/presentation/circle_detail_screen.dart';
import 'package:life_os/features/circles/presentation/join_circle_screen.dart';

class CirclesScreen extends ConsumerStatefulWidget {
  const CirclesScreen({super.key});

  @override
  ConsumerState<CirclesScreen> createState() => _CirclesScreenState();
}

class _CirclesScreenState extends ConsumerState<CirclesScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final repository = ref.read(circlesRepositoryProvider);
      final activeCircleId = await repository.getUserActiveCircleId();

      if (activeCircleId != null && mounted) {
        ref.read(circlesProvider.notifier).joinCircle(activeCircleId);
      } else {
        print("Nenhum círculo ativo encontrado para este usuário.");
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final circlesState = ref.watch(circlesProvider);
    final currentCircle = circlesState.joinedCircle;
    final isLoading = circlesState.isLoading;

    return Scaffold(
      backgroundColor: AppColors.scaffoldBackground,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          "Círculos de Evolução",
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: AppColors.textMain,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.qr_code_scanner, color: AppColors.textMain),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const JoinCircleScreen(),
                ),
              );
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: AppColors.secondary,
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => const CreateCircleScreen()),
          );
        },
        child: const Icon(Icons.add, color: AppColors.textMain),
      ),
      body: isLoading
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.primary),
            )
          : currentCircle == null
          ? const Center(
              child: Text(
                "Você não está em nenhum círculo social.",
                style: TextStyle(color: AppColors.textHint),
              ),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // --- CARD DO CÍRCULO ATUAL ---
                  InkWell(
                    borderRadius: BorderRadius.circular(24),
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) =>
                              CircleDetailScreen(circleId: currentCircle.id),
                        ),
                      );
                    },
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: AppColors.cardBackground,
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(
                          color: AppColors.primary.withOpacity(0.15),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            currentCircle.name,
                            style: const TextStyle(
                              color: AppColors.textMain,
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            currentCircle.description,
                            style: const TextStyle(
                              color: AppColors.textHint,
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            "👥 ${currentCircle.memberCount} integrantes ativos",
                            style: const TextStyle(
                              color: AppColors.primary,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 25),
                  const Text(
                    "Desafio Coletivo Ativo",
                    style: TextStyle(
                      color: AppColors.textMain,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),

                  ...currentCircle.activeChallenges.map((challenge) {
                    return Container(
                      padding: const EdgeInsets.all(18),
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: AppColors.cardBackground,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Expanded(
                                child: Text(
                                  challenge.title,
                                  style: const TextStyle(
                                    color: AppColors.textMain,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 14),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              // 👉 Usando o nosso getter inteligente aqui!
                              value: challenge.progressRatio,
                              backgroundColor: Colors.white10,
                              valueColor: const AlwaysStoppedAnimation<Color>(
                                AppColors.secondary,
                              ),
                              minHeight: 8,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                "${challenge.currentXpContributed} / ${challenge.targetXp} XP",
                                style: const TextStyle(
                                  color: AppColors.textDisabled,
                                  fontSize: 12,
                                ),
                              ),
                              ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppColors.secondary,
                                  minimumSize: const Size(90, 30),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                ),
                                // Adicionando XP e disparando a UI Otimista!
                                onPressed: () => ref
                                    .read(circlesProvider.notifier)
                                    .contributeToChallenge(challenge.id, 150),
                                child: const Text(
                                  "+150 XP",
                                  style: TextStyle(
                                    color: AppColors.textMain,
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    );
                  }),

                  const SizedBox(height: 25),
                  const Text(
                    "Quadro de Líderes (Leaderboard)",
                    style: TextStyle(
                      color: AppColors.textMain,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),

                  ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: currentCircle.ranking.length,
                    separatorBuilder: (context, index) =>
                        const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final member = currentCircle.ranking[index];

                      // 👉 Lógica para colorir as medalhas do Top 3
                      Color rankColor = AppColors.textHint;
                      if (member.rankPosition == 1) rankColor = Colors.amber;
                      if (member.rankPosition == 2)
                        rankColor = Colors.grey[300]!;
                      if (member.rankPosition == 3)
                        rankColor = Colors.brown[300]!;

                      return Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                        decoration: BoxDecoration(
                          color: member.isCurrentUser
                              ? AppColors.secondary.withOpacity(0.15)
                              : AppColors.cardBackground,
                          borderRadius: BorderRadius.circular(16),
                          border: member.isCurrentUser
                              ? Border.all(color: AppColors.secondary, width: 1)
                              : null,
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Row(
                              children: [
                                // 👉 Exibindo a Posição no Ranking!
                                SizedBox(
                                  width: 28,
                                  child: Text(
                                    "${member.rankPosition}º",
                                    style: TextStyle(
                                      color: rankColor,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                CircleAvatar(
                                  radius: 18,
                                  backgroundColor: AppColors.secondary,
                                  backgroundImage: member.photoUrl != null
                                      ? NetworkImage(member.photoUrl!)
                                      : null,
                                  child: member.photoUrl == null
                                      ? Text(
                                          member.name[0].toUpperCase(),
                                          style: const TextStyle(
                                            color: AppColors.textMain,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        )
                                      : null,
                                ),
                                const SizedBox(width: 12),
                                Text(
                                  member.name,
                                  style: TextStyle(
                                    color: AppColors.textMain,
                                    fontWeight: member.isCurrentUser
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                                    fontSize: 14,
                                  ),
                                ),
                              ],
                            ),
                            Text(
                              "${member.totalXp} XP",
                              style: const TextStyle(
                                color: AppColors
                                    .success, // Verde esmeralda que definimos
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
    );
  }
}
