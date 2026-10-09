import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart';
import 'package:life_os/core/utils/app_logger.dart';
import 'package:life_os/core/database/database_provider.dart';
import 'package:life_os/core/database/local_mutation_gate.dart';
import 'package:life_os/core/database/remote_send_permit.dart';
import 'package:life_os/core/services/firebase_auth_provider.dart';
import 'package:life_os/core/services/sync_manager_provider.dart';
import 'package:life_os/features/focus/data/remote/focus_remote_data_source.dart';
import 'package:life_os/features/focus/data/repositories/focus_repository.dart';
import 'package:life_os/features/tasks/presentation/providers/tasks_provider.dart';
import 'package:life_os/features/study/presentation/providers/study_provider.dart';
import 'package:life_os/features/settings/presentation/providers/analytics_provider.dart';

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
    ref.watch(syncManagerProvider),
  );
});

typedef FocusPeriodicTimerFactory =
    Timer Function(Duration duration, void Function(Timer timer) callback);

final focusPeriodicTimerFactoryProvider = Provider<FocusPeriodicTimerFactory>(
  (ref) => Timer.periodic,
);

final focusRemoteSendPermitProvider = Provider<RemoteSendPermit Function()>((
  ref,
) {
  return () {
    try {
      if (!ref.mounted) throw const RemoteSessionStopped();
      final auth = ref.read(firebaseAuthProvider);
      final uid = auth.currentUser?.uid;
      if (uid == null || uid.trim().isEmpty) {
        throw const RemoteSessionStopped();
      }
      final database = ref.read(databaseProvider);
      return database.localMutations
          .captureRemoteSend(expectedUid: uid)
          .and(() => ref.mounted && auth.currentUser?.uid == uid);
    } catch (_) {
      // Missing prepared database or invalid UID must never admit a send.
      throw const RemoteSessionStopped();
    }
  };
});

final focusRemoteDataSourceProvider = Provider<FocusRemoteDataSource>((ref) {
  final dataSource = FocusRemoteDataSource(
    captureRemoteSend: ref.read(focusRemoteSendPermitProvider),
  );
  ref.onDispose(dataSource.close);
  return dataSource;
});

const _keepCurrentTargetValue = Object();
const _verifiedFocusDurations = {60, 180, 600, 1500, 2700};

bool isVerifiedFocusDuration(int durationSeconds) {
  return _verifiedFocusDurations.contains(durationSeconds);
}

class _FocusCycleContext {
  final String targetId;
  final FocusTargetType targetType;
  final int plannedDurationSeconds;
  final LocalMutationTicket admission;
  final RemoteSendPermit? remoteAdmission;

  const _FocusCycleContext({
    required this.targetId,
    required this.targetType,
    required this.plannedDurationSeconds,
    required this.admission,
    required this.remoteAdmission,
  });
}

class _PendingVerifiedInvalidation {
  final String sessionId;
  final RemoteSendPermit admission;
  Future<bool>? cancelAttempt;

  _PendingVerifiedInvalidation(this.sessionId, this.admission);
}

class FocusState {
  final int durationRemaining;
  final bool isRunning;
  final bool isBreak;
  final bool targetLocked;
  final String? activeTargetId;
  final String? activeTargetTitle;
  final FocusTargetType? activeTargetType;

  const FocusState({
    required this.durationRemaining,
    required this.isRunning,
    required this.isBreak,
    this.targetLocked = false,
    this.activeTargetId,
    this.activeTargetTitle,
    this.activeTargetType,
  });

  FocusState copyWith({
    int? durationRemaining,
    bool? isRunning,
    bool? isBreak,
    bool? targetLocked,
    Object? activeTargetId = _keepCurrentTargetValue,
    Object? activeTargetTitle = _keepCurrentTargetValue,
    Object? activeTargetType = _keepCurrentTargetValue,
  }) {
    return FocusState(
      durationRemaining: durationRemaining ?? this.durationRemaining,
      isRunning: isRunning ?? this.isRunning,
      isBreak: isBreak ?? this.isBreak,
      targetLocked: targetLocked ?? this.targetLocked,
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
  int _lifecycleGeneration = 0;
  String? _verifiedSessionId;
  _PendingVerifiedInvalidation? _pendingVerifiedInvalidation;
  _FocusCycleContext? _activeCycle;
  int _timerDurationInSeconds = 1500; // Armazena a duração atual configurada

  @override
  FocusState build() {
    // Riverpod may rebuild this notifier after invalidation. Its fresh state
    // must not retain an old cycle or an in-flight remote operation.
    _isStartingVerifiedSession = false;
    _isCompletingSession = false;
    _cycleCanBeVerified = true;
    _verifiedSessionId = null;
    _pendingVerifiedInvalidation = null;
    _activeCycle = null;
    _timerDurationInSeconds = 1500;
    ref.onDispose(() {
      _startGeneration++;
      _lifecycleGeneration++;
      _timer?.cancel();
    });

    return const FocusState(
      durationRemaining: 1500, // Padrão: 25 minutos
      isRunning: false,
      isBreak: false,
    );
  }

  void selectTarget(String id, String title, FocusTargetType targetType) {
    if (state.targetLocked || state.isRunning || _isStartingVerifiedSession) {
      return;
    }

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
    state = state.copyWith(targetLocked: true);
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
      admission: ref.read(databaseProvider).localMutations.capture(),
      remoteAdmission: _captureCycleRemoteAdmission(),
    );
  }

  RemoteSendPermit? _captureCycleRemoteAdmission() {
    final lifecycle = _lifecycleGeneration;
    try {
      return ref
          .read(focusRemoteSendPermitProvider)()
          .and(() => ref.mounted && lifecycle == _lifecycleGeneration);
    } on RemoteSessionStopped {
      return null;
    }
  }

  bool _canStartVerifiedSession(_FocusCycleContext? cycle) {
    return !state.isBreak &&
        cycle != null &&
        _cycleCanBeVerified &&
        state.durationRemaining == _timerDurationInSeconds &&
        isVerifiedFocusDuration(cycle.plannedDurationSeconds);
  }

  Future<void> _startVerifiedThenLocal(
    _FocusCycleContext cycle,
    int generation,
  ) async {
    final admission = cycle.remoteAdmission;
    try {
      if (admission == null) throw const RemoteSessionStopped();
      admission.requireCurrent();
      final invalidation = _pendingVerifiedInvalidation;
      if (invalidation != null) {
        final wasCancelled = await _ensureInvalidationCancel(invalidation);
        if (!admission.isCurrent || generation != _startGeneration) return;

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
            admission: admission,
          );

      if (!admission.isCurrent) return;
      if (generation != _startGeneration) {
        _beginPendingVerifiedInvalidation(response.sessionId, admission);
        return;
      }

      _verifiedSessionId = response.sessionId;
      _startLocalTimer(cycle);
    } catch (_) {
      if (!ref.mounted ||
          generation != _startGeneration ||
          (admission != null && !admission.isCurrent))
        return;

      AppLogger.w(
        'Focus verificado indisponível no início; sessão continuará local.',
      );
      _startLocalTimer(cycle);
    } finally {
      if (ref.mounted && generation == _startGeneration) {
        _isStartingVerifiedSession = false;
        if (admission != null && !admission.isCurrent) {
          try {
            // Only restore idle UI in the original local session. Waiting for
            // quiescence holds no lease and never renews remote admission.
            await ref.read(databaseProvider).localMutations.run(() async {
              if (ref.mounted &&
                  generation == _startGeneration &&
                  !state.isRunning &&
                  _activeCycle == null) {
                state = state.copyWith(targetLocked: false);
              }
            }, ticket: cycle.admission);
          } catch (_) {
            // Disposed or changed/unavailable sessions must keep their state.
          }
        }
      }
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
    final startingRemaining = state.durationRemaining;
    state = state.copyWith(
      isRunning: true,
      targetLocked: !state.isBreak && cycle != null,
    );

    _timer = ref.read(focusPeriodicTimerFactoryProvider)(
      const Duration(seconds: 1),
      (timer) {
        if (!ref.mounted) return;
        final remaining = startingRemaining - timer.tick;
        if (remaining > 0) {
          state = state.copyWith(durationRemaining: remaining);
        } else {
          _timer?.cancel();
          state = state.copyWith(durationRemaining: 0, isRunning: false);
          unawaited(_handleSessionEnd());
        }
      },
    );
  }

  Future<void> _handleSessionEnd() async {
    if (!ref.mounted) return;
    final cycle = _activeCycle;
    try {
      await ref
          .read(databaseProvider)
          .localMutations
          .run(_completeLocalSession, ticket: cycle?.admission);
    } on LocalMutationUnavailable {
      // A confirmed sign-out must not revive this timer's old session.
    }
  }

  Future<void> _completeLocalSession() async {
    if (!ref.mounted) return;
    if (_isCompletingSession) return;

    _isCompletingSession = true;
    final analytics = ref.read(analyticsServiceProvider);

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

        if (!ref.mounted) return;

        // 2. Atualiza Tarefa se for do tipo TASK
        if (targetType == FocusTargetType.task) {
          await ref
              .read(tasksRepositoryProvider)
              .toggleTaskStatus(targetIdStr, false);
          unawaited(
            ref.read(syncManagerProvider).processPendingItems().catchError((
              Object _,
              StackTrace _,
            ) {
              AppLogger.w('Não foi possível enviar a tarefa do Focus agora.');
              return false;
            }),
          );
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
      if (ref.mounted && !state.isBreak) {
        final durationSeconds =
            cycle?.plannedDurationSeconds ?? _timerDurationInSeconds;
        unawaited(
          analytics.logFocusCompleted(durationMinutes: durationSeconds ~/ 60),
        );
      }
      if (ref.mounted) toggleSessionType();
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
          .finishFocus(sessionId: sessionId, admission: cycle.remoteAdmission);
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
    _isStartingVerifiedSession = false;
    final sessionId = _takeVerifiedSession();
    if (sessionId != null) {
      _beginPendingVerifiedInvalidation(
        sessionId,
        _activeCycle!.remoteAdmission!,
      );
    }
  }

  void resetTimer() {
    _timer?.cancel();
    _startGeneration++;
    _isStartingVerifiedSession = false;
    final sessionId = _takeVerifiedSession();
    if (sessionId != null) {
      _beginPendingVerifiedInvalidation(
        sessionId,
        _activeCycle!.remoteAdmission!,
      );
    }
    _activeCycle = null;
    _cycleCanBeVerified = true;
    state = state.copyWith(
      durationRemaining: state.isBreak ? 300 : _timerDurationInSeconds,
      isRunning: false,
      targetLocked: false,
    );
  }

  void toggleSessionType() {
    _timer?.cancel();
    _startGeneration++;
    _isStartingVerifiedSession = false;
    final sessionId = _takeVerifiedSession();
    if (sessionId != null) {
      _beginPendingVerifiedInvalidation(
        sessionId,
        _activeCycle!.remoteAdmission!,
      );
    }
    _activeCycle = null;
    _cycleCanBeVerified = true;
    final nextIsBreak = !state.isBreak;
    state = state.copyWith(
      durationRemaining: nextIsBreak ? 300 : _timerDurationInSeconds,
      isRunning: false,
      isBreak: nextIsBreak,
      targetLocked: false,
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

  void _beginPendingVerifiedInvalidation(
    String sessionId,
    RemoteSendPermit admission,
  ) {
    if (!admission.isCurrent) return;
    final currentInvalidation = _pendingVerifiedInvalidation;
    if (currentInvalidation != null &&
        currentInvalidation.sessionId == sessionId) {
      unawaited(_ensureInvalidationCancel(currentInvalidation));
      return;
    }

    final invalidation = _PendingVerifiedInvalidation(sessionId, admission);
    _pendingVerifiedInvalidation = invalidation;
    unawaited(_ensureInvalidationCancel(invalidation));
  }

  Future<bool> _ensureInvalidationCancel(
    _PendingVerifiedInvalidation invalidation,
  ) {
    final existingAttempt = invalidation.cancelAttempt;
    if (existingAttempt != null) return existingAttempt;

    final attempt = _cancelRemoteSession(invalidation);
    invalidation.cancelAttempt = attempt;
    unawaited(
      attempt.then((wasCancelled) {
        if (!invalidation.admission.isCurrent ||
            !identical(_pendingVerifiedInvalidation, invalidation) ||
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

  Future<bool> _cancelRemoteSession(
    _PendingVerifiedInvalidation invalidation,
  ) async {
    try {
      invalidation.admission.requireCurrent();
      final response = await ref
          .read(focusRemoteDataSourceProvider)
          .cancelFocus(
            sessionId: invalidation.sessionId,
            admission: invalidation.admission,
          );
      if (!invalidation.admission.isCurrent) return false;
      if (response.sessionId != invalidation.sessionId) {
        AppLogger.w('Resposta incoerente ao cancelar Focus verificado.');
        return false;
      }
      return true;
    } on FocusRemoteException catch (error) {
      if (invalidation.admission.isCurrent &&
          error.code == 'FOCUS_SESSION_EXPIRED')
        return true;

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
