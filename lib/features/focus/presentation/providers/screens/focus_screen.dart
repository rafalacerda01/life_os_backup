import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/features/focus/presentation/providers/providers/focus_provider.dart';
import 'package:life_os/features/focus/presentation/providers/screens/target_selection_screen.dart';
import 'package:life_os/features/circles/domain/entities/challenge_entity.dart';
import 'package:life_os/features/circles/presentation/circle_focus_contribution_provider.dart';

class FocusScreen extends ConsumerWidget {
  const FocusScreen({super.key});

  static const Color _background = Color(0xFF070B14);
  static const Color _surface = Color(0xFF0E1526);
  static const Color _surfaceElevated = Color(0xFF111A2E);

  static const Color _purple = Color(0xFF7C3AED);
  static const Color _purpleBright = Color(0xFFB026FF);

  static const Color _green = Color(0xFF34D399);

  static const Color _textPrimary = Colors.white;
  static const Color _textSecondary = Color(0xFF9CA3AF);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final focusState = ref.watch(focusProvider);

    final activeCircleIdAsync = ref.watch(activeCircleIdForFocusProvider);
    final activeCircleId = activeCircleIdAsync.asData?.value;

    final circleChallengesAsync = activeCircleId == null
        ? null
        : ref.watch(circleChallengeWindowsProvider(activeCircleId));

    final circleChallenges =
        circleChallengesAsync?.asData?.value ?? const <CircleChallengeWindow>[];

    final eligibleCircleChallengeCount = _eligibleCircleChallengeCount(
      focusState,
      circleChallenges,
    );

    final minutes = (focusState.durationRemaining ~/ 60).toString().padLeft(
      2,
      '0',
    );

    final seconds = (focusState.durationRemaining % 60).toString().padLeft(
      2,
      '0',
    );

    final hasTarget = focusState.activeTargetId != null;
    final isBreak = focusState.isBreak;

    return Scaffold(
      backgroundColor: _background,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isCompactHeight = constraints.maxHeight < 700;

            final timerSize = math.min(
              constraints.maxWidth - 72,
              isCompactHeight ? 250.0 : 290.0,
            );

            return SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              padding: EdgeInsets.fromLTRB(
                20,
                isCompactHeight ? 12 : 20,
                20,
                28,
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight:
                      constraints.maxHeight - (isCompactHeight ? 40 : 56),
                ),
                child: Column(
                  children: [
                    _buildHeader(focusState),

                    SizedBox(height: isCompactHeight ? 18 : 26),

                    _buildTargetCard(context, focusState),

                    if (eligibleCircleChallengeCount > 0) ...[
                      SizedBox(height: isCompactHeight ? 12 : 16),
                      _buildCircleContributionBanner(
                        eligibleCircleChallengeCount,
                      ),
                    ],

                    SizedBox(height: isCompactHeight ? 18 : 24),

                    _buildSessionType(isBreak: isBreak),

                    SizedBox(height: isCompactHeight ? 12 : 18),

                    _buildTimer(
                      focusState: focusState,
                      minutes: minutes,
                      seconds: seconds,
                      size: timerSize,
                    ),

                    SizedBox(height: isCompactHeight ? 18 : 26),

                    _buildDurationSection(ref, focusState),

                    SizedBox(height: isCompactHeight ? 18 : 26),

                    _buildControls(
                      context,
                      ref,
                      focusState,
                      hasTarget: hasTarget,
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  // ===========================================================================
  // HEADER
  // ===========================================================================

  Widget _buildHeader(FocusState focusState) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'FOCUS',
                style: TextStyle(
                  color: _purpleBright,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 2.4,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                focusState.isBreak ? 'Hora de respirar' : 'Hora de focar',
                style: const TextStyle(
                  color: _textPrimary,
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                ),
              ),
            ],
          ),
        ),

        _buildStatusBadge(focusState),
      ],
    );
  }

  Widget _buildStatusBadge(FocusState focusState) {
    final isActive = focusState.isRunning;

    final Color statusColor;

    if (!isActive) {
      statusColor = Colors.white38;
    } else if (focusState.isBreak) {
      statusColor = _green;
    } else {
      statusColor = _purpleBright;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: statusColor,
              boxShadow: isActive
                  ? [
                      BoxShadow(
                        color: statusColor.withValues(alpha: 0.55),
                        blurRadius: 8,
                      ),
                    ]
                  : null,
            ),
          ),
          const SizedBox(width: 7),
          Text(
            isActive ? 'ATIVO' : 'PRONTO',
            style: TextStyle(
              color: isActive ? Colors.white : _textSecondary,
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 1,
            ),
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // TARGET
  // ===========================================================================

  Widget _buildTargetCard(BuildContext context, FocusState focusState) {
    final hasTarget = focusState.activeTargetId != null;

    return GestureDetector(
      onTap: focusState.isRunning
          ? null
          : () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const TargetSelectionScreen(),
                ),
              );
            },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: _surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: hasTarget
                ? _purple.withValues(alpha: 0.55)
                : Colors.white.withValues(alpha: 0.07),
          ),
          boxShadow: hasTarget
              ? [
                  BoxShadow(
                    color: _purple.withValues(alpha: 0.10),
                    blurRadius: 24,
                  ),
                ]
              : null,
        ),
        child: Row(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: hasTarget
                    ? _purple.withValues(alpha: 0.14)
                    : Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(
                hasTarget
                    ? Icons.track_changes_rounded
                    : Icons.add_task_rounded,
                color: hasTarget ? _purpleBright : Colors.white38,
                size: 23,
              ),
            ),

            const SizedBox(width: 13),

            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    hasTarget ? 'ALVO ATUAL' : 'NENHUM ALVO SELECIONADO',
                    style: TextStyle(
                      color: hasTarget ? _purpleBright : _textSecondary,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.1,
                    ),
                  ),

                  const SizedBox(height: 5),

                  Text(
                    focusState.activeTargetTitle ??
                        'Selecione uma tarefa ou matéria',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: hasTarget ? _textPrimary : Colors.white54,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(width: 10),

            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(
                Icons.chevron_right_rounded,
                color: Colors.white54,
                size: 20,
              ),
            ),
          ],
        ),
      ),
    );
  }

  int _eligibleCircleChallengeCount(
    FocusState focusState,
    List<CircleChallengeWindow> challenges,
  ) {
    if (focusState.isBreak ||
        focusState.isRunning ||
        focusState.activeTargetType == null) {
      return 0;
    }

    final durationSeconds = focusState.durationRemaining;

    if (!isVerifiedFocusDuration(durationSeconds)) {
      return 0;
    }

    final acceptedTypes = switch (focusState.activeTargetType!) {
      FocusTargetType.task => <ChallengeType>{ChallengeType.focusMinutes},
      FocusTargetType.subject => <ChallengeType>{
        ChallengeType.focusMinutes,
        ChallengeType.studyMinutes,
      },
    };

    return countEligibleCircleChallenges(
      challenges: challenges,
      acceptedTypes: acceptedTypes,
      sessionDurationSeconds: durationSeconds,
    );
  }

  Widget _buildCircleContributionBanner(int challengeCount) {
    final challengeLabel = challengeCount == 1
        ? '1 desafio ativo'
        : '$challengeCount desafios ativos';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: _purple.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _purpleBright.withValues(alpha: 0.24)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: _purpleBright.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(
              Icons.groups_rounded,
              color: _purpleBright,
              size: 21,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'CONTRIBUIÇÃO PARA O CÍRCULO',
                  style: TextStyle(
                    color: _purpleBright,
                    fontSize: 10,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Esta sessão pode contribuir para '
                  '$challengeLabel do seu Círculo.',
                  style: const TextStyle(
                    color: _textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 5),
                const Text(
                  'Após a conclusão verificada, o progresso é '
                  'creditado automaticamente.',
                  style: TextStyle(
                    color: _textSecondary,
                    fontSize: 11,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
  // ===========================================================================
  // FOCO / PAUSA
  // ===========================================================================

  Widget _buildSessionType({required bool isBreak}) {
    return Container(
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _sessionBadge(label: 'FOCO', active: !isBreak, color: _purpleBright),
          _sessionBadge(label: 'PAUSA', active: isBreak, color: _green),
        ],
      ),
    );
  }

  Widget _sessionBadge({
    required String label,
    required bool active,
    required Color color,
  }) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
      decoration: BoxDecoration(
        color: active ? color.withValues(alpha: 0.14) : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: active ? color : Colors.white38,
          fontSize: 11,
          fontWeight: FontWeight.w900,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  // ===========================================================================
  // TIMER
  // ===========================================================================

  Widget _buildTimer({
    required FocusState focusState,
    required String minutes,
    required String seconds,
    required double size,
  }) {
    final isBreak = focusState.isBreak;

    final progressColor = isBreak ? _green : _purpleBright;

    final progress = _calculateProgress(focusState);

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // -------------------------------------------------------------------
          // ANEL DE FUNDO
          // -------------------------------------------------------------------
          SizedBox(
            width: size,
            height: size,
            child: CircularProgressIndicator(
              value: 1,
              strokeWidth: 8,
              strokeCap: StrokeCap.round,
              color: Colors.white.withValues(alpha: 0.055),
            ),
          ),

          // -------------------------------------------------------------------
          // PROGRESSO REAL
          // -------------------------------------------------------------------
          SizedBox(
            width: size,
            height: size,
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: progress, end: progress),
              duration: const Duration(milliseconds: 400),
              curve: Curves.easeOut,
              builder: (context, value, child) {
                return CircularProgressIndicator(
                  value: value,
                  strokeWidth: 8,
                  strokeCap: StrokeCap.round,
                  color: progressColor,
                );
              },
            ),
          ),

          // -------------------------------------------------------------------
          // GLOW
          // -------------------------------------------------------------------
          Container(
            width: size - 34,
            height: size - 34,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _surfaceElevated,
              boxShadow: [
                BoxShadow(
                  color: progressColor.withValues(alpha: 0.13),
                  blurRadius: 35,
                  spreadRadius: 3,
                ),
              ],
            ),
          ),

          // -------------------------------------------------------------------
          // BORDA INTERNA
          // -------------------------------------------------------------------
          Container(
            width: size - 48,
            height: size - 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: progressColor.withValues(alpha: 0.08)),
            ),
          ),

          // -------------------------------------------------------------------
          // CONTEÚDO
          // -------------------------------------------------------------------
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isBreak ? Icons.self_improvement_rounded : Icons.bolt_rounded,
                color: progressColor,
                size: 22,
              ),

              const SizedBox(height: 8),

              Text(
                '$minutes:$seconds',
                style: TextStyle(
                  color: _textPrimary,
                  fontSize: size >= 270 ? 48 : 42,
                  fontWeight: FontWeight.w800,
                  fontFamily: 'monospace',
                  letterSpacing: -2,
                ),
              ),

              const SizedBox(height: 5),

              Text(
                isBreak
                    ? 'PAUSA'
                    : focusState.isRunning
                    ? 'MANTENHA O FOCO'
                    : 'PRONTO PARA COMEÇAR',
                style: TextStyle(
                  color: isBreak ? _green : Colors.white54,
                  fontSize: 9,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.3,
                ),
              ),

              const SizedBox(height: 8),

              Text(
                '${(progress * 100).round()}%',
                style: TextStyle(
                  color: progressColor.withValues(alpha: 0.75),
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // PROGRESSO REAL
  // ===========================================================================

  double _calculateProgress(FocusState focusState) {
    if (focusState.isBreak) {
      const breakDuration = 300;

      if (focusState.durationRemaining <= 0) {
        return 1;
      }

      return (1 - (focusState.durationRemaining / breakDuration)).clamp(
        0.0,
        1.0,
      );
    }

    /*
     * O provider mantém internamente:
     *
     * _timerDurationInSeconds
     *
     * Porém esse valor é privado.
     *
     * Como a FocusScreen só recebe FocusState, usamos o valor
     * atual da sessão para estimar o progresso visual.
     *
     * Para o progresso matematicamente perfeito, o ideal seria
     * expor o total no FocusState.
     */

    const presetDurations = [60, 180, 600, 1500, 2700];

    final remaining = focusState.durationRemaining;

    if (remaining <= 0) {
      return 1;
    }

    /*
     * Identifica o preset correspondente ao tempo restante.
     */
    int total = presetDurations.last;

    for (final duration in presetDurations) {
      if (remaining <= duration) {
        total = duration;
        break;
      }
    }

    return (1 - (remaining / total)).clamp(0.0, 1.0);
  }

  // ===========================================================================
  // DURAÇÃO
  // ===========================================================================

  Widget _buildDurationSection(WidgetRef ref, FocusState focusState) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'DURAÇÃO DA SESSÃO',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.2,
                  ),
                ),
              ),

              if (focusState.isRunning)
                const Row(
                  children: [
                    Icon(
                      Icons.lock_outline_rounded,
                      size: 13,
                      color: Colors.white30,
                    ),
                    SizedBox(width: 5),
                    Text(
                      'BLOQUEADO',
                      style: TextStyle(
                        color: Colors.white30,
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ],
                ),
            ],
          ),

          const SizedBox(height: 13),

          Row(
            children: [
              Expanded(
                child: _buildDurationChip(
                  ref,
                  focusState,
                  label: '1m',
                  minutes: 1,
                ),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: _buildDurationChip(
                  ref,
                  focusState,
                  label: '3m',
                  minutes: 3,
                ),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: _buildDurationChip(
                  ref,
                  focusState,
                  label: '10m',
                  minutes: 10,
                ),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: _buildDurationChip(
                  ref,
                  focusState,
                  label: '25m',
                  minutes: 25,
                ),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: _buildDurationChip(
                  ref,
                  focusState,
                  label: '45m',
                  minutes: 45,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDurationChip(
    WidgetRef ref,
    FocusState focusState, {
    required String label,
    required int minutes,
  }) {
    final currentMinutes = focusState.durationRemaining ~/ 60;

    final isSelected = currentMinutes == minutes && !focusState.isBreak;

    final isLocked = focusState.isRunning;

    return GestureDetector(
      onTap: isLocked
          ? null
          : () {
              ref.read(focusProvider.notifier).setCustomDuration(minutes);
            },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isSelected
              ? _purple.withValues(alpha: 0.20)
              : Colors.white.withValues(alpha: 0.035),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected
                ? _purpleBright.withValues(alpha: 0.75)
                : Colors.white.withValues(alpha: 0.055),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isLocked
                ? Colors.white24
                : isSelected
                ? Colors.white
                : Colors.white60,
            fontSize: 12,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }

  // ===========================================================================
  // CONTROLES
  // ===========================================================================

  Widget _buildControls(
    BuildContext context,
    WidgetRef ref,
    FocusState focusState, {
    required bool hasTarget,
  }) {
    final canPlay = hasTarget;

    return Column(
      children: [
        GestureDetector(
          onTap: canPlay
              ? () {
                  final notifier = ref.read(focusProvider.notifier);

                  if (focusState.isRunning) {
                    notifier.pauseTimer();
                  } else {
                    notifier.startTimer();
                  }
                }
              : () {
                  ScaffoldMessenger.of(context).hideCurrentSnackBar();

                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: const Row(
                        children: [
                          Icon(Icons.info_outline_rounded, color: Colors.white),
                          SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Selecione uma tarefa ou matéria primeiro.',
                            ),
                          ),
                        ],
                      ),
                      backgroundColor: _surfaceElevated,
                      behavior: SnackBarBehavior.floating,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 76,
            height: 76,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: canPlay
                  ? _purpleBright
                  : Colors.white.withValues(alpha: 0.06),
              boxShadow: canPlay
                  ? [
                      BoxShadow(
                        color: _purpleBright.withValues(alpha: 0.28),
                        blurRadius: 28,
                        spreadRadius: 2,
                      ),
                    ]
                  : null,
            ),
            child: Icon(
              focusState.isRunning
                  ? Icons.pause_rounded
                  : Icons.play_arrow_rounded,
              color: canPlay ? Colors.white : Colors.white24,
              size: 38,
            ),
          ),
        ),

        const SizedBox(height: 13),

        Text(
          !hasTarget
              ? 'SELECIONE UM ALVO PARA COMEÇAR'
              : focusState.isRunning
              ? 'PAUSAR SESSÃO'
              : 'INICIAR SESSÃO',
          style: TextStyle(
            color: hasTarget ? Colors.white54 : Colors.white30,
            fontSize: 9,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.1,
          ),
        ),

        const SizedBox(height: 12),

        TextButton.icon(
          onPressed: () {
            ref.read(focusProvider.notifier).resetTimer();
          },
          style: TextButton.styleFrom(
            foregroundColor: Colors.white54,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          ),
          icon: const Icon(Icons.restart_alt_rounded, size: 18),
          label: const Text(
            'Redefinir sessão',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}
