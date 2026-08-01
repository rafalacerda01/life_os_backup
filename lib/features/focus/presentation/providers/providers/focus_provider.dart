import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:life_os/core/database/database_provider.dart';
import 'package:life_os/features/focus/data/repositories/focus_repository.dart';
import 'package:life_os/features/tasks/presentation/providers/tasks_provider.dart';
import 'package:life_os/features/study/presentation/providers/study_provider.dart';

// --- INJEÇÃO DO REPOSITÓRIO ---
final focusRepositoryProvider = Provider((ref) {
  return FocusRepository(
    ref.watch(databaseProvider),
    FirebaseFirestore.instance,
    FirebaseAuth.instance,
  );
});

class FocusState {
  final int durationRemaining;
  final bool isRunning;
  final bool isBreak;
  final String? activeTargetId;
  final String? activeTargetTitle;
  final String? activeTargetType;

  const FocusState({
    required this.durationRemaining,
    required this.isRunning,
    required this.isBreak,
    this.activeTargetId,
    this.activeTargetTitle,
    this.activeTargetType,
  });

  FocusState copyWith({
    int? durationRemaining,
    bool? isRunning,
    bool? isBreak,
    String? activeTargetId,
    String? activeTargetTitle,
    String? activeTargetType,
  }) {
    return FocusState(
      durationRemaining: durationRemaining ?? this.durationRemaining,
      isRunning: isRunning ?? this.isRunning,
      isBreak: isBreak ?? this.isBreak,
      activeTargetId: activeTargetId ?? this.activeTargetId,
      activeTargetTitle: activeTargetTitle ?? this.activeTargetTitle,
      activeTargetType: activeTargetType ?? this.activeTargetType,
    );
  }
}

class FocusNotifier extends Notifier<FocusState> {
  Timer? _timer;
  int _timerDurationInSeconds = 1500; // Armazena a duração atual configurada

  @override
  FocusState build() {
    ref.onDispose(() {
      _timer?.cancel();
    });

    return const FocusState(
      durationRemaining: 1500, // Padrão: 25 minutos
      isRunning: false,
      isBreak: false,
    );
  }

  void selectTarget(String id, String title, {String targetType = 'TASK'}) {
    state = state.copyWith(
      activeTargetId: id,
      activeTargetTitle: title,
      activeTargetType: targetType,
    );
  }

  void validateActiveTarget(List<String> validIds) {
    if (state.activeTargetId != null &&
        !validIds.contains(state.activeTargetId)) {
      state = state.copyWith(
        activeTargetId: null,
        activeTargetTitle: null,
        activeTargetType: null,
      );
    }
  }

  void setCustomDuration(int minutes) {
    if (state.isRunning) return;

    final safeMinutes = minutes < 1 ? 1 : minutes;
    _timerDurationInSeconds = safeMinutes * 60;

    state = state.copyWith(durationRemaining: _timerDurationInSeconds);
  }

  void startTimer() {
    if (state.isRunning) return;

    state = state.copyWith(isRunning: true);

    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (state.durationRemaining > 1) {
        state = state.copyWith(durationRemaining: state.durationRemaining - 1);
      } else {
        _timer?.cancel();
        state = state.copyWith(durationRemaining: 0, isRunning: false);
        _handleSessionEnd();
      }
    });
  }

  Future<void> _handleSessionEnd() async {
    if (!state.isBreak && state.activeTargetId != null) {
      try {
        final targetIdStr = state.activeTargetId!;
        final targetType = state.activeTargetType ?? 'TASK';
        final elapsedSeconds = _timerDurationInSeconds;

        // 1. Grava o log de foco usando o FocusRepository! (Salva local e Firebase)
        await ref
            .read(focusRepositoryProvider)
            .saveFocusSession(targetIdStr, targetType, elapsedSeconds);

        // 2. Delega a atualização da tarefa para o TasksRepository
        if (targetType == 'TASK') {
          await ref
              .read(tasksRepositoryProvider)
              .toggleTaskStatus(targetIdStr, false);
        }
        // 3. Delega a atualização da matéria para o StudyRepository (Ajuste conforme o seu método)
        else if (targetType == 'SUBJECT' || targetType == 'EXAM') {
          // Exemplo de como deve ficar se você tiver um método updateLastStudyDate:
          // await ref.read(studyRepositoryProvider).updateLastStudyDate(targetIdStr);
        }
      } catch (e) {
        // Agora usamos o AppLogger oficial aqui também, caso algo falhe na coordenação
        print("Erro ao finalizar sessão de foco: $e");
      }
    }
    toggleSessionType();
  }

  void pauseTimer() {
    _timer?.cancel();
    state = state.copyWith(isRunning: false);
  }

  void resetTimer() {
    _timer?.cancel();
    state = state.copyWith(
      durationRemaining: state.isBreak ? 300 : _timerDurationInSeconds,
      isRunning: false,
    );
  }

  void toggleSessionType() {
    _timer?.cancel();
    final nextIsBreak = !state.isBreak;
    state = state.copyWith(
      durationRemaining: nextIsBreak ? 300 : _timerDurationInSeconds,
      isRunning: false,
      isBreak: nextIsBreak,
    );
  }
}

final focusProvider = NotifierProvider<FocusNotifier, FocusState>(
  FocusNotifier.new,
);
