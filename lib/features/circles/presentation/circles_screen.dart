import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/core/theme/app_colors.dart';
import 'package:life_os/features/circles/data/repositories/circles_repository.dart';
import 'package:life_os/features/circles/domain/entities/challenge_entity.dart';
import 'package:life_os/features/circles/domain/entities/circle_entity.dart';
import 'package:life_os/features/circles/presentation/circle_detail_screen.dart';
import 'package:life_os/features/circles/presentation/circles_provider.dart';
import 'package:life_os/features/circles/presentation/create_circle_screen.dart';
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
      final activeCircleId = await ref
          .read(circlesRepositoryProvider)
          .getUserActiveCircleId();
      if (activeCircleId != null && mounted) {
        ref.read(circlesProvider.notifier).joinCircle(activeCircleId);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(circlesProvider);
    final circle = state.joinedCircle;
    final currentUserId = FirebaseAuth.instance.currentUser?.uid ?? '';

    return Scaffold(
      backgroundColor: AppColors.scaffoldBackground,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          'Círculos de Evolução',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: AppColors.textMain,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.qr_code_scanner, color: AppColors.textMain),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const JoinCircleScreen()),
            ),
          ),
        ],
      ),
      floatingActionButton: circle == null
          ? FloatingActionButton(
              backgroundColor: AppColors.secondary,
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const CreateCircleScreen()),
              ),
              child: const Icon(Icons.add, color: AppColors.textMain),
            )
          : null,
      body: state.isLoading
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.primary),
            )
          : circle == null
          ? const Center(
              child: Text(
                'Você não está em nenhum círculo social.',
                style: TextStyle(color: AppColors.textHint),
              ),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildCircleHeader(context, circle),
                  const SizedBox(height: 25),
                  const Text(
                    'Desafios',
                    style: TextStyle(
                      color: AppColors.textMain,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
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
                  const SizedBox(height: 25),
                  Text(
                    'Membros (${circle.memberCount}/${circle.memberLimit})',
                    style: const TextStyle(
                      color: AppColors.textMain,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  ...circle.members.map(
                    (member) => _buildMemberTile(member, currentUserId),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildCircleHeader(BuildContext context, CircleEntity circle) {
    return InkWell(
      borderRadius: BorderRadius.circular(24),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => CircleDetailScreen(circleId: circle.id),
        ),
      ),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppColors.cardBackground,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: AppColors.primary.withOpacity(0.15)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              circle.name,
              style: const TextStyle(
                color: AppColors.textMain,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              circle.description,
              style: const TextStyle(color: AppColors.textHint, fontSize: 13),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Icon(Icons.group_outlined, color: AppColors.primary),
                const SizedBox(width: 8),
                Text(
                  '${circle.memberCount} de ${circle.memberLimit} membros',
                  style: const TextStyle(
                    color: AppColors.primary,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChallengeCard(
    CircleEntity circle,
    ChallengeEntity challenge,
    String currentUserId,
  ) {
    final total = circle.totalProgressFor(challenge);
    final ranking = circle.rankingFor(challenge).take(3);

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
          Text(
            challenge.title,
            style: const TextStyle(
              color: AppColors.textMain,
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            challenge.type.label,
            style: const TextStyle(color: AppColors.textHint, fontSize: 12),
          ),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: circle.progressRatioFor(challenge),
              backgroundColor: Colors.white10,
              valueColor: const AlwaysStoppedAnimation(AppColors.secondary),
              minHeight: 8,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '$total / ${challenge.targetValue} ${challenge.type.label}',
            style: const TextStyle(color: AppColors.textDisabled, fontSize: 12),
          ),
          const SizedBox(height: 8),
          ...ranking.toList().asMap().entries.map((entry) {
            final item = entry.value;
            final isCurrentUser = item.member.userId == currentUserId;
            return Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  SizedBox(
                    width: 24,
                    child: Text(
                      '${entry.key + 1}.',
                      style: const TextStyle(color: AppColors.textHint),
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
                    '${item.value}',
                    style: const TextStyle(
                      color: AppColors.success,
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

  Widget _buildMemberTile(CircleMemberEntity member, String currentUserId) {
    final isCurrentUser = member.userId == currentUserId;
    final initial = member.displayName.isEmpty
        ? '?'
        : member.displayName[0].toUpperCase();

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: isCurrentUser
            ? AppColors.secondary.withOpacity(0.15)
            : AppColors.cardBackground,
        borderRadius: BorderRadius.circular(16),
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
              'Admin',
              style: TextStyle(color: AppColors.primary, fontSize: 12),
            ),
        ],
      ),
    );
  }
}
