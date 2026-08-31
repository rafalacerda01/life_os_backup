import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import 'package:life_os/core/theme/app_colors.dart';
import 'package:life_os/features/circles/domain/entities/challenge_entity.dart';
import 'package:life_os/features/circles/domain/entities/circle_entity.dart';
import 'package:life_os/features/circles/presentation/circles_provider.dart';
import 'package:life_os/features/circles/presentation/create_challenge_screen.dart';

class CircleDetailScreen extends ConsumerWidget {
  final String circleId;

  const CircleDetailScreen({super.key, required this.circleId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final circle = ref.watch(circlesProvider).joinedCircle;
    final currentUserId = FirebaseAuth.instance.currentUser?.uid ?? '';

    if (circle == null || circle.id != circleId) {
      return const Scaffold(
        backgroundColor: AppColors.scaffoldBackground,
        body: Center(
          child: CircularProgressIndicator(color: AppColors.primary),
        ),
      );
    }

    final isAdmin = circle.isAdmin(currentUserId);

    return Scaffold(
      backgroundColor: AppColors.scaffoldBackground,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          'Detalhes do Círculo',
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
                'Junte-se ao meu Círculo no Life OS! Código: $circleId',
                subject: 'Convite para Círculo de Evolução',
              );
            },
          ),
          if (isAdmin)
            IconButton(
              icon: const Icon(Icons.delete, color: Colors.redAccent),
              onPressed: () {
                if (circle.memberCount == 1) {
                  _confirmDelete(context, ref, circle.id);
                } else {
                  _showDeleteRequiresBackend(context);
                }
              },
            )
          else
            IconButton(
              icon: const Icon(Icons.exit_to_app, color: Colors.redAccent),
              onPressed: () => _confirmLeave(context, ref, circle.id),
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(circle),
            const SizedBox(height: 16),
            _buildCodeCard(context, circle.id),
            const SizedBox(height: 30),
            Text(
              'Membros (${circle.memberCount}/${circle.memberLimit})',
              style: const TextStyle(
                color: AppColors.textMain,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            ...circle.members.map(
              (member) => _buildMemberTile(member, currentUserId),
            ),
            const SizedBox(height: 30),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Desafios',
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
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            CreateChallengeScreen(circleId: circle.id),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (circle.challenges.isEmpty)
              const Text(
                'Nenhum desafio criado no momento.',
                style: TextStyle(color: AppColors.textDisabled),
              ),
            ...circle.challenges.map(
              (challenge) =>
                  _buildChallengeCard(circle, challenge, currentUserId),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(CircleEntity circle) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: AppColors.cardBackground,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppColors.primary.withOpacity(0.2)),
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
            style: const TextStyle(color: AppColors.textHint, fontSize: 14),
          ),
          const SizedBox(height: 16),
          Text(
            '${circle.memberCount} de ${circle.memberLimit} membros',
            style: const TextStyle(
              color: AppColors.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCodeCard(BuildContext context, String id) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.cardBackground,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(
              'Código: $id',
              style: const TextStyle(
                color: AppColors.textHint,
                fontFamily: 'monospace',
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.copy, color: AppColors.secondary),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: id));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Código copiado!'),
                  backgroundColor: AppColors.primary,
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildMemberTile(CircleMemberEntity member, String currentUserId) {
    final isCurrentUser = member.userId == currentUserId;
    final initial = member.displayName.isEmpty
        ? '?'
        : member.displayName[0].toUpperCase();

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isCurrentUser
            ? AppColors.secondary.withOpacity(0.12)
            : AppColors.cardBackground,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: AppColors.secondary,
            backgroundImage: member.photoUrl != null
                ? NetworkImage(member.photoUrl!)
                : null,
            child: member.photoUrl == null
                ? Text(
                    initial,
                    style: const TextStyle(
                      color: AppColors.textMain,
                      fontWeight: FontWeight.bold,
                    ),
                  )
                : null,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              member.displayName,
              style: TextStyle(
                color: AppColors.textMain,
                fontWeight: isCurrentUser ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ),
          if (member.role == CircleMemberRole.admin)
            const Text(
              'Administrador',
              style: TextStyle(color: AppColors.primary, fontSize: 12),
            ),
        ],
      ),
    );
  }

  Widget _buildChallengeCard(
    CircleEntity circle,
    ChallengeEntity challenge,
    String currentUserId,
  ) {
    final total = circle.totalProgressFor(challenge);
    final completed = total >= challenge.targetValue;
    final ranking = circle.rankingFor(challenge);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: completed
            ? AppColors.success.withOpacity(0.15)
            : AppColors.cardBackground,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: completed
              ? AppColors.success.withOpacity(0.5)
              : Colors.white10,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  challenge.title,
                  style: TextStyle(
                    color: completed ? AppColors.success : AppColors.textMain,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Text(
                challenge.isExpired
                    ? 'Encerrado'
                    : completed
                    ? 'Concluído'
                    : 'Ativo',
                style: TextStyle(
                  color: completed ? AppColors.success : AppColors.textDisabled,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            challenge.type.label,
            style: const TextStyle(color: AppColors.textHint, fontSize: 12),
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: circle.progressRatioFor(challenge),
              backgroundColor: Colors.white10,
              valueColor: AlwaysStoppedAnimation(
                completed ? AppColors.success : AppColors.secondary,
              ),
              minHeight: 8,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '$total / ${challenge.targetValue} ${challenge.type.label}',
            style: const TextStyle(color: AppColors.textDisabled, fontSize: 12),
          ),
          const SizedBox(height: 14),
          const Text(
            'Ranking do desafio',
            style: TextStyle(
              color: AppColors.textMain,
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
          ...ranking.asMap().entries.map((entry) {
            final item = entry.value;
            final isCurrentUser = item.member.userId == currentUserId;
            return Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  SizedBox(
                    width: 28,
                    child: Text(
                      '${entry.key + 1}.',
                      style: const TextStyle(color: AppColors.secondary),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      item.member.displayName,
                      style: TextStyle(
                        color: AppColors.textMain,
                        fontWeight: isCurrentUser
                            ? FontWeight.bold
                            : FontWeight.normal,
                      ),
                    ),
                  ),
                  Text(
                    '${item.value} ${challenge.type.label}',
                    style: const TextStyle(
                      color: AppColors.primary,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  void _confirmDelete(BuildContext context, WidgetRef ref, String id) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.cardBackground,
        title: const Text(
          'Excluir Círculo',
          style: TextStyle(color: AppColors.textMain),
        ),
        content: const Text(
          'Esta ação é irreversível. Deseja continuar?',
          style: TextStyle(color: AppColors.textHint),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(dialogContext);
              await ref.read(circlesProvider.notifier).deleteCircle(id);
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text(
              'Excluir',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );
  }

  void _showDeleteRequiresBackend(BuildContext context) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.cardBackground,
        title: const Text(
          'Exclusão indisponível',
          style: TextStyle(color: AppColors.textMain),
        ),
        content: const Text(
          'Círculos com vários membros exigem exclusão pelo backend.',
          style: TextStyle(color: AppColors.textHint),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Entendi'),
          ),
        ],
      ),
    );
  }

  void _confirmLeave(BuildContext context, WidgetRef ref, String id) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.cardBackground,
        title: const Text(
          'Sair do Círculo',
          style: TextStyle(color: AppColors.textMain),
        ),
        content: const Text(
          'Você não terá mais acesso aos desafios deste círculo. Deseja sair?',
          style: TextStyle(color: AppColors.textHint),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(dialogContext);
              if (context.mounted) Navigator.pop(context);
              await ref.read(circlesProvider.notifier).leaveCircle(id);
            },
            child: const Text(
              'Sair',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );
  }
}
