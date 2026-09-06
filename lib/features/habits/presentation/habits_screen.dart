import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:life_os/core/services/sync_manager_provider.dart';
import 'package:life_os/core/utils/app_logger.dart';
import 'package:life_os/features/habits/presentation/providers/habits_provider.dart';
import 'package:life_os/features/premium/domain/services/plan_limits.dart';
import 'package:life_os/features/premium/domain/services/quota_service.dart';
import 'package:life_os/features/premium/presentation/plan_limits_provider.dart';

const _backgroundColor = Color(0xFF070B14);
const _cardColor = Color(0xFF11182E);
const _cardSecondaryColor = Color(0xFF0D1326);
const _primaryColor = Color(0xFFB026FF);
const _successColor = Color(0xFF45E6A3);
const _dangerColor = Color(0xFFFF5C70);

class HabitsScreen extends ConsumerStatefulWidget {
  const HabitsScreen({super.key});

  @override
  ConsumerState<HabitsScreen> createState() => _HabitsScreenState();
}

class _HabitsScreenState extends ConsumerState<HabitsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_syncPendingThenHydrateHabits());
    });
  }

  Future<void> _syncPendingThenHydrateHabits() async {
    try {
      final queueDrained = await ref
          .read(syncManagerProvider)
          .processPendingItems();
      if (!mounted || !queueDrained) return;
      await ref.read(habitsRepositoryProvider).syncHabitsFromFirebaseToLocal();
    } catch (_) {
      AppLogger.w('Não foi possível sincronizar hábitos neste momento.');
    }
  }

  void _schedulePendingHabitSync() {
    if (!mounted) return;
    unawaited(
      ref.read(syncManagerProvider).processPendingItems().catchError((
        Object _,
      ) {
        AppLogger.w('Não foi possível sincronizar hábitos neste momento.');
        return false;
      }),
    );
  }

  void _showAddHabitDialog(BuildContext context, WidgetRef ref) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => _AddHabitSheet(
        onCreate: (title) async {
          final habitsAsync = ref.read(habitsStreamProvider);

          if (!habitsAsync.hasValue) {
            if (sheetContext.mounted) {
              ScaffoldMessenger.of(sheetContext).showSnackBar(
                const SnackBar(
                  content: Text(
                    'Não foi possível verificar seus hábitos agora. Tente novamente.',
                  ),
                ),
              );
            }
            return;
          }

          final habits = habitsAsync.requireValue;
          final limits = ref.read(planLimitsProvider);
          const quotaService = QuotaService();
          final canCreate = quotaService.canCreate(
            limit: limits.limitFor(QuotaResource.habits),
            currentCount: habits.length,
          );

          if (!canCreate) {
            final limit = limits.limitFor(QuotaResource.habits);
            final message = switch (limit.mode) {
              QuotaMode.disabled =>
                'Este recurso não está disponível no seu plano.',
              QuotaMode.limited =>
                'Você atingiu o limite de ${limit.maximum} hábitos do seu plano.',
              QuotaMode.unlimited => 'Você não possui limite de hábitos.',
              QuotaMode.notConfigured =>
                'O limite deste recurso ainda não está configurado.',
            };

            if (sheetContext.mounted) {
              ScaffoldMessenger.of(
                sheetContext,
              ).showSnackBar(SnackBar(content: Text(message)));
            }
            return;
          }

          await ref.read(habitsRepositoryProvider).addHabit(title);
          _schedulePendingHabitSync();

          if (sheetContext.mounted) {
            Navigator.pop(sheetContext);
          }
        },
      ),
    );
  }

  void _showDeleteConfirmationDialog(
    BuildContext context,
    WidgetRef ref,
    String habitId,
    String habitTitle,
  ) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: _cardColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const Row(
          children: [
            Icon(Icons.delete_outline_rounded, color: _dangerColor),
            SizedBox(width: 10),
            Text(
              'Excluir hábito',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        content: Text(
          "Deseja realmente excluir o hábito \"$habitTitle\"? Todo o histórico de progresso será perdido.",
          style: const TextStyle(color: Colors.white70, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              "Cancelar",
              style: TextStyle(color: Colors.white54),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: _dangerColor,
              foregroundColor: Colors.white,
              elevation: 0,
            ),
            onPressed: () async {
              await ref
                  .read(habitsRepositoryProvider)
                  .deleteHabit(habitId, habitTitle);
              _schedulePendingHabitSync();
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('Excluir'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final habitsAsync = ref.watch(habitsStreamProvider);
    final todayStr = DateFormat('yyyy-MM-dd').format(DateTime.now());

    // Algoritmo para descobrir as datas da semana atual (Segunda a Domingo)
    final now = DateTime.now();
    final monday = now.subtract(Duration(days: now.weekday - 1));
    final weekDays = List.generate(
      7,
      (index) => monday.add(Duration(days: index)),
    );

    return Scaffold(
      backgroundColor: _backgroundColor,
      floatingActionButton: FloatingActionButton(
        backgroundColor: _primaryColor,
        foregroundColor: Colors.white,
        elevation: 8,
        onPressed: () => _showAddHabitDialog(context, ref),
        child: const Icon(Icons.add_rounded, size: 28),
      ),
      body: SafeArea(
        child: habitsAsync.when(
          loading: () => const Center(
            child: CircularProgressIndicator(color: _primaryColor),
          ),
          error: (_, _) => const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.error_outline_rounded,
                    color: _dangerColor,
                    size: 42,
                  ),
                  SizedBox(height: 14),
                  Text(
                    'Não foi possível carregar seus hábitos.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  SizedBox(height: 6),
                  Text(
                    'Tente novamente em instantes.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
          data: (habits) {
            // 🚀 Cálculo do Progresso de Hoje para o Banner Superior
            final totalHabits = habits.length;
            final completedTodayCount = habits
                .where((h) => h.completedDates.contains(todayStr))
                .length;
            final progressPercent = totalHabits > 0
                ? completedTodayCount / totalHabits
                : 0.0;

            return Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Hábitos',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 29,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Construa consistência um dia de cada vez.',
                    style: TextStyle(color: Colors.white54, fontSize: 13),
                  ),
                  const SizedBox(height: 20),

                  if (totalHabits > 0)
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: _cardColor,
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(
                          color: _primaryColor.withValues(alpha: 0.16),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: _primaryColor.withValues(alpha: 0.05),
                            blurRadius: 22,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'HOJE',
                                  style: TextStyle(
                                    color: Colors.white54,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 1,
                                  ),
                                ),
                                const SizedBox(height: 5),
                                Text(
                                  '$completedTodayCount de $totalHabits ${totalHabits == 1 ? 'hábito concluído' : 'hábitos concluídos'}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 17,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          TweenAnimationBuilder<double>(
                            tween: Tween(begin: 0, end: progressPercent),
                            duration: const Duration(milliseconds: 600),
                            curve: Curves.easeOutCubic,
                            builder: (context, value, _) => SizedBox(
                              width: 52,
                              height: 52,
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  CircularProgressIndicator(
                                    value: value,
                                    backgroundColor: Colors.white10,
                                    color: _primaryColor,
                                    strokeWidth: 5,
                                  ),
                                  Text(
                                    '${(progressPercent * 100).toInt()}%',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
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

                  const SizedBox(height: 20),

                  Expanded(
                    child: totalHabits == 0
                        ? Center(
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.all(24),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    width: 76,
                                    height: 76,
                                    decoration: BoxDecoration(
                                      color: _primaryColor.withValues(
                                        alpha: 0.10,
                                      ),
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(
                                      Icons.repeat_rounded,
                                      color: _primaryColor,
                                      size: 34,
                                    ),
                                  ),
                                  const SizedBox(height: 20),
                                  const Text(
                                    'Nenhum hábito ativo',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 18,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  const Text(
                                    'Crie um hábito simples e acompanhe sua consistência diária.',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: Colors.white54,
                                      fontSize: 13,
                                      height: 1.4,
                                    ),
                                  ),
                                  const SizedBox(height: 22),
                                  ElevatedButton(
                                    onPressed: () =>
                                        _showAddHabitDialog(context, ref),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: _primaryColor,
                                      foregroundColor: Colors.white,
                                      elevation: 0,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 20,
                                        vertical: 13,
                                      ),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(14),
                                      ),
                                    ),
                                    child: const Text(
                                      'Criar primeiro hábito',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          )
                        : ListView.builder(
                            itemCount: habits.length,
                            itemBuilder: (context, index) {
                              final habit = habits[index];
                              bool isDoneToday = habit.completedDates.contains(
                                todayStr,
                              );

                              return Container(
                                margin: const EdgeInsets.only(bottom: 16),
                                padding: const EdgeInsets.all(16),
                                decoration: BoxDecoration(
                                  color: _cardColor,
                                  borderRadius: BorderRadius.circular(22),
                                  border: Border.all(
                                    color: isDoneToday
                                        ? _successColor.withValues(alpha: 0.20)
                                        : Colors.white.withValues(alpha: 0.05),
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(
                                        alpha: 0.16,
                                      ),
                                      blurRadius: 16,
                                      offset: const Offset(0, 8),
                                    ),
                                  ],
                                ),
                                child: Column(
                                  children: [
                                    Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                habit.title,
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 17,
                                                  fontWeight: FontWeight.w700,
                                                  height: 1.25,
                                                ),
                                              ),
                                              const SizedBox(height: 8),
                                              Row(
                                                children: [
                                                  Container(
                                                    padding:
                                                        const EdgeInsets.symmetric(
                                                          horizontal: 8,
                                                          vertical: 4,
                                                        ),
                                                    decoration: BoxDecoration(
                                                      color: isDoneToday
                                                          ? _successColor
                                                                .withValues(
                                                                  alpha: 0.12,
                                                                )
                                                          : _cardSecondaryColor,
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            20,
                                                          ),
                                                    ),
                                                    child: Text(
                                                      isDoneToday
                                                          ? 'Feito hoje'
                                                          : 'Pendente hoje',
                                                      style: TextStyle(
                                                        color: isDoneToday
                                                            ? _successColor
                                                            : Colors.white54,
                                                        fontSize: 10,
                                                        fontWeight:
                                                            FontWeight.w700,
                                                      ),
                                                    ),
                                                  ),
                                                  const SizedBox(width: 8),
                                                  const Icon(
                                                    Icons
                                                        .calendar_month_outlined,
                                                    color: Colors.white38,
                                                    size: 14,
                                                  ),
                                                  const SizedBox(width: 4),
                                                  Text(
                                                    '${habit.completedDates.length} ${habit.completedDates.length == 1 ? 'dia registrado' : 'dias registrados'}',
                                                    style: const TextStyle(
                                                      color: Colors.white38,
                                                      fontSize: 11,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ],
                                          ),
                                        ),
                                        Row(
                                          children: [
                                            Material(
                                              color: isDoneToday
                                                  ? _primaryColor.withValues(
                                                      alpha: 0.16,
                                                    )
                                                  : _primaryColor.withValues(
                                                      alpha: 0.08,
                                                    ),
                                              borderRadius:
                                                  BorderRadius.circular(13),
                                              child: InkWell(
                                                borderRadius:
                                                    BorderRadius.circular(13),
                                                onTap: () async {
                                                  await ref.read(
                                                    manualHabitTodayToggleProvider,
                                                  )(
                                                    habit.id,
                                                    habit.completedDates,
                                                    isDoneToday,
                                                  );
                                                  _schedulePendingHabitSync();
                                                },
                                                child: SizedBox(
                                                  width: 38,
                                                  height: 38,
                                                  child: Icon(
                                                    isDoneToday
                                                        ? Icons.check_rounded
                                                        : Icons.add_rounded,
                                                    color: _primaryColor,
                                                    size: 20,
                                                  ),
                                                ),
                                              ),
                                            ),
                                            IconButton(
                                              tooltip: 'Excluir hábito',
                                              icon: const Icon(
                                                Icons.delete_outline_rounded,
                                                color: _dangerColor,
                                                size: 20,
                                              ),
                                              onPressed: () =>
                                                  _showDeleteConfirmationDialog(
                                                    context,
                                                    ref,
                                                    habit.id,
                                                    habit.title,
                                                  ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                    const Divider(
                                      color: Colors.white10,
                                      height: 24,
                                    ),

                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      children: weekDays.map((day) {
                                        final dayStr = DateFormat(
                                          'yyyy-MM-dd',
                                        ).format(day);
                                        final isCompleted = habit.completedDates
                                            .contains(dayStr);
                                        final isDayToday = dayStr == todayStr;
                                        final dayLetter =
                                            DateFormat('E', 'pt_BR')
                                                .format(day)
                                                .substring(0, 1)
                                                .toUpperCase();

                                        return GestureDetector(
                                          onTap: () async {
                                            final updatedDates =
                                                List<String>.from(
                                                  habit.completedDates,
                                                );
                                            if (isCompleted) {
                                              updatedDates.remove(dayStr);
                                            } else {
                                              updatedDates.add(dayStr);
                                            }
                                            await ref
                                                .read(habitsRepositoryProvider)
                                                .updateHabitDates(
                                                  habit.id,
                                                  updatedDates,
                                                );
                                            _schedulePendingHabitSync();
                                          },
                                          child: Column(
                                            children: [
                                              Text(
                                                dayLetter,
                                                style: TextStyle(
                                                  color: isDayToday
                                                      ? _primaryColor
                                                      : Colors.white38,
                                                  fontSize: 11,
                                                  fontWeight: isDayToday
                                                      ? FontWeight.w700
                                                      : FontWeight.w500,
                                                ),
                                              ),
                                              const SizedBox(height: 6),
                                              AnimatedContainer(
                                                duration: const Duration(
                                                  milliseconds: 200,
                                                ),
                                                width: 28,
                                                height: 28,
                                                decoration: BoxDecoration(
                                                  color: isCompleted
                                                      ? _primaryColor
                                                      : _backgroundColor,
                                                  borderRadius:
                                                      BorderRadius.circular(8),
                                                  border: Border.all(
                                                    color: isDayToday
                                                        ? _primaryColor
                                                        : Colors.white
                                                              .withValues(
                                                                alpha: 0.08,
                                                              ),
                                                    width: isDayToday ? 1.5 : 1,
                                                  ),
                                                ),
                                                child: isCompleted
                                                    ? const Icon(
                                                        Icons.check_rounded,
                                                        color: Colors.white,
                                                        size: 16,
                                                      )
                                                    : null,
                                              ),
                                            ],
                                          ),
                                        );
                                      }).toList(),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _AddHabitSheet extends StatefulWidget {
  final Future<void> Function(String title) onCreate;

  const _AddHabitSheet({required this.onCreate});

  @override
  State<_AddHabitSheet> createState() => _AddHabitSheetState();
}

class _AddHabitSheetState extends State<_AddHabitSheet> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF0A0F1E),
        borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 12,
            bottom: MediaQuery.of(context).viewInsets.bottom + 20,
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
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: _primaryColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(15),
                      ),
                      child: const Icon(
                        Icons.repeat_rounded,
                        color: _primaryColor,
                      ),
                    ),
                    const SizedBox(width: 14),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Novo hábito',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 21,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          SizedBox(height: 3),
                          Text(
                            'Escolha um ritual simples para repetir.',
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                const Text(
                  'Nome do hábito',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _controller,
                  autofocus: true,
                  textInputAction: TextInputAction.done,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'Ex.: Meditar 10 minutos',
                    hintStyle: const TextStyle(color: Colors.white38),
                    filled: true,
                    fillColor: _backgroundColor,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(
                        color: Colors.white.withValues(alpha: 0.06),
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: const BorderSide(color: _primaryColor),
                    ),
                  ),
                  onSubmitted: (_) => _submit(),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: ElevatedButton(
                    onPressed: _submit,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _primaryColor,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    child: const Text(
                      'Criar hábito',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _submit() async {
    final title = _controller.text.trim();
    if (title.isEmpty) return;
    await widget.onCreate(title);
  }
}
