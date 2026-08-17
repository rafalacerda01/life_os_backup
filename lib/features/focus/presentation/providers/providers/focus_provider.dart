import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart';
import 'package:life_os/core/utils/app_logger.dart';
import 'package:life_os/core/database/database_provider.dart';
import 'package:life_os/features/focus/data/repositories/focus_repository.dart';
import 'package:life_os/features/tasks/presentation/providers/tasks_provider.dart';
import 'package:life_os/features/study/presentation/providers/study_provider.dart';

enum FocusTargetType {
  task('TASK'),
  subject('SUBJECT');

  const FocusTargetType(this.value);

  final String value;
}

// --- INJEÇÃO DO REPOSITÓRIO ---
final focusRepositoryProvider = Provider((ref) {
  return FocusRepository(
    ref.watch(databaseProvider),
    FirebaseFirestore.instance,
    FirebaseAuth.instance,
  );
});

typedef FocusPeriodicTimerFactory =
    Timer Function(Duration duration, void Function(Timer timer) callback);

final focusPeriodicTimerFactoryProvider = Provider<FocusPeriodicTimerFactory>(
  (ref) => Timer.periodic,
);

const _keepCurrentTargetValue = Object();

class FocusState {
  final int durationRemaining;
  final bool isRunning;
  final bool isBreak;
  final String? activeTargetId;
  final String? activeTargetTitle;
  final FocusTargetType? activeTargetType;

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
    Object? activeTargetId = _keepCurrentTargetValue,
    Object? activeTargetTitle = _keepCurrentTargetValue,
    Object? activeTargetType = _keepCurrentTargetValue,
  }) {
    return FocusState(
      durationRemaining: durationRemaining ?? this.durationRemaining,
      isRunning: isRunning ?? this.isRunning,
      isBreak: isBreak ?? this.isBreak,
      activeTargetId: identical(activeTargetId, _keepCurrentTargetValue)
          ? this.activeTargetId
          : activeTargetId as String?,
      activeTargetTitle: identical(activeTargetTitle, _keepCurrentTargetValue)
          ? this.activeTargetTitle
          : activeTargetTitle as String?,
      activeTargetType: identical(activeTargetType, _keepCurrentTargetValue)
          ? this.activeTargetType
          : activeTargetType as FocusTargetType?,
    );
  }
}

class FocusNotifier extends Notifier<FocusState> {
  Timer? _timer;
  bool _isCompletingSession = false;
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

  void selectTarget(String id, String title, FocusTargetType targetType) {
    if (state.isRunning) return;

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
    if (state.isRunning || _isCompletingSession) return;

    state = state.copyWith(isRunning: true);

    _timer = ref.read(focusPeriodicTimerFactoryProvider)(
      const Duration(seconds: 1),
      (timer) {
        if (state.durationRemaining > 1) {
          state = state.copyWith(
            durationRemaining: state.durationRemaining - 1,
          );
        } else {
          _timer?.cancel();
          state = state.copyWith(durationRemaining: 0, isRunning: false);
          unawaited(_handleSessionEnd());
        }
      },
    );
  }

  Future<void> _handleSessionEnd() async {
    if (_isCompletingSession) return;

    _isCompletingSession = true;

    try {
      if (!state.isBreak && state.activeTargetId != null) {
        final targetIdStr = state.activeTargetId!;
        final targetType = state.activeTargetType ?? FocusTargetType.task;
        final elapsedSeconds = _timerDurationInSeconds;

        // 1. Grava o log de foco bruto
        await ref
            .read(focusRepositoryProvider)
            .saveFocusSession(targetIdStr, targetType.value, elapsedSeconds);

        // 2. Atualiza Tarefa se for do tipo TASK
        if (targetType == FocusTargetType.task) {
          await ref
              .read(tasksRepositoryProvider)
              .toggleTaskStatus(targetIdStr, false);
        }
        // 3. Atualiza Matéria/Estudo se for do tipo SUBJECT
        else if (targetType == FocusTargetType.subject) {
          await ref
              .read(studyRepositoryProvider)
              .addStudyTime(targetIdStr, elapsedSeconds);
        }
      }
    } catch (e, stack) {
      AppLogger.e("Erro ao finalizar sessão de foco", e, stack);
    } finally {
      toggleSessionType();
      _isCompletingSession = false;
    }
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
