import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart';
import 'package:life_os/core/utils/app_logger.dart';
import 'package:life_os/core/database/database_provider.dart';
import 'package:life_os/features/focus/data/remote/focus_remote_data_source.dart';
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

final focusRemoteDataSourceProvider = Provider<FocusRemoteDataSource>((ref) {
  final dataSource = FocusRemoteDataSource();
  ref.onDispose(dataSource.close);
  return dataSource;
});

const _keepCurrentTargetValue = Object();
const _verifiedFocusDurations = {60, 180, 600, 1500, 2700};

class _FocusCycleContext {
  final String targetId;
  final FocusTargetType targetType;
  final int plannedDurationSeconds;

  const _FocusCycleContext({
    required this.targetId,
    required this.targetType,
    required this.plannedDurationSeconds,
  });
}

class _PendingVerifiedInvalidation {
  final String sessionId;
  Future<bool>? cancelAttempt;

  _PendingVerifiedInvalidation(this.sessionId);
}

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
  bool _isStartingVerifiedSession = false;
  bool _cycleCanBeVerified = true;
  int _startGeneration = 0;
  String? _verifiedSessionId;
  _PendingVerifiedInvalidation? _pendingVerifiedInvalidation;
  _FocusCycleContext? _activeCycle;
  int _timerDurationInSeconds = 1500; // Armazena a duração atual configurada

  @override
  FocusState build() {
    ref.onDispose(() {
      _startGeneration++;
      _timer?.cancel();
    });

    return const FocusState(
      durationRemaining: 1500, // Padrão: 25 minutos
      isRunning: false,
      isBreak: false,
    );
  }

  void selectTarget(String id, String title, FocusTargetType targetType) {
    if (state.isRunning || _isStartingVerifiedSession) return;

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
    if (state.isRunning || _isStartingVerifiedSession) return;

    final safeMinutes = minutes < 1 ? 1 : minutes;
    _timerDurationInSeconds = safeMinutes * 60;

    state = state.copyWith(durationRemaining: _timerDurationInSeconds);
  }

  void startTimer() {
    if (state.isRunning || _isCompletingSession || _isStartingVerifiedSession) {
      return;
    }

    final cycle = _cycleForCurrentState();
    if (!_canStartVerifiedSession(cycle)) {
      _startLocalTimer(cycle);
      return;
    }

    _isStartingVerifiedSession = true;
    final generation = ++_startGeneration;
    unawaited(_startVerifiedThenLocal(cycle!, generation));
  }

  _FocusCycleContext? _cycleForCurrentState() {
    if (state.isBreak) return null;

    final existingCycle = _activeCycle;
    if (existingCycle != null &&
        state.durationRemaining < _timerDurationInSeconds) {
      return existingCycle;
    }

    final targetId = state.activeTargetId;
    final targetType = state.activeTargetType;
    if (targetId == null || targetType == null) return null;

    return _FocusCycleContext(
      targetId: targetId,
      targetType: targetType,
      plannedDurationSeconds: _timerDurationInSeconds,
    );
  }

  bool _canStartVerifiedSession(_FocusCycleContext? cycle) {
    return !state.isBreak &&
        cycle != null &&
        _cycleCanBeVerified &&
        state.durationRemaining == _timerDurationInSeconds &&
        _verifiedFocusDurations.contains(cycle.plannedDurationSeconds);
  }

  Future<void> _startVerifiedThenLocal(
    _FocusCycleContext cycle,
    int generation,
  ) async {
    try {
      final invalidation = _pendingVerifiedInvalidation;
      if (invalidation != null) {
        final wasCancelled = await _ensureInvalidationCancel(invalidation);
        if (generation != _startGeneration) return;

        final currentInvalidation = _pendingVerifiedInvalidation;
        if (wasCancelled) {
          if (identical(currentInvalidation, invalidation)) {
            _pendingVerifiedInvalidation = null;
          } else if (currentInvalidation != null) {
            _startLocalAfterUnconfirmedCancel(cycle);
            return;
          }
        } else {
          _startLocalAfterUnconfirmedCancel(cycle);
          return;
        }
      }

      final response = await ref
          .read(focusRemoteDataSourceProvider)
          .startFocus(
            targetId: cycle.targetId,
            targetType: _toRemoteTargetType(cycle.targetType),
            plannedDurationSeconds: cycle.plannedDurationSeconds,
          );

      if (generation != _startGeneration) {
        _beginPendingVerifiedInvalidation(response.sessionId);
        return;
      }

      _verifiedSessionId = response.sessionId;
      _startLocalTimer(cycle);
    } catch (_) {
      if (generation != _startGeneration) return;

      AppLogger.w(
        'Focus verificado indisponível no início; sessão continuará local.',
      );
      _startLocalTimer(cycle);
    } finally {
      _isStartingVerifiedSession = false;
    }
  }

  FocusRemoteTargetType _toRemoteTargetType(FocusTargetType targetType) {
    return switch (targetType) {
      FocusTargetType.task => FocusRemoteTargetType.task,
      FocusTargetType.subject => FocusRemoteTargetType.subject,
    };
  }

  void _startLocalTimer(_FocusCycleContext? cycle) {
    _activeCycle = cycle;
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

    final cycle = _activeCycle;
    final verifiedSessionId = _takeVerifiedSession();
    if (verifiedSessionId != null && cycle != null && _cycleCanBeVerified) {
      unawaited(_finishVerifiedSession(verifiedSessionId, cycle));
    }

    try {
      if (!state.isBreak && cycle != null) {
        final targetIdStr = cycle.targetId;
        final targetType = cycle.targetType;
        final elapsedSeconds = cycle.plannedDurationSeconds;

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

  Future<void> _finishVerifiedSession(
    String sessionId,
    _FocusCycleContext cycle,
  ) async {
    try {
      final response = await ref
          .read(focusRemoteDataSourceProvider)
          .finishFocus(sessionId: sessionId);
      if (response.sessionId != sessionId ||
          response.verifiedDurationSeconds != cycle.plannedDurationSeconds) {
        AppLogger.w('Resposta incoerente ao finalizar Focus verificado.');
      }
    } catch (_) {
      AppLogger.w(
        'Não foi possível confirmar o Focus verificado; '
        'a sessão pessoal foi preservada.',
      );
    }
  }

  void pauseTimer() {
    _timer?.cancel();
    state = state.copyWith(isRunning: false);

    if (state.isBreak) return;

    _cycleCanBeVerified = false;
    _startGeneration++;
    final sessionId = _takeVerifiedSession();
    if (sessionId != null) {
      _beginPendingVerifiedInvalidation(sessionId);
    }
  }

  void resetTimer() {
    _timer?.cancel();
    _startGeneration++;
    final sessionId = _takeVerifiedSession();
    if (sessionId != null) {
      _beginPendingVerifiedInvalidation(sessionId);
    }
    _activeCycle = null;
    _cycleCanBeVerified = true;
    state = state.copyWith(
      durationRemaining: state.isBreak ? 300 : _timerDurationInSeconds,
      isRunning: false,
    );
  }

  void toggleSessionType() {
    _timer?.cancel();
    _startGeneration++;
    final sessionId = _takeVerifiedSession();
    if (sessionId != null) {
      _beginPendingVerifiedInvalidation(sessionId);
    }
    _activeCycle = null;
    _cycleCanBeVerified = true;
    final nextIsBreak = !state.isBreak;
    state = state.copyWith(
      durationRemaining: nextIsBreak ? 300 : _timerDurationInSeconds,
      isRunning: false,
      isBreak: nextIsBreak,
    );
  }

  String? _takeVerifiedSession() {
    final sessionId = _verifiedSessionId;
    _verifiedSessionId = null;
    return sessionId;
  }

  void _startLocalAfterUnconfirmedCancel(_FocusCycleContext cycle) {
    AppLogger.w(
      'Cancelamento anterior não confirmado; sessão continuará local.',
    );
    _startLocalTimer(cycle);
  }

  void _beginPendingVerifiedInvalidation(String sessionId) {
    final currentInvalidation = _pendingVerifiedInvalidation;
    if (currentInvalidation != null &&
        currentInvalidation.sessionId == sessionId) {
      unawaited(_ensureInvalidationCancel(currentInvalidation));
      return;
    }

    final invalidation = _PendingVerifiedInvalidation(sessionId);
    _pendingVerifiedInvalidation = invalidation;
    unawaited(_ensureInvalidationCancel(invalidation));
  }

  Future<bool> _ensureInvalidationCancel(
    _PendingVerifiedInvalidation invalidation,
  ) {
    final existingAttempt = invalidation.cancelAttempt;
    if (existingAttempt != null) return existingAttempt;

    final attempt = _cancelRemoteSession(invalidation.sessionId);
    invalidation.cancelAttempt = attempt;
    unawaited(
      attempt.then((wasCancelled) {
        if (!identical(_pendingVerifiedInvalidation, invalidation) ||
            !identical(invalidation.cancelAttempt, attempt)) {
          return;
        }

        invalidation.cancelAttempt = null;
        if (wasCancelled) {
          _pendingVerifiedInvalidation = null;
        }
      }),
    );
    return attempt;
  }

  Future<bool> _cancelRemoteSession(String sessionId) async {
    try {
      final response = await ref
          .read(focusRemoteDataSourceProvider)
          .cancelFocus(sessionId: sessionId);
      if (response.sessionId != sessionId) {
        AppLogger.w('Resposta incoerente ao cancelar Focus verificado.');
        return false;
      }
      return true;
    } on FocusRemoteException catch (error) {
      if (error.code == 'FOCUS_SESSION_EXPIRED') return true;

      AppLogger.w(
        'Não foi possível cancelar o Focus verificado; '
        'a sessão pessoal permanece local.',
      );
      return false;
    } catch (_) {
      AppLogger.w(
        'Não foi possível cancelar o Focus verificado; '
        'a sessão pessoal permanece local.',
      );
      return false;
    }
  }
}

final focusProvider = NotifierProvider<FocusNotifier, FocusState>(
  FocusNotifier.new,
);
