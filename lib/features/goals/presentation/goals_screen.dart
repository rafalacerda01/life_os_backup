import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/core/services/sync_manager_provider.dart';
import 'package:life_os/features/goals/presentation/goals_provider.dart';
import 'package:life_os/core/security/input_sanitizer.dart';
import 'package:life_os/core/utils/app_logger.dart';
import 'package:life_os/features/premium/domain/services/plan_limits.dart';
import 'package:life_os/features/premium/domain/services/quota_service.dart';
import 'package:life_os/features/premium/presentation/plan_limits_provider.dart';

class GoalsScreen extends ConsumerStatefulWidget {
  const GoalsScreen({super.key});

  @override
  ConsumerState<GoalsScreen> createState() => _GoalsScreenState();
}

class _GoalsScreenState extends ConsumerState<GoalsScreen> {
  static const Color _backgroundColor = Color(0xFF070B14);
  static const Color _cardColor = Color(0xFF11182E);
  static const Color _cardSecondaryColor = Color(0xFF0D1326);
  static const Color _primaryColor = Color(0xFFB026FF);
  static const Color _successColor = Color(0xFF45E6A3);
  static const Color _dangerColor = Color(0xFFFF5C70);
  static const Color _white45 = Color(0x73FFFFFF);
  static const Color _white38 = Color(0x61FFFFFF);
  static const Color _white60 = Color(0x99FFFFFF);

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_syncPendingThenHydrateGoals());
    });
  }

  Future<void> _syncPendingThenHydrateGoals() async {
    try {
      final queueDrained = await ref
          .read(syncManagerProvider)
          .processPendingItems();
      if (!mounted || !queueDrained) return;
      await ref.read(goalRepositoryProvider).syncGoalsFromFirebaseToLocal();
    } catch (_) {
      AppLogger.w('Não foi possível sincronizar metas neste momento.');
    }
  }

  void _schedulePendingGoalSync() {
    if (!mounted) return;
    unawaited(
      ref.read(syncManagerProvider).processPendingItems().catchError((
        Object _,
      ) {
        AppLogger.w('Não foi possível sincronizar metas neste momento.');
        return false;
      }),
    );
  }

  Future<void> _updateGoalProgress(String goalId, int value) async {
    await ref.read(goalRepositoryProvider).updateGoalProgress(goalId, value);
    _schedulePendingGoalSync();
  }

  Future<void> _resetGoalCycle(String goalId) async {
    await ref.read(goalRepositoryProvider).resetGoalCycle(goalId);
    _schedulePendingGoalSync();
  }

  // ===========================================================================
  // EXCLUSÃO
  // ===========================================================================

  void _showDeleteConfirmationDialog(
    BuildContext context,
    WidgetRef ref,
    String goalId,
    String goalTitle,
  ) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: _cardColor,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
          contentPadding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
          actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          title: const Row(
            children: [
              Icon(Icons.delete_outline_rounded, color: _dangerColor, size: 24),
              SizedBox(width: 10),
              Text(
                'Excluir meta?',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          content: Text(
            'Tem certeza que deseja apagar a meta "$goalTitle"? '
            'Essa ação não pode ser desfeita.',
            style: const TextStyle(color: _white60, fontSize: 14, height: 1.45),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text(
                'Cancelar',
                style: TextStyle(color: _white60, fontWeight: FontWeight.w600),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: _dangerColor,
                foregroundColor: Colors.white,
                elevation: 0,
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 12,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed: () async {
                await ref.read(goalRepositoryProvider).removeGoal(goalId);
                _schedulePendingGoalSync();
                if (context.mounted) {
                  Navigator.pop(context);
                }
              },
              child: const Text(
                'Excluir',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        );
      },
    );
  }

  // ===========================================================================
  // CRIAÇÃO DE META
  // ===========================================================================

  void _showAddGoalModal(BuildContext context, WidgetRef ref) {
    final titleController = TextEditingController();
    final targetController = TextEditingController();
    String selectedTimeframe = 'DIÁRIA';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Container(
              decoration: const BoxDecoration(
                color: _cardColor,
                borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
              ),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: EdgeInsets.only(
                    bottom: MediaQuery.of(context).viewInsets.bottom + 20,
                    top: 12,
                    left: 20,
                    right: 20,
                  ),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Center(
                          child: Container(
                            width: 42,
                            height: 4,
                            decoration: BoxDecoration(
                              color: _white45,
                              borderRadius: BorderRadius.circular(20),
                            ),
                          ),
                        ),
                        const SizedBox(height: 24),
                        const Row(
                          children: [
                            _ModalIcon(),
                            SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Nova meta',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 21,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  SizedBox(height: 3),
                                  Text(
                                    'Defina um resultado mensurável para acompanhar por ciclo.',
                                    style: TextStyle(
                                      color: _white45,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 24),
                        _ModalLabel(
                          icon: Icons.flag_outlined,
                          label: 'Nome da meta',
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: titleController,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                          ),
                          textInputAction: TextInputAction.next,
                          decoration: _modalInputDecoration(
                            hintText: 'Ex.: Páginas lidas',
                          ),
                        ),
                        const SizedBox(height: 18),
                        _ModalLabel(
                          icon: Icons.calendar_today_outlined,
                          label: 'Ciclo',
                        ),
                        const SizedBox(height: 8),
                        Container(
                          decoration: BoxDecoration(
                            color: _backgroundColor,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.06),
                            ),
                          ),
                          child: DropdownButtonFormField<String>(
                            initialValue: selectedTimeframe,
                            dropdownColor: _cardColor,
                            icon: const Icon(
                              Icons.keyboard_arrow_down_rounded,
                              color: _white60,
                            ),
                            decoration: const InputDecoration(
                              border: InputBorder.none,
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 4,
                              ),
                            ),
                            items: ['DIÁRIA', 'SEMANAL', 'MENSAL']
                                .map(
                                  (s) => DropdownMenuItem(
                                    value: s,
                                    child: Text(
                                      _formatPeriod(s),
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                )
                                .toList(),
                            onChanged: (value) {
                              if (value != null) {
                                setModalState(() => selectedTimeframe = value);
                              }
                            },
                          ),
                        ),
                        const SizedBox(height: 18),
                        _ModalLabel(
                          icon: Icons.track_changes_rounded,
                          label: 'Alvo do ciclo',
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: targetController,
                          keyboardType: TextInputType.number,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                          ),
                          decoration: _modalInputDecoration(
                            hintText: 'Ex.: 10',
                          ),
                        ),
                        const SizedBox(height: 7),
                        const Text(
                          'O progresso é ajustado em passos de 1.',
                          style: TextStyle(color: _white45, fontSize: 11),
                        ),
                        const SizedBox(height: 24),
                        SizedBox(
                          width: double.infinity,
                          height: 54,
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _primaryColor,
                              foregroundColor: Colors.white,
                              elevation: 0,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                            ),
                            onPressed: () async {
                              final title = InputSanitizer.sanitize(
                                titleController.text,
                              );
                              final target = int.tryParse(
                                targetController.text.trim(),
                              );

                              if (title.isEmpty) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        'Informe um nome para a meta.',
                                      ),
                                    ),
                                  );
                                }
                                return;
                              }

                              if (title.length > 200) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        'O nome da meta deve ter no máximo 200 caracteres.',
                                      ),
                                    ),
                                  );
                                }
                                return;
                              }

                              if (target == null || target <= 0) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        'Informe um objetivo numérico maior que zero.',
                                      ),
                                    ),
                                  );
                                }
                                return;
                              }

                              final goalsAsync = ref.read(goalsStreamProvider);

                              if (!goalsAsync.hasValue) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        'Não foi possível verificar suas metas agora. Tente novamente.',
                                      ),
                                    ),
                                  );
                                }
                                return;
                              }

                              final goals = goalsAsync.requireValue;

                              final limits = ref.read(planLimitsProvider);
                              const quotaService = QuotaService();

                              final goalLimit = limits.limitFor(
                                QuotaResource.goals,
                              );

                              final canCreate = quotaService.canCreate(
                                limit: goalLimit,
                                currentCount: goals.length,
                              );

                              if (!canCreate) {
                                final message = switch (goalLimit.mode) {
                                  QuotaMode.disabled =>
                                    'Este recurso não está disponível no seu plano.',
                                  QuotaMode.limited =>
                                    'Você atingiu o limite de ${goalLimit.maximum} metas do seu plano.',
                                  QuotaMode.unlimited =>
                                    'Você não possui limite de metas.',
                                  QuotaMode.notConfigured =>
                                    'O limite deste recurso ainda não está configurado.',
                                };

                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text(message)),
                                  );
                                }

                                return;
                              }

                              await ref
                                  .read(goalRepositoryProvider)
                                  .createGoal(title, selectedTimeframe, target);

                              _schedulePendingGoalSync();

                              if (context.mounted) {
                                Navigator.pop(context);
                              }
                            },
                            child: const Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.check_rounded, size: 20),
                                SizedBox(width: 8),
                                Text(
                                  'Criar meta',
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  // ===========================================================================
  // BUILD
  // ===========================================================================

  @override
  Widget build(BuildContext context) {
    final goalsAsync = ref.watch(goalsStreamProvider);

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        backgroundColor: _backgroundColor,
        appBar: AppBar(
          backgroundColor: _backgroundColor,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          centerTitle: false,
          titleSpacing: 20,
          title: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Minhas metas',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 25,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.4,
                ),
              ),
              SizedBox(height: 3),
              Text(
                'Acompanhe alvos recorrentes por ciclo.',
                style: TextStyle(
                  color: _white45,
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ],
          ),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(58),
            child: Container(
              margin: const EdgeInsets.fromLTRB(16, 14, 16, 0),
              height: 44,
              decoration: BoxDecoration(
                color: _cardSecondaryColor,
                borderRadius: BorderRadius.circular(14),
              ),
              child: TabBar(
                indicatorSize: TabBarIndicatorSize.tab,
                dividerColor: Colors.transparent,
                indicator: BoxDecoration(
                  color: _primaryColor,
                  borderRadius: BorderRadius.circular(11),
                ),
                labelColor: Colors.white,
                unselectedLabelColor: _white45,
                labelStyle: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
                unselectedLabelStyle: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
                padding: const EdgeInsets.all(3),
                tabs: const [
                  Tab(text: 'Diárias'),
                  Tab(text: 'Semanais'),
                  Tab(text: 'Mensais'),
                ],
              ),
            ),
          ),
        ),
        body: goalsAsync.when(
          loading: () => const Center(
            child: CircularProgressIndicator(
              color: _primaryColor,
              strokeWidth: 2.5,
            ),
          ),
          error: (_, _) =>
              _ErrorState(onRetry: () => ref.invalidate(goalsStreamProvider)),
          data: (goalsList) {
            // =================================================================
            // LÓGICA ORIGINAL DE RESET
            // =================================================================

            final now = DateTime.now();

            for (final goal in goalsList) {
              bool precisaResetar = false;
              final lastReset = goal.lastReset;

              if (goal.period == 'DIÁRIA') {
                precisaResetar =
                    lastReset.day != now.day ||
                    lastReset.month != now.month ||
                    lastReset.year != now.year;
              } else if (goal.period == 'MENSAL') {
                precisaResetar =
                    lastReset.month != now.month || lastReset.year != now.year;
              } else if (goal.period == 'SEMANAL') {
                final deSegunda = lastReset.subtract(
                  Duration(days: lastReset.weekday - 1),
                );

                final hojeSegunda = now.subtract(
                  Duration(days: now.weekday - 1),
                );

                precisaResetar =
                    deSegunda.day != hojeSegunda.day ||
                    deSegunda.month != hojeSegunda.month ||
                    deSegunda.year != hojeSegunda.year;
              }

              if (precisaResetar) {
                Future.microtask(() => _resetGoalCycle(goal.id));
              }
            }

            return TabBarView(
              children: ['DIÁRIA', 'SEMANAL', 'MENSAL'].map((timeframe) {
                final filteredGoals = goalsList
                    .where((goal) => goal.period == timeframe)
                    .toList();

                if (filteredGoals.isEmpty) {
                  return _EmptyGoalsState(
                    timeframe: timeframe,
                    onAdd: () => _showAddGoalModal(context, ref),
                  );
                }

                final reachedGoals = filteredGoals
                    .where((goal) => goal.currentValue >= goal.targetValue)
                    .length;

                return ListView.builder(
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(20, 22, 20, 110),
                  itemCount: filteredGoals.length + 1,
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return _CycleSummary(
                        period: timeframe,
                        total: filteredGoals.length,
                        reached: reachedGoals,
                      );
                    }

                    final goal = filteredGoals[index - 1];

                    final double progress = goal.targetValue > 0
                        ? (goal.currentValue / goal.targetValue).clamp(0.0, 1.0)
                        : 0.0;

                    final bool isCompleted =
                        goal.currentValue >= goal.targetValue;

                    return _GoalCard(
                      goal: goal,
                      progress: progress,
                      isCompleted: isCompleted,
                      onDecrease: goal.currentValue > 0
                          ? () => _updateGoalProgress(
                              goal.id,
                              goal.currentValue - 1,
                            )
                          : null,
                      onIncrease: goal.currentValue < goal.targetValue
                          ? () => _updateGoalProgress(
                              goal.id,
                              goal.currentValue + 1,
                            )
                          : null,
                      onDelete: () => _showDeleteConfirmationDialog(
                        context,
                        ref,
                        goal.id,
                        goal.title,
                      ),
                    );
                  },
                );
              }).toList(),
            );
          },
        ),
        floatingActionButton: FloatingActionButton(
          backgroundColor: _primaryColor,
          foregroundColor: Colors.white,
          elevation: 8,
          onPressed: () => _showAddGoalModal(context, ref),
          child: const Icon(Icons.add_rounded, size: 28),
        ),
      ),
    );
  }

  static String _formatPeriod(String period) {
    switch (period) {
      case 'DIÁRIA':
        return 'Diária';
      case 'SEMANAL':
        return 'Semanal';
      case 'MENSAL':
        return 'Mensal';
      default:
        return period;
    }
  }

  static InputDecoration _modalInputDecoration({required String hintText}) {
    return InputDecoration(
      hintText: hintText,
      hintStyle: const TextStyle(color: _white45, fontSize: 14),
      filled: true,
      fillColor: _backgroundColor,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: _primaryColor, width: 1.2),
      ),
    );
  }
}

// =============================================================================
// CARD DE META
// =============================================================================

class _GoalCard extends StatelessWidget {
  final dynamic goal;
  final double progress;
  final bool isCompleted;
  final VoidCallback? onDecrease;
  final VoidCallback? onIncrease;
  final VoidCallback onDelete;

  const _GoalCard({
    required this.goal,
    required this.progress,
    required this.isCompleted,
    required this.onDecrease,
    required this.onIncrease,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final percentage = (progress * 100).round();

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: _GoalsScreenState._cardColor,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: isCompleted
              ? _GoalsScreenState._successColor.withValues(alpha: 0.20)
              : Colors.white.withValues(alpha: 0.045),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(17, 17, 14, 14),
        child: Column(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: isCompleted
                        ? _GoalsScreenState._successColor.withValues(
                            alpha: 0.12,
                          )
                        : _GoalsScreenState._primaryColor.withValues(
                            alpha: 0.11,
                          ),
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: Icon(
                    Icons.flag_outlined,
                    color: isCompleted
                        ? _GoalsScreenState._successColor
                        : _GoalsScreenState._primaryColor,
                    size: 21,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        goal.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          height: 1.25,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        isCompleted
                            ? 'Alvo do ciclo atingido'
                            : '$percentage% do alvo',
                        style: TextStyle(
                          color: isCompleted
                              ? _GoalsScreenState._successColor
                              : _GoalsScreenState._white45,
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: _GoalsScreenState._backgroundColor,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${goal.currentValue} / ${goal.targetValue}',
                    style: TextStyle(
                      color: isCompleted
                          ? _GoalsScreenState._successColor
                          : _GoalsScreenState._primaryColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 17),
            ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: progress),
                duration: const Duration(milliseconds: 600),
                curve: Curves.easeOutCubic,
                builder: (context, value, _) => LinearProgressIndicator(
                  value: value,
                  minHeight: 8,
                  backgroundColor: Colors.white.withValues(alpha: 0.06),
                  valueColor: AlwaysStoppedAnimation<Color>(
                    isCompleted
                        ? _GoalsScreenState._successColor
                        : _GoalsScreenState._primaryColor,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _ProgressButton(
                  icon: Icons.remove_rounded,
                  onPressed: onDecrease,
                  enabled: onDecrease != null,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Ajustar progresso',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: _GoalsScreenState._white45,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _ProgressButton(
                  icon: Icons.add_rounded,
                  primary: true,
                  onPressed: onIncrease,
                  enabled: onIncrease != null,
                ),
                const SizedBox(width: 4),
                IconButton(
                  tooltip: 'Excluir meta',
                  visualDensity: VisualDensity.compact,
                  onPressed: onDelete,
                  icon: const Icon(
                    Icons.delete_outline_rounded,
                    color: _GoalsScreenState._dangerColor,
                    size: 20,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// RESUMO DO CICLO
// =============================================================================

class _CycleSummary extends StatelessWidget {
  final String period;
  final int total;
  final int reached;

  const _CycleSummary({
    required this.period,
    required this.total,
    required this.reached,
  });

  @override
  Widget build(BuildContext context) {
    final cycleLabel = switch (period) {
      'DIÁRIA' => 'CICLO DIÁRIO',
      'SEMANAL' => 'CICLO SEMANAL',
      'MENSAL' => 'CICLO MENSAL',
      _ => 'CICLO',
    };
    final targetLabel = total == 1 ? 'alvo atingido' : 'alvos atingidos';

    return Container(
      margin: const EdgeInsets.only(bottom: 18),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: _GoalsScreenState._cardColor,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: _GoalsScreenState._primaryColor.withValues(alpha: 0.16),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: _GoalsScreenState._primaryColor.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(
              Icons.track_changes_rounded,
              color: _GoalsScreenState._primaryColor,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  cycleLabel,
                  style: const TextStyle(
                    color: _GoalsScreenState._white45,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '$reached de $total $targetLabel',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// BOTÃO DE PROGRESSO
// =============================================================================

class _ProgressButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onPressed;
  final bool enabled;
  final bool primary;

  const _ProgressButton({
    required this.icon,
    required this.onPressed,
    required this.enabled,
    this.primary = false,
  });

  @override
  Widget build(BuildContext context) {
    final background = primary
        ? _GoalsScreenState._primaryColor
        : _GoalsScreenState._backgroundColor;

    final foreground = primary
        ? Colors.white
        : enabled
        ? _GoalsScreenState._white60
        : _GoalsScreenState._white38;

    return Material(
      color: background,
      borderRadius: BorderRadius.circular(11),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(11),
        child: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(11),
            border: Border.all(
              color: primary
                  ? Colors.transparent
                  : Colors.white.withValues(alpha: 0.05),
            ),
          ),
          child: Icon(icon, color: foreground, size: 20),
        ),
      ),
    );
  }
}

// =============================================================================
// ESTADO VAZIO
// =============================================================================

class _EmptyGoalsState extends StatelessWidget {
  final String timeframe;
  final VoidCallback onAdd;

  const _EmptyGoalsState({required this.timeframe, required this.onAdd});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                color: _GoalsScreenState._primaryColor.withValues(alpha: 0.10),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.flag_outlined,
                color: _GoalsScreenState._primaryColor,
                size: 34,
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'Nenhuma meta neste ciclo',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Crie uma meta ${_GoalsScreenState._formatPeriod(timeframe).toLowerCase()} com um alvo mensurável para acompanhar.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: _GoalsScreenState._white45,
                fontSize: 13,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 22),
            ElevatedButton(
              onPressed: onAdd,
              style: ElevatedButton.styleFrom(
                backgroundColor: _GoalsScreenState._primaryColor,
                foregroundColor: Colors.white,
                elevation: 0,
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 13,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(13),
                ),
              ),
              child: const Text(
                'Criar primeira meta',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// ESTADO DE ERRO
// =============================================================================

class _ErrorState extends StatelessWidget {
  final VoidCallback onRetry;

  const _ErrorState({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.error_outline_rounded,
              color: _GoalsScreenState._dangerColor,
              size: 42,
            ),
            const SizedBox(height: 14),
            const Text(
              'Não foi possível carregar suas metas.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Tente novamente em instantes.',
              textAlign: TextAlign.center,
              style: TextStyle(color: _GoalsScreenState._white45, fontSize: 12),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: onRetry,
              child: const Text('Tentar novamente'),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// LABEL DO MODAL
// =============================================================================

class _ModalLabel extends StatelessWidget {
  final IconData icon;
  final String label;

  const _ModalLabel({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: _GoalsScreenState._primaryColor, size: 16),
        const SizedBox(width: 7),
        Text(
          label,
          style: const TextStyle(
            color: _GoalsScreenState._white60,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// ÍCONE DO MODAL
// =============================================================================

class _ModalIcon extends StatelessWidget {
  const _ModalIcon();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: _GoalsScreenState._primaryColor.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(15),
      ),
      child: const Icon(
        Icons.flag_rounded,
        color: _GoalsScreenState._primaryColor,
        size: 23,
      ),
    );
  }
}
