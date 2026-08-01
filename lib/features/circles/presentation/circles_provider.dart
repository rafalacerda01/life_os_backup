import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:life_os/features/circles/domain/entities/circle_entity.dart';
import 'package:life_os/features/circles/domain/entities/challenge_entity.dart';
import 'package:life_os/features/circles/data/repositories/circles_repository.dart';
import 'dart:async';
import 'package:life_os/core/utils/app_logger.dart';

final circlesProvider = NotifierProvider<CirclesNotifier, CirclesState>(
  CirclesNotifier.new,
);

const _sentinel = Object();

class CirclesState {
  final List<CircleEntity> availableCircles;
  final CircleEntity? joinedCircle;
  final bool isLoading;

  const CirclesState({
    required this.availableCircles,
    this.joinedCircle,
    required this.isLoading,
  });

  CirclesState copyWith({
    List<CircleEntity>? availableCircles,
    Object? joinedCircle = _sentinel,
    bool? isLoading,
  }) {
    return CirclesState(
      availableCircles: availableCircles ?? this.availableCircles,
      joinedCircle: joinedCircle == _sentinel
          ? this.joinedCircle
          : joinedCircle as CircleEntity?,
      isLoading: isLoading ?? this.isLoading,
    );
  }
}

class CirclesNotifier extends Notifier<CirclesState> {
  StreamSubscription? _subscription;

  @override
  CirclesState build() {
    ref.onDispose(() {
      _subscription?.cancel();
    });

    return const CirclesState(
      isLoading: false,
      availableCircles: [],
      joinedCircle: null,
    );
  }

  void clearJoinedCircle() {
    state = state.copyWith(joinedCircle: null, isLoading: false);
  }

  Future<void> joinCircle(String circleId) async {
    await _subscription?.cancel();
    state = state.copyWith(isLoading: true);

    _subscription = ref
        .read(circlesRepositoryProvider)
        .getCircleStream(circleId)
        .listen(
          (circle) {
            if (circle == null) {
              clearJoinedCircle();
            } else {
              state = state.copyWith(joinedCircle: circle, isLoading: false);
            }
          },
          onError: (error) {
            print("Erro no stream do círculo (provavelmente deletado): $error");
            clearJoinedCircle();
          },
        );
  }

  Future<void> contributeToChallenge(String challengeId, int xpAmount) async {
    final circle = state.joinedCircle;
    if (circle == null) return;

    final updatedChallenges = circle.activeChallenges.map((challenge) {
      if (challenge.id == challengeId) {
        return challenge.copyWith(
          currentXpContributed: (challenge.currentXpContributed + xpAmount)
              .clamp(0, challenge.targetXp)
              .toInt(),
        );
      }
      return challenge;
    }).toList();

    final updatedRanking = circle.ranking.map((member) {
      if (member.isCurrentUser) {
        return member.copyWith(totalXp: member.totalXp + xpAmount);
      }
      return member;
    }).toList();

    updatedRanking.sort((a, b) => b.totalXp.compareTo(a.totalXp));

    final finalRanking = updatedRanking.asMap().entries.map((entry) {
      return entry.value.copyWith(rankPosition: entry.key + 1);
    }).toList();

    state = state.copyWith(
      joinedCircle: circle.copyWith(
        ranking: finalRanking,
        activeChallenges: updatedChallenges,
      ),
    );

    try {
      await ref
          .read(circlesRepositoryProvider)
          .contributeXp(circle.id, challengeId, xpAmount);
    } catch (e) {
      print("Erro ao atualizar Firebase: $e");
    }
  }

  Future<void> createNewChallenge(String title, int targetXp) async {
    final circle = state.joinedCircle;
    final user = FirebaseAuth.instance.currentUser;
    if (circle == null || user == null) return;

    try {
      final newChallenge = ChallengeEntity(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        title: title,
        targetXp: targetXp,
        currentXpContributed: 0,
        createdBy: user.uid,
      );

      state = state.copyWith(
        joinedCircle: circle.copyWith(
          activeChallenges: [...circle.activeChallenges, newChallenge],
        ),
      );

      await ref
          .read(circlesRepositoryProvider)
          .createChallenge(
            circleId: circle.id,
            title: title,
            targetXp: targetXp,
            adminId: user.uid,
          );
    } catch (e) {
      print("Erro ao criar desafio: $e");
    }
  }

  Future<void> leaveCircle(String circleId) async {
    try {
      await ref.read(circlesRepositoryProvider).leaveCircle(circleId);
      clearJoinedCircle();
    } catch (e) {
      print("Erro ao sair do círculo: $e");
    }
  }

  Future<String?> joinCircleByCode(String code) async {
    try {
      state = state.copyWith(isLoading: true);
      await ref.read(circlesRepositoryProvider).joinCircleByCode(code);
      await joinCircle(code.trim());
      return null;
    } catch (e) {
      state = state.copyWith(isLoading: false);
      return e.toString().replaceAll("Exception: ", "");
    }
  }

  Future<void> deleteCircle(String circleId) async {
    final previousState = state;

    // Se o círculo deletado for o que está aberto, cancela a stream ativa imediatamente
    if (state.joinedCircle?.id == circleId) {
      await _subscription?.cancel();
      _subscription = null;
    }

    final updatedAvailable = state.availableCircles
        .where((c) => c.id != circleId)
        .toList();

    final clearedJoined = state.joinedCircle?.id == circleId
        ? null
        : state.joinedCircle;

    // Atualiza o estado de forma otimista
    state = state.copyWith(
      availableCircles: updatedAvailable,
      joinedCircle: clearedJoined,
      isLoading: false,
    );

    try {
      await ref.read(circlesRepositoryProvider).deleteCircle(circleId);
    } catch (e) {
      // Reverte o estado caso ocorra erro no Firebase
      state = previousState;
      print("Erro ao deletar círculo: $e");
      rethrow;
    }
  }
}
