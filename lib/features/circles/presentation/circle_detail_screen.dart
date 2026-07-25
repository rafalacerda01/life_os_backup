import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import 'package:life_os/core/theme/app_colors.dart'; // <-- IMPORT DO SEU TEMA
import 'package:life_os/features/circles/data/repositories/circles_repository.dart';
import 'package:life_os/features/circles/domain/entities/circle_entity.dart';
import 'package:life_os/features/circles/domain/entities/challenge_entity.dart';
import 'package:life_os/features/circles/presentation/create_challenge_screen.dart';
import 'package:life_os/features/circles/presentation/circles_provider.dart';

class CircleDetailScreen extends ConsumerWidget {
  final String circleId;

  const CircleDetailScreen({super.key, required this.circleId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final circlesState = ref.watch(circlesProvider);
    final circle = circlesState.joinedCircle;
    final currentUserId = FirebaseAuth.instance.currentUser?.uid ?? '';

    return Builder(
      builder: (context) {
        if (circle == null || circle.id != circleId) {
          return const Scaffold(
            backgroundColor: AppColors.scaffoldBackground,
            body: Center(
              child: CircularProgressIndicator(color: AppColors.primary),
            ),
          );
        }

        // 👉 Usando o Getter inteligente que criamos na Entidade!
        final bool isAdmin = circle.isAdmin(currentUserId);

        return Scaffold(
          backgroundColor: AppColors.scaffoldBackground,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            title: const Text(
              "Detalhes do Círculo",
              style: TextStyle(
                color: AppColors.textMain,
                fontWeight: FontWeight.bold,
              ),
            ),
            iconTheme: const IconThemeData(color: AppColors.textMain),
            actions: [
              IconButton(
                icon: const Icon(Icons.share, color: AppColors.primary),
                onPressed: () {
                  Share.share(
                    'Junte-se ao meu Círculo no Life OS! Use este código para entrar: $circleId',
                    subject: 'Convite para Círculo de Evolução',
                  );
                },
              ),
              // LÓGICA DO BOTÃO: Lixeira se for Admin, Porta de saída se for Membro
              if (isAdmin)
                IconButton(
                  icon: const Icon(Icons.delete, color: Colors.redAccent),
                  onPressed: () => _confirmDelete(context, ref, circleId),
                )
              else
                IconButton(
                  icon: const Icon(Icons.exit_to_app, color: Colors.redAccent),
                  onPressed: () => _confirmLeave(context, ref, circleId),
                ),
            ],
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: AppColors.cardBackground,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(
                      color: AppColors.primary.withOpacity(0.2),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        circle.name,
                        style: const TextStyle(
                          color: AppColors.textMain,
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        circle.description,
                        style: const TextStyle(
                          color: AppColors.textHint,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        "👥 ${circle.memberCount} membros",
                        style: const TextStyle(
                          color: AppColors.primary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.cardBackground,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.white10),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        "Código: ${circle.id}",
                        style: const TextStyle(
                          color: AppColors.textHint,
                          fontFamily: 'monospace',
                        ),
                      ),
                      IconButton(
                        icon: const Icon(
                          Icons.copy,
                          color: AppColors.secondary,
                        ),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: circle.id));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                "Código copiado!",
                                style: TextStyle(color: Colors.white),
                              ),
                              backgroundColor: AppColors.primary,
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 30),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      "Estatísticas",
                      style: TextStyle(
                        color: AppColors.textMain,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (isAdmin)
                      IconButton(
                        icon: const Icon(
                          Icons.add_circle_outline,
                          color: AppColors.primary,
                        ),
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  CreateChallengeScreen(circleId: circle.id),
                            ),
                          );
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                if (circle.activeChallenges.isEmpty)
                  const Text(
                    "Nenhum desafio ativo no momento.",
                    style: TextStyle(color: AppColors.textDisabled),
                  ),
                ...circle.activeChallenges.map(
                  (c) => _buildChallengeCard(ref, c),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _confirmDelete(BuildContext context, WidgetRef ref, String circleId) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.cardBackground,
        title: const Text(
          "Excluir Círculo",
          style: TextStyle(color: AppColors.textMain),
        ),
        content: const Text(
          "Esta ação é irreversível e excluirá o círculo para todos. Deseja continuar?",
          style: TextStyle(color: AppColors.textHint),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text(
              "Cancelar",
              style: TextStyle(color: AppColors.textHint),
            ),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(dialogContext);
              if (context.mounted) Navigator.pop(context);
              // O Riverpod vai escutar a deleção e atualizar a tela inicial automaticamente
              await ref.read(circlesRepositoryProvider).deleteCircle(circleId);
            },
            child: const Text(
              "Excluir",
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );
  }

  void _confirmLeave(BuildContext context, WidgetRef ref, String circleId) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.cardBackground,
        title: const Text(
          "Sair do Círculo",
          style: TextStyle(color: AppColors.textMain),
        ),
        content: const Text(
          "Você não terá mais acesso aos desafios deste círculo. Deseja sair?",
          style: TextStyle(color: AppColors.textHint),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text(
              "Cancelar",
              style: TextStyle(color: AppColors.textHint),
            ),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(dialogContext);
              if (context.mounted) Navigator.pop(context);
              await ref.read(circlesProvider.notifier).leaveCircle(circleId);
            },
            child: const Text(
              "Sair",
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChallengeCard(WidgetRef ref, ChallengeEntity challenge) {
    // 👉 Código reduzido graças aos getters inteligentes de ChallengeEntity!
    final bool isCompleted = challenge.isCompleted;
    final double progress = challenge.progressRatio;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isCompleted
            ? AppColors.success.withOpacity(0.15)
            : AppColors.cardBackground,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isCompleted
              ? AppColors.success.withOpacity(0.5)
              : Colors.white10,
        ),
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
                  style: TextStyle(
                    color: isCompleted ? AppColors.success : AppColors.textMain,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              if (isCompleted)
                const Text(
                  "CONCLUÍDO! 🏆",
                  style: TextStyle(
                    color: AppColors.success,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress,
              backgroundColor: Colors.white10,
              valueColor: AlwaysStoppedAnimation<Color>(
                isCompleted ? AppColors.success : AppColors.secondary,
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
              if (!isCompleted)
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.secondary,
                    minimumSize: const Size(90, 30),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  onPressed: () {
                    ref
                        .read(circlesProvider.notifier)
                        .contributeToChallenge(challenge.id, 150);
                  },
                  child: const Text(
                    "+150 XP",
                    style: TextStyle(color: AppColors.textMain, fontSize: 11),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
