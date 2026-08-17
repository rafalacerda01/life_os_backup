import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/core/utils/app_logger.dart';
import 'package:life_os/features/circles/data/repositories/circles_repository.dart';
import 'package:life_os/features/circles/domain/entities/challenge_entity.dart';
import 'package:life_os/features/circles/domain/entities/circle_entity.dart';

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
  StreamSubscription<CircleEntity?>? _subscription;

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
          onError: (Object error, StackTrace stackTrace) {
            AppLogger.e('Erro no stream do círculo', error, stackTrace);
            clearJoinedCircle();
          },
        );
  }

  Future<void> createNewChallenge({
    required String title,
    required ChallengeType type,
    required int targetValue,
    required DateTime endAt,
  }) async {
    final circle = state.joinedCircle;
    if (circle == null) {
      throw StateError('Nenhum círculo ativo');
    }

    try {
      await ref
          .read(circlesRepositoryProvider)
          .createChallenge(
            circleId: circle.id,
            title: title,
            type: type,
            targetValue: targetValue,
            endAt: endAt,
          );
    } catch (error, stackTrace) {
      AppLogger.e('Erro ao criar desafio', error, stackTrace);
      rethrow;
    }
  }

  Future<void> leaveCircle(String circleId) async {
    try {
      await ref.read(circlesRepositoryProvider).leaveCircle(circleId);
      clearJoinedCircle();
    } catch (error, stackTrace) {
      AppLogger.e('Erro ao sair do círculo', error, stackTrace);
      rethrow;
    }
  }

  Future<String?> joinCircleByCode(String code) async {
    try {
      state = state.copyWith(isLoading: true);
      await ref.read(circlesRepositoryProvider).joinCircleByCode(code);
      await joinCircle(code.trim());
      return null;
    } catch (error, stackTrace) {
      AppLogger.e('Erro ao entrar no círculo', error, stackTrace);
      state = state.copyWith(isLoading: false);
      return error.toString().replaceAll('Exception: ', '');
    }
  }

  Future<void> deleteCircle(String circleId) async {
    final previousState = state;

    if (state.joinedCircle?.id == circleId) {
      await _subscription?.cancel();
      _subscription = null;
    }

    final updatedAvailable = state.availableCircles
        .where((circle) => circle.id != circleId)
        .toList();
    final clearedJoined = state.joinedCircle?.id == circleId
        ? null
        : state.joinedCircle;

    state = state.copyWith(
      availableCircles: updatedAvailable,
      joinedCircle: clearedJoined,
      isLoading: false,
    );

    try {
      await ref.read(circlesRepositoryProvider).deleteCircle(circleId);
    } catch (error, stackTrace) {
      state = previousState;
      AppLogger.e('Erro ao deletar círculo', error, stackTrace);
      rethrow;
    }
  }
}
