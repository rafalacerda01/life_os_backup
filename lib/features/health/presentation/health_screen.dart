import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:life_os/features/premium/domain/services/plan_limits.dart';
import 'package:life_os/features/premium/domain/services/quota_service.dart';
import 'package:life_os/features/premium/presentation/plan_limits_provider.dart';
import 'package:life_os/core/security/input_sanitizer.dart';
import 'package:life_os/core/utils/app_logger.dart';
import 'package:life_os/features/checkin/presentation/checkin_screen.dart';
import 'package:life_os/features/health/data/models/health_model.dart';
import 'package:life_os/features/health/data/repositories/health_repository.dart';
import 'package:life_os/features/health/presentation/cycle/cycle_daily_pill_control.dart';
import 'package:life_os/features/health/presentation/cycle/cycle_reminder_preferences.dart';
import 'package:life_os/features/health/presentation/providers/health_provider.dart';

typedef MedicationAdder =
    Future<void> Function(String name, DateTime startDate, int? durationDays);
typedef MedicationTimePicker =
    Future<TimeOfDay?> Function(BuildContext context);

DateTime combineMedicationDateAndTime(DateTime date, TimeOfDay time) {
  return DateTime(date.year, date.month, date.day, time.hour, time.minute);
}

class HealthScreen extends ConsumerWidget {
  const HealthScreen({
    super.key,
    this.medicationAdder,
    this.medicationTimePicker,
    this.clock,
  });

  final MedicationAdder? medicationAdder;
  final MedicationTimePicker? medicationTimePicker;
  final DateTime Function()? clock;

  static const Color _background = Color(0xFF070B14);
  static const Color _surface = Color(0xFF11182E);
  static const Color _green = Colors.greenAccent;
  static const Color _blue = Colors.blueAccent;
  static const Color _purple = Colors.purpleAccent;

  void _showSnackBar(
    BuildContext context,
    String message, {
    bool error = false,
  }) {
    if (!context.mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: error ? Colors.redAccent : _surface,
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.all(16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      );
  }

  Future<void> _updateMood(
    BuildContext context,
    WidgetRef ref,
    String mood,
  ) async {
    try {
      await ref.read(healthRepositoryProvider).updateMood(mood);
    } catch (e, stack) {
      AppLogger.e('Erro ao atualizar humor', e, stack);

      _showSnackBar(
        context,
        'Não foi possível registrar seu humor.',
        error: true,
      );
    }
  }

  Future<void> _addWater(
    BuildContext context,
    WidgetRef ref,
    int currentAmount,
  ) async {
    try {
      await ref.read(healthRepositoryProvider).addWater(currentAmount);
    } catch (e, stack) {
      AppLogger.e('Erro ao registrar hidratação', e, stack);

      _showSnackBar(
        context,
        'Não foi possível registrar a hidratação.',
        error: true,
      );
    }
  }

  void _showAddMedicationModal(BuildContext parentContext, WidgetRef ref) {
    final nameController = TextEditingController();
    final durationController = TextEditingController();

    DateTime startDate = (clock ?? DateTime.now)();
    TimeOfDay? reminderTime;

    showDialog<void>(
      context: parentContext,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (modalContext, setModalState) {
            return AlertDialog(
              backgroundColor: _surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
              title: const Row(
                children: [
                  Icon(Icons.medication_rounded, color: _green),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Adicionar medicamento',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _DialogField(
                      controller: nameController,
                      label: 'Nome',
                      hint: 'Ex.: Vitamina D',
                    ),
                    const SizedBox(height: 14),
                    _DialogField(
                      controller: durationController,
                      label: 'Duração',
                      hint: 'Opcional',
                      keyboardType: TextInputType.number,
                    ),
                    const SizedBox(height: 18),
                    const Text(
                      'Data de início',
                      style: TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                    const SizedBox(height: 8),
                    InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () async {
                        FocusManager.instance.primaryFocus?.unfocus();

                        final picked = await showDatePicker(
                          context: parentContext,
                          initialDate: startDate,
                          firstDate: DateTime(2025),
                          lastDate: DateTime(2035),
                        );

                        if (picked != null) {
                          setModalState(() {
                            startDate = picked;
                          });
                        }
                      },
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                        decoration: BoxDecoration(
                          color: _background,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: Colors.white10),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.calendar_today_rounded,
                              color: _green,
                              size: 18,
                            ),
                            const SizedBox(width: 10),
                            Text(
                              DateFormat('dd/MM/yyyy').format(startDate),
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const Spacer(),
                            const Icon(
                              Icons.chevron_right_rounded,
                              color: Colors.white38,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    const Text(
                      'Horário do lembrete',
                      style: TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                    const SizedBox(height: 8),
                    InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () async {
                        FocusManager.instance.primaryFocus?.unfocus();

                        final picker = medicationTimePicker;
                        final picked = picker == null
                            ? await showTimePicker(
                                context: parentContext,
                                initialTime: reminderTime ?? TimeOfDay.now(),
                                builder: (pickerContext, child) {
                                  final mediaQuery = MediaQuery.of(
                                    pickerContext,
                                  );
                                  // The text parser checks MediaQuery, not just locale.
                                  return MediaQuery(
                                    data: mediaQuery.copyWith(
                                      alwaysUse24HourFormat: true,
                                    ),
                                    child: child!,
                                  );
                                },
                              )
                            : await picker(parentContext);

                        if (picked != null) {
                          setModalState(() {
                            reminderTime = picked;
                          });
                        }
                      },
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                        decoration: BoxDecoration(
                          color: _background,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: Colors.white10),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.schedule_rounded,
                              color: _green,
                              size: 18,
                            ),
                            const SizedBox(width: 10),
                            Text(
                              reminderTime?.format(modalContext) ??
                                  'Selecionar horário',
                              style: TextStyle(
                                color: reminderTime == null
                                    ? Colors.white54
                                    : Colors.white,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const Spacer(),
                            const Icon(
                              Icons.chevron_right_rounded,
                              color: Colors.white38,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
              actions: [
                TextButton(
                  onPressed: () {
                    FocusManager.instance.primaryFocus?.unfocus();
                    Navigator.pop(dialogContext);
                  },
                  child: const Text(
                    'Cancelar',
                    style: TextStyle(color: Colors.white54),
                  ),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _green,
                    foregroundColor: Colors.black,
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
                    FocusManager.instance.primaryFocus?.unfocus();

                    final cleanName = InputSanitizer.sanitize(
                      nameController.text.trim(),
                    );

                    if (cleanName.isEmpty) {
                      _showSnackBar(
                        parentContext,
                        'Informe o nome do medicamento.',
                        error: true,
                      );
                      return;
                    }

                    final durationText = durationController.text.trim();

                    final duration = durationText.isEmpty
                        ? null
                        : int.tryParse(durationText);

                    if (durationText.isNotEmpty &&
                        (duration == null || duration <= 0)) {
                      _showSnackBar(
                        parentContext,
                        'Informe uma duração válida.',
                        error: true,
                      );
                      return;
                    }

                    final selectedTime = reminderTime;
                    if (selectedTime == null) {
                      _showSnackBar(
                        parentContext,
                        'Selecione o horário do lembrete.',
                        error: true,
                      );
                      return;
                    }

                    final scheduledStart = combineMedicationDateAndTime(
                      startDate,
                      selectedTime,
                    );

                    final medicationsAsync = ref.read(
                      medicationsStreamProvider,
                    );

                    if (!medicationsAsync.hasValue) {
                      _showSnackBar(
                        parentContext,
                        'Não foi possível verificar seus medicamentos agora. Tente novamente.',
                        error: true,
                      );
                      return;
                    }

                    final medications = medicationsAsync.requireValue;

                    final limits = ref.read(planLimitsProvider);
                    const quotaService = QuotaService();

                    final medicationLimit = limits.limitFor(
                      QuotaResource.medications,
                    );

                    final canCreate = quotaService.canCreate(
                      limit: medicationLimit,
                      currentCount: medications.length,
                    );

                    if (!canCreate) {
                      final message = switch (medicationLimit.mode) {
                        QuotaMode.disabled =>
                          'Este recurso não está disponível no seu plano.',
                        QuotaMode.limited =>
                          'Você atingiu o limite de ${medicationLimit.maximum} medicamentos do seu plano.',
                        QuotaMode.unlimited =>
                          'Você não possui limite de medicamentos.',
                        QuotaMode.notConfigured =>
                          'O limite deste recurso ainda não está configurado.',
                      };

                      _showSnackBar(parentContext, message, error: true);

                      return;
                    }

                    final navigator = Navigator.of(dialogContext);

                    try {
                      final addMedication = medicationAdder;
                      if (addMedication == null) {
                        await ref
                            .read(healthRepositoryProvider)
                            .addMedication(cleanName, scheduledStart, duration);
                      } else {
                        await addMedication(
                          cleanName,
                          scheduledStart,
                          duration,
                        );
                      }

                      if (dialogContext.mounted) {
                        navigator.pop();
                      }

                      if (parentContext.mounted) {
                        _showSnackBar(parentContext, 'Medicamento adicionado.');
                      }
                    } catch (e, stack) {
                      AppLogger.e('Erro ao adicionar medicamento', e, stack);

                      if (parentContext.mounted) {
                        _showSnackBar(
                          parentContext,
                          'Não foi possível salvar o medicamento.',
                          error: true,
                        );
                      }
                    }
                  },
                  child: const Text(
                    'Salvar',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            );
          },
        );
      },
    ).whenComplete(() {
      nameController.dispose();
      durationController.dispose();
    });
  }

  void _showDeleteConfirmation(
    BuildContext parentContext,
    WidgetRef ref,
    String docId,
    int localId,
  ) {
    FocusManager.instance.primaryFocus?.unfocus();

    showDialog<void>(
      context: parentContext,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: _surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          title: const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: Colors.redAccent),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Excluir medicamento?',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          content: const Text(
            'O medicamento será removido da sua lista. '
            'Essa ação não poderá ser desfeita.',
            style: TextStyle(color: Colors.white70, height: 1.4),
          ),
          actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text(
                'Cancelar',
                style: TextStyle(color: Colors.white54),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent,
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed: () async {
                // 🛡️ CORREÇÃO CRÍTICA: Fechar o diálogo PRIMEIRO, de forma limpa,
                // ANTES de executar a exclusão assíncrona no banco/repositório.
                Navigator.pop(dialogContext);

                try {
                  await ref
                      .read(healthRepositoryProvider)
                      .deleteMedication(docId, localId);

                  if (parentContext.mounted) {
                    _showSnackBar(parentContext, 'Medicamento removido.');
                  }
                } catch (e, stack) {
                  AppLogger.e('Erro ao excluir medicamento', e, stack);

                  if (parentContext.mounted) {
                    _showSnackBar(
                      parentContext,
                      'Não foi possível excluir o medicamento.',
                      error: true,
                    );
                  }
                }
              },
              child: const Text(
                'Excluir',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final healthAsync = ref.watch(healthStreamProvider);

    const moods = [
      _MoodData(label: 'Radiante', emoji: '🤩'),
      _MoodData(label: 'Focado', emoji: '🧠'),
      _MoodData(label: 'Neutro', emoji: '😐'),
      _MoodData(label: 'Cansado', emoji: '😴'),
      _MoodData(label: 'Estressado', emoji: '🤯'),
    ];

    return Scaffold(
      backgroundColor: _background,
      body: SafeArea(
        child: healthAsync.when(
          loading: () => const _HealthLoading(),
          error: (error, stack) {
            AppLogger.e('Erro ao carregar dados de saúde', error, stack);

            return _HealthError(
              onRetry: () {
                ref.invalidate(healthStreamProvider);
              },
            );
          },
          data: (health) {
            final waterProgress = (health.waterIntakeMl / 3000)
                .clamp(0.0, 1.0)
                .toDouble();

            return RefreshIndicator(
              color: _green,
              backgroundColor: _surface,
              onRefresh: () async {
                ref.invalidate(healthStreamProvider);

                await Future<void>.delayed(const Duration(milliseconds: 250));
              },
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
                    sliver: SliverList(
                      delegate: SliverChildListDelegate([
                        _buildHeader(context),
                        const SizedBox(height: 22),

                        _buildDailySnapshot(health),

                        const SizedBox(height: 28),

                        _buildSectionLabel(
                          'COMO VOCÊ ESTÁ HOJE?',
                          'Seu estado mental',
                        ),

                        const SizedBox(height: 12),

                        _buildMoodSelector(context, ref, health, moods),

                        const SizedBox(height: 28),

                        _buildSectionLabel(
                          'HIDRATAÇÃO',
                          'Meta diária de 3 litros',
                        ),

                        const SizedBox(height: 12),

                        _buildHydrationCard(
                          context,
                          ref,
                          health,
                          waterProgress,
                        ),

                        const SizedBox(height: 28),

                        _buildSectionLabel(
                          'MEDICAMENTOS',
                          'Tratamentos ativos',
                          trailing: IconButton(
                            onPressed: () =>
                                _showAddMedicationModal(context, ref),
                            icon: const Icon(Icons.add_rounded),
                            color: _green,
                            tooltip: 'Adicionar medicamento',
                          ),
                        ),

                        const SizedBox(height: 12),

                        _buildMedicationsCard(context, ref),

                        const SizedBox(height: 28),

                        CycleHealthSummaryCard(
                          health: health,
                          onTap: () => context.push('/health/cycle'),
                        ),
                      ]),
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

  Widget _buildHeader(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'SAÚDE',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.5,
                ),
              ),
              SizedBox(height: 4),
              Text(
                'Seu bem-estar hoje',
                style: TextStyle(color: Colors.white54, fontSize: 14),
              ),
            ],
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: _surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white10),
          ),
          child: IconButton(
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const CheckInScreen()),
              );
            },
            icon: const Icon(Icons.insights_rounded, color: _green),
            tooltip: 'Check-in de estado',
          ),
        ),
      ],
    );
  }

  Widget _buildDailySnapshot(HealthModel health) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [_surface, _surface.withOpacity(0.78)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.today_rounded, color: _green, size: 18),
              SizedBox(width: 8),
              Text(
                'RESUMO DO DIA',
                style: TextStyle(
                  color: Colors.white54,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _SnapshotItem(
                  icon: Icons.psychology_rounded,
                  color: _purple,
                  label: 'Humor',
                  value: health.mood == '—' ? 'Não registrado' : health.mood,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _SnapshotItem(
                  icon: Icons.water_drop_rounded,
                  color: _blue,
                  label: 'Hidratação',
                  value: '${health.waterIntakeMl} ml',
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Expanded(
                child: _SnapshotItem(
                  icon: Icons.medication_rounded,
                  color: _green,
                  label: 'Cuidados',
                  value: 'Monitorados',
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: _SnapshotItem(
                  icon: Icons.auto_awesome_rounded,
                  color: _purple,
                  label: 'Sugestão',
                  value: 'Disponível',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSectionLabel(String title, String subtitle, {Widget? trailing}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                subtitle,
                style: const TextStyle(color: Colors.white38, fontSize: 11),
              ),
            ],
          ),
        ),
        ?trailing,
      ],
    );
  }

  Widget _buildMoodSelector(
    BuildContext context,
    WidgetRef ref,
    HealthModel health,
    List<_MoodData> moods,
  ) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 18, 10, 16),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: moods.map((mood) {
              final isSelected = health.mood == mood.label;

              return Expanded(
                child: GestureDetector(
                  onTap: () => _updateMood(context, ref, mood.label),
                  behavior: HitTestBehavior.opaque,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 220),
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? _green.withOpacity(0.10)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isSelected ? _green : Colors.transparent,
                        width: 1.4,
                      ),
                    ),
                    child: Column(
                      children: [
                        AnimatedScale(
                          scale: isSelected ? 1.08 : 1.0,
                          duration: const Duration(milliseconds: 220),
                          child: Text(
                            mood.emoji,
                            style: const TextStyle(fontSize: 26),
                          ),
                        ),
                        const SizedBox(height: 7),
                        Text(
                          mood.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: isSelected ? _green : Colors.white38,
                            fontSize: 9.5,
                            fontWeight: isSelected
                                ? FontWeight.w700
                                : FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          if (health.mood != '—') ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: _green.withOpacity(0.06),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.check_circle_rounded,
                    color: _green,
                    size: 15,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Estado registrado: ${health.mood}',
                    style: const TextStyle(
                      color: _green,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildHydrationCard(
    BuildContext context,
    WidgetRef ref,
    HealthModel health,
    double progress,
  ) {
    final remaining = (3000 - health.waterIntakeMl).clamp(0, 3000);

    final percentage = (progress * 100).round();

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: _blue.withOpacity(0.14)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: _blue.withOpacity(0.10),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.water_drop_rounded,
                  color: _blue,
                  size: 21,
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Hidratação diária',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SizedBox(height: 3),
                    Text(
                      'Meta de 3.000 ml',
                      style: TextStyle(color: Colors.white38, fontSize: 11),
                    ),
                  ],
                ),
              ),
              Text(
                '$percentage%',
                style: const TextStyle(
                  color: _blue,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 11,
              backgroundColor: _background,
              valueColor: const AlwaysStoppedAnimation<Color>(_blue),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${health.waterIntakeMl} ml consumidos',
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                remaining > 0 ? '$remaining ml restantes' : 'Meta atingida',
                style: TextStyle(
                  color: remaining > 0 ? Colors.white38 : _blue,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            height: 46,
            child: OutlinedButton.icon(
              onPressed: () => _addWater(context, ref, health.waterIntakeMl),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: _blue.withOpacity(0.45)),
                foregroundColor: _blue,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              icon: const Icon(Icons.add_rounded, size: 19),
              label: const Text(
                'Registrar +250 ml',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMedicationsCard(BuildContext context, WidgetRef ref) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white10),
      ),
      child: ref
          .watch(medicationsStreamProvider)
          .when(
            loading: () => const Padding(
              padding: EdgeInsets.all(20),
              child: Center(
                child: CircularProgressIndicator(color: _green, strokeWidth: 2),
              ),
            ),
            error: (error, stack) {
              AppLogger.e('Erro ao carregar medicamentos', error, stack);

              return const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Não foi possível carregar os medicamentos.',
                  style: TextStyle(color: Colors.redAccent, fontSize: 12),
                ),
              );
            },
            data: (medications) {
              if (medications.isEmpty) {
                return const _EmptyMedicationState();
              }

              return Column(
                children: [
                  for (var index = 0; index < medications.length; index++) ...[
                    _MedicationCard(
                      key: ValueKey(medications[index].id),
                      medication: medications[index],
                      onDelete: () {
                        final medication = medications[index];

                        _showDeleteConfirmation(
                          context,
                          ref,
                          medication.firestoreId ?? '',
                          medication.id,
                        );
                      },
                    ),
                    if (index < medications.length - 1)
                      const SizedBox(height: 10),
                  ],
                ],
              );
            },
          ),
    );
  }
}

class CycleHealthSummaryCard extends StatelessWidget {
  const CycleHealthSummaryCard({
    super.key,
    required this.health,
    required this.onTap,
  });

  final HealthModel health;
  final VoidCallback onTap;

  static const Color _surface = Color(0xFF11182E);
  static const Color _primary = Color(0xFFB026FF);

  @override
  Widget build(BuildContext context) {
    final cycleData = health.menstrualCycle;
    final isConfigured = cycleData != null;
    final isEnabled = cycleData?['isEnabled'] == true;

    String summary;
    if (!isConfigured) {
      summary = 'Configure para acompanhar estimativas e registros.';
    } else if (!isEnabled) {
      summary = 'Acompanhamento desativado. Configure quando desejar.';
    } else {
      final cycleInfo = health.cyclePhaseInfo;
      final day = (cycleInfo['day'] as num?)?.toInt() ?? 0;
      final totalDays = (cycleInfo['totalDays'] as num?)?.toInt() ?? 0;
      final phase = cycleInfo['name']?.toString() ?? 'Fase atual';
      summary = day > 0 && totalDays > 0
          ? 'Estimativa: dia $day de $totalDays · $phase'
          : 'Complete a configuração para gerar estimativas.';
    }

    return Semantics(
      button: true,
      label: 'Abrir Saúde do ciclo',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: const ValueKey('cycle-health-summary-card'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(22),
          child: Ink(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: _surface,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: _primary.withOpacity(0.18)),
            ),
            child: Row(
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFF5D0EFF), _primary],
                    ),
                    borderRadius: BorderRadius.circular(15),
                  ),
                  child: const Icon(
                    Icons.calendar_month_rounded,
                    color: Colors.white,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Saúde do ciclo',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        summary,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 12,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                const Icon(Icons.chevron_right_rounded, color: Colors.white54),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

enum CycleHealthDetailsPresentation { embedded, dedicated }

final cyclePillTrackingVisibleProvider = Provider<bool>((ref) {
  final preferences = ref.watch(cycleReminderPreferencesProvider);
  return preferences.asData?.value?.type == CycleReminderType.pill;
});

class CycleHealthDetails extends ConsumerWidget {
  final HealthModel health;
  final CycleHealthDetailsPresentation presentation;

  const CycleHealthDetails({
    super.key,
    required this.health,
    this.presentation = CycleHealthDetailsPresentation.embedded,
    this.showDailyPillControl = true,
  });

  final bool showDailyPillControl;

  static const Color _background = Color(0xFF070B14);
  static const Color _surface = Color(0xFF11182E);
  static const Color _pink = Color(0xFFB026FF);
  static const Color _purple = Colors.purpleAccent;
  static const Color _rose = Color(0xFFFF6B9F);
  static const Color _softRose = Color(0xFFFF9FBA);
  static const Color _lilac = Color(0xFFC58CFF);
  static const Color _softViolet = Color(0xFF9B72FF);
  static const Color _turquoise = Color(0xFF58D6C7);
  static const Color _warmPeach = Color(0xFFF2A56B);
  static const int _maximumCycleLengthDays = 120;

  void _showSnackBar(
    BuildContext context,
    String message, {
    bool error = false,
  }) {
    if (!context.mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: error ? Colors.redAccent : _surface,
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.all(16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      );
  }

  Future<bool> _toggleCycle(
    BuildContext context,
    WidgetRef ref,
    String? expectedUid,
    bool enabled,
  ) async {
    if (expectedUid == null) {
      _showSnackBar(
        context,
        enabled
            ? 'Não foi possível ativar o ciclo.'
            : 'Não foi possível desativar o ciclo.',
        error: true,
      );
      return false;
    }

    try {
      final updated = await ref
          .read(healthRepositoryProvider)
          .toggleMenstrualCycleFeature(enabled, expectedUid: expectedUid);
      if (!updated) {
        _showSnackBar(
          context,
          enabled
              ? 'Não foi possível ativar o ciclo.'
              : 'Não foi possível desativar o ciclo.',
          error: true,
        );
        return false;
      }
      return true;
    } catch (e, stack) {
      AppLogger.e(
        enabled
            ? 'Erro ao ativar ciclo menstrual'
            : 'Erro ao desativar ciclo menstrual',
        e,
        stack,
      );

      _showSnackBar(
        context,
        enabled
            ? 'Não foi possível ativar o ciclo.'
            : 'Não foi possível desativar o ciclo.',
        error: true,
      );
      return false;
    }
  }

  Widget _buildWeekTracker() {
    final now = DateTime.now();

    final monday = DateTime(
      now.year,
      now.month,
      now.day,
    ).subtract(Duration(days: now.weekday - 1));

    const dayNames = ['Seg', 'Ter', 'Qua', 'Qui', 'Sex', 'Sáb', 'Dom'];

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: List.generate(7, (index) {
          final date = monday.add(Duration(days: index));

          final isToday =
              date.year == now.year &&
              date.month == now.month &&
              date.day == now.day;

          return Padding(
            padding: EdgeInsets.only(right: index == 6 ? 0 : 10),
            child: Column(
              children: [
                Text(
                  dayNames[index],
                  style: TextStyle(
                    fontSize: 9,
                    color: isToday ? _pink : Colors.white38,
                    fontWeight: isToday ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
                const SizedBox(height: 7),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isToday
                        ? _pink.withOpacity(0.15)
                        : Colors.transparent,
                    border: Border.all(
                      color: isToday ? _pink : Colors.white10,
                      width: isToday ? 1.7 : 1,
                    ),
                  ),
                  child: Center(
                    child: Text(
                      '${date.day}',
                      style: TextStyle(
                        fontSize: 10,
                        color: isToday ? Colors.white : Colors.white38,
                        fontWeight: isToday
                            ? FontWeight.bold
                            : FontWeight.normal,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        }),
      ),
    );
  }

  Future<bool> _confirmCycleDeactivation(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (confirmationContext) => AlertDialog(
        backgroundColor: _surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const Text(
          'Desativar acompanhamento?',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
        ),
        content: const Text(
          'Suas configurações serão mantidas, mas as estimativas do ciclo '
          'deixarão de ser exibidas. Você pode ativar novamente quando quiser.',
          style: TextStyle(color: Colors.white70, height: 1.45),
        ),
        actions: [
          TextButton(
            key: const ValueKey('cycle-deactivate-cancel'),
            onPressed: () => Navigator.pop(confirmationContext, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            key: const ValueKey('cycle-deactivate-confirm'),
            onPressed: () => Navigator.pop(confirmationContext, true),
            style: FilledButton.styleFrom(
              backgroundColor: _rose,
              foregroundColor: Colors.black,
            ),
            child: const Text('Desativar'),
          ),
        ],
      ),
    );

    return confirmed == true;
  }

  void _showCycleSettings(
    BuildContext parentContext,
    WidgetRef ref,
    String? expectedUid,
    Map<String, dynamic>? currentData, {
    bool allowDeactivation = false,
  }) {
    final initialDateStr = currentData?['lastPeriodStart'];

    DateTime tempDate;

    try {
      tempDate = initialDateStr is String
          ? DateTime.parse(initialDateStr)
          : DateTime.now();
    } catch (e, stack) {
      AppLogger.e('Data de início do ciclo inválida', e, stack);

      tempDate = DateTime.now();
    }

    final cycleController = TextEditingController(
      text: (currentData?['cycleLengthDays'] ?? 28).toString(),
    );

    final periodController = TextEditingController(
      text: (currentData?['periodLengthDays'] ?? 5).toString(),
    );

    showDialog<void>(
      context: parentContext,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (modalContext, setDialogState) {
            return AlertDialog(
              backgroundColor: _surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
              title: const Row(
                children: [
                  Icon(Icons.calendar_month_rounded, color: _pink),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Configurar ciclo',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Início do último ciclo',
                      style: TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                    const SizedBox(height: 8),
                    InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () async {
                        FocusManager.instance.primaryFocus?.unfocus();

                        final picked = await showDatePicker(
                          context: parentContext,
                          initialDate: tempDate,
                          firstDate: DateTime(2025),
                          lastDate: DateTime.now(),
                        );

                        if (picked != null) {
                          setDialogState(() {
                            tempDate = picked;
                          });
                        }
                      },
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                        decoration: BoxDecoration(
                          color: _background,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: Colors.white10),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.calendar_today_rounded,
                              color: _pink,
                              size: 17,
                            ),
                            const SizedBox(width: 10),
                            Text(
                              DateFormat('dd/MM/yyyy').format(tempDate),
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const Spacer(),
                            const Icon(
                              Icons.chevron_right_rounded,
                              color: Colors.white38,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        Expanded(
                          child: _DialogField(
                            controller: cycleController,
                            label: 'Ciclo',
                            hint: '28 dias',
                            keyboardType: TextInputType.number,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _DialogField(
                            controller: periodController,
                            label: 'Período',
                            hint: '5 dias',
                            keyboardType: TextInputType.number,
                          ),
                        ),
                      ],
                    ),
                    if (allowDeactivation &&
                        currentData?['isEnabled'] == true) ...[
                      const SizedBox(height: 22),
                      const Divider(color: Colors.white10),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: TextButton.icon(
                          key: const ValueKey('cycle-deactivate-action'),
                          onPressed: () async {
                            FocusManager.instance.primaryFocus?.unfocus();
                            final confirmed = await _confirmCycleDeactivation(
                              parentContext,
                            );
                            if (!confirmed || !parentContext.mounted) return;

                            final deactivated = await _toggleCycle(
                              parentContext,
                              ref,
                              expectedUid,
                              false,
                            );
                            if (deactivated && dialogContext.mounted) {
                              Navigator.pop(dialogContext);
                            }
                          },
                          style: TextButton.styleFrom(
                            foregroundColor: _softRose,
                            alignment: Alignment.centerLeft,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 12,
                            ),
                          ),
                          icon: const Icon(
                            Icons.pause_circle_outline_rounded,
                            size: 19,
                          ),
                          label: const Text(
                            'Desativar acompanhamento do ciclo',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
              actions: [
                TextButton(
                  onPressed: () {
                    FocusManager.instance.primaryFocus?.unfocus();
                    Navigator.pop(dialogContext);
                  },
                  child: const Text(
                    'Cancelar',
                    style: TextStyle(color: Colors.white54),
                  ),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _pink,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: () async {
                    FocusManager.instance.primaryFocus?.unfocus();

                    if (expectedUid == null) {
                      _showSnackBar(
                        parentContext,
                        'Não foi possível salvar a configuração.',
                        error: true,
                      );
                      return;
                    }

                    final cycleLength = int.tryParse(
                      cycleController.text.trim(),
                    );
                    final periodLength = int.tryParse(
                      periodController.text.trim(),
                    );

                    if (cycleLength == null || cycleLength <= 0) {
                      _showSnackBar(
                        parentContext,
                        'Informe uma duração de ciclo válida.',
                        error: true,
                      );
                      return;
                    }

                    if (cycleLength > _maximumCycleLengthDays) {
                      _showSnackBar(
                        parentContext,
                        'O ciclo deve ter no máximo 120 dias.',
                        error: true,
                      );
                      return;
                    }

                    if (periodLength == null || periodLength <= 0) {
                      _showSnackBar(
                        parentContext,
                        'Informe uma duração de menstruação válida.',
                        error: true,
                      );
                      return;
                    }

                    if (periodLength > cycleLength) {
                      _showSnackBar(
                        parentContext,
                        'A menstruação não pode ser maior que o ciclo.',
                        error: true,
                      );
                      return;
                    }

                    final newCycleData = <String, dynamic>{
                      'isEnabled': true,
                      'lastPeriodStart': tempDate.toIso8601String(),
                      'cycleLengthDays': cycleLength,
                      'periodLengthDays': periodLength,
                    };

                    final navigator = Navigator.of(dialogContext);

                    try {
                      final updated = await ref
                          .read(healthRepositoryProvider)
                          .updateCycleSettings(
                            newCycleData,
                            expectedUid: expectedUid,
                          );

                      if (!updated) {
                        if (parentContext.mounted) {
                          _showSnackBar(
                            parentContext,
                            'Não foi possível salvar a configuração.',
                            error: true,
                          );
                        }
                        return;
                      }

                      if (dialogContext.mounted) {
                        navigator.pop();
                      }

                      if (parentContext.mounted) {
                        _showSnackBar(
                          parentContext,
                          'Configuração do ciclo atualizada.',
                        );
                      }
                    } catch (e, stack) {
                      AppLogger.e(
                        'Erro ao salvar configuração do ciclo',
                        e,
                        stack,
                      );

                      if (parentContext.mounted) {
                        _showSnackBar(
                          parentContext,
                          'Não foi possível salvar a configuração.',
                          error: true,
                        );
                      }
                    }
                  },
                  child: const Text(
                    'Salvar',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            );
          },
        );
      },
    ).whenComplete(() {
      cycleController.dispose();
      periodController.dispose();
    });
  }

  Color _phasePresentationColor(String phaseName) {
    final normalized = phaseName.toLowerCase();
    if (normalized.contains('menstrual')) return _rose;
    if (normalized.contains('folicular')) return _lilac;
    if (normalized.contains('ovula')) return _turquoise;
    if (normalized.contains('lútea') ||
        normalized.contains('lutea') ||
        normalized.contains('luteal')) {
      return _warmPeach;
    }
    return _softViolet;
  }

  Widget _buildDedicatedInactiveState(
    BuildContext context,
    WidgetRef ref,
    String? expectedUid,
    Map<String, dynamic>? cycleData,
    Map<String, dynamic> cycleInfo,
    bool isEnabled,
    bool showPillTracking,
  ) {
    final isPaused = cycleData != null && !isEnabled;
    final canReactivateDirectly =
        isPaused && HealthRepository.isCycleConfigurationValid(cycleData);
    final title = isPaused
        ? 'Acompanhamento pausado'
        : cycleInfo['name']?.toString() ?? 'Configure seu ciclo';
    final message = isPaused
        ? 'Seus dados continuam salvos. Ative quando quiser voltar a '
              'acompanhar suas estimativas.'
        : cycleData == null
        ? 'Configure para acompanhar estimativas e registros.'
        : cycleInfo['message']?.toString() ??
              'Complete a configuração para gerar estimativas.';

    return Container(
      key: ValueKey(isPaused ? 'cycle-paused-state' : 'cycle-setup-state'),
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            _surface,
            _softViolet.withOpacity(0.10),
            _rose.withOpacity(0.06),
          ],
        ),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: _softViolet.withOpacity(0.22)),
        boxShadow: [
          BoxShadow(
            color: _softViolet.withOpacity(0.08),
            blurRadius: 28,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: Column(
        children: [
          Container(
            width: 62,
            height: 62,
            decoration: BoxDecoration(
              color: _softViolet.withOpacity(0.12),
              shape: BoxShape.circle,
              border: Border.all(color: _softViolet.withOpacity(0.26)),
            ),
            child: Icon(
              isPaused ? Icons.pause_rounded : Icons.calendar_month_rounded,
              color: _lilac,
              size: 28,
            ),
          ),
          const SizedBox(height: 18),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white60,
              fontSize: 13,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 22),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: ValueKey(
                isPaused ? 'cycle-reactivate-action' : 'cycle-configure-action',
              ),
              onPressed: canReactivateDirectly
                  ? () => _toggleCycle(context, ref, expectedUid, true)
                  : () => _showCycleSettings(
                      context,
                      ref,
                      expectedUid,
                      cycleData,
                      allowDeactivation: isEnabled,
                    ),
              style: FilledButton.styleFrom(
                backgroundColor: _pink,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              icon: Icon(
                isPaused ? Icons.play_arrow_rounded : Icons.tune_rounded,
              ),
              label: Text(
                isPaused ? 'Ativar acompanhamento' : 'Configurar ciclo',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ),
          if (isPaused) ...[
            const SizedBox(height: 8),
            TextButton.icon(
              key: const ValueKey('cycle-configure-action'),
              onPressed: () =>
                  _showCycleSettings(context, ref, expectedUid, cycleData),
              icon: const Icon(Icons.settings_rounded, size: 18),
              label: const Text('Ajustar configuração'),
              style: TextButton.styleFrom(foregroundColor: Colors.white60),
            ),
          ],
          if (showPillTracking) ...[
            const SizedBox(height: 16),
            CycleDailyPillControl(health: health),
          ],
        ],
      ),
    );
  }

  Widget _buildDedicatedHero(
    BuildContext context,
    WidgetRef ref,
    String? expectedUid,
    Map<String, dynamic> cycleData,
    int currentDay,
    int totalDays,
    String phaseName,
    String insight,
    bool showPillTracking,
  ) {
    final phaseColor = _phasePresentationColor(phaseName);
    final progress = (currentDay / totalDays).clamp(0.0, 1.0);

    return Container(
      key: const ValueKey('cycle-hero-card'),
      width: double.infinity,
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            _surface,
            _rose.withOpacity(0.10),
            _softViolet.withOpacity(0.13),
          ],
          stops: const [0, 0.52, 1],
        ),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: phaseColor.withOpacity(0.28)),
        boxShadow: [
          BoxShadow(
            color: phaseColor.withOpacity(0.09),
            blurRadius: 34,
            offset: const Offset(0, 16),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: phaseColor.withOpacity(0.13),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.calendar_month_rounded,
                  color: phaseColor,
                  size: 19,
                ),
              ),
              const SizedBox(width: 11),
              const Expanded(
                child: Text(
                  'SEU CICLO HOJE',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.1,
                  ),
                ),
              ),
              IconButton(
                key: const ValueKey('cycle-configure-action'),
                onPressed: () => _showCycleSettings(
                  context,
                  ref,
                  expectedUid,
                  cycleData,
                  allowDeactivation: true,
                ),
                tooltip: 'Configurar ciclo',
                icon: const Icon(
                  Icons.settings_rounded,
                  color: Colors.white70,
                  size: 20,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Center(
            child: SizedBox(
              width: 142,
              height: 142,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox.expand(
                    child: CircularProgressIndicator(
                      value: progress,
                      strokeWidth: 9,
                      backgroundColor: Colors.white.withOpacity(0.07),
                      valueColor: AlwaysStoppedAnimation<Color>(phaseColor),
                      strokeCap: StrokeCap.round,
                    ),
                  ),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Dia $currentDay',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 25,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'de $totalDays',
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
              decoration: BoxDecoration(
                color: phaseColor.withOpacity(0.12),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: phaseColor.withOpacity(0.25)),
              ),
              child: Text(
                '$phaseName · estimativa',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: phaseColor,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
          const SizedBox(height: 22),
          _buildWeekTracker(),
          const SizedBox(height: 20),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (showPillTracking) CycleDailyPillControl(health: health),
            ],
          ),
          const SizedBox(height: 18),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: _background.withOpacity(0.72),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: _lilac.withOpacity(0.16)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.auto_awesome_rounded, color: _lilac, size: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'SUGESTÃO DO DIA',
                        style: TextStyle(
                          color: _lilac,
                          fontSize: 9,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.9,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        insight,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                          height: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cycleData = health.menstrualCycle;
    final isEnabled = cycleData != null && cycleData['isEnabled'] == true;
    final cycleInfo = health.cyclePhaseInfo;
    final currentDay = (cycleInfo['day'] as num?)?.toInt() ?? 0;
    final totalDays = (cycleInfo['totalDays'] as num?)?.toInt() ?? 0;
    final hasUsableEstimate = currentDay > 0 && totalDays > 0;
    final expectedUid = ref.read(cycleReminderUserIdReaderProvider)();
    final showPillTracking =
        showDailyPillControl && ref.watch(cyclePillTrackingVisibleProvider);

    if (!isEnabled || !hasUsableEstimate) {
      if (presentation == CycleHealthDetailsPresentation.dedicated) {
        return _buildDedicatedInactiveState(
          context,
          ref,
          expectedUid,
          cycleData,
          cycleInfo,
          isEnabled,
          showPillTracking,
        );
      }

      final statusName = isEnabled
          ? cycleInfo['name']?.toString() ?? 'Configuração incompleta'
          : 'Saúde do ciclo';
      final statusMessage = cycleData == null
          ? 'Configure para acompanhar estimativas e registros.'
          : !isEnabled
          ? 'Acompanhamento desativado. Configure quando desejar.'
          : cycleInfo['message']?.toString() ??
                'Complete a configuração para gerar estimativas.';

      return Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: _surface,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: _pink.withOpacity(0.12)),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: _pink.withOpacity(0.09),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.calendar_month_rounded, color: _pink),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    statusName,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    statusMessage,
                    style: const TextStyle(color: Colors.white38, fontSize: 11),
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: () =>
                  _showCycleSettings(context, ref, expectedUid, cycleData),
              style: TextButton.styleFrom(
                foregroundColor: _pink,
                backgroundColor: _pink.withOpacity(0.08),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text(
                'Configurar',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
              ),
            ),
          ],
        ),
      );
    }

    final phaseName = cycleInfo['name']?.toString() ?? 'Fase atual';

    final aiMessage =
        cycleInfo['message']?.toString() ??
        'Observe como seu corpo está respondendo hoje.';

    final phaseColor = cycleInfo['color'] is Color
        ? cycleInfo['color'] as Color
        : _pink;

    if (presentation == CycleHealthDetailsPresentation.dedicated) {
      return _buildDedicatedHero(
        context,
        ref,
        expectedUid,
        cycleData,
        currentDay,
        totalDays,
        phaseName,
        aiMessage,
        showPillTracking,
      );
    }

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: phaseColor.withOpacity(0.16)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: phaseColor.withOpacity(0.09),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.calendar_month_rounded,
                  color: phaseColor,
                  size: 19,
                ),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'ESTADO ATUAL',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                      ),
                    ),
                    SizedBox(height: 3),
                    Text(
                      'Acompanhamento do seu ciclo',
                      style: TextStyle(color: Colors.white38, fontSize: 10),
                    ),
                  ],
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(
                  Icons.settings_rounded,
                  color: Colors.white54,
                  size: 18,
                ),
                onPressed: () =>
                    _showCycleSettings(context, ref, expectedUid, cycleData),
                tooltip: 'Configurar ciclo',
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(
                  Icons.power_settings_new_rounded,
                  color: Colors.white24,
                  size: 18,
                ),
                onPressed: () => _toggleCycle(context, ref, expectedUid, false),
                tooltip: 'Desativar ciclo',
              ),
            ],
          ),
          const SizedBox(height: 20),
          _buildWeekTracker(),
          const SizedBox(height: 22),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Dia $currentDay',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'de $totalDays dias',
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 7),
                    Text(
                      '$phaseName · estimativa',
                      style: TextStyle(
                        color: phaseColor,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              if (showPillTracking)
                CycleDailyPillControl(health: health, compact: true),
            ],
          ),
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: totalDays > 0
                  ? (currentDay / totalDays).clamp(0.0, 1.0)
                  : 0,
              minHeight: 7,
              backgroundColor: _background,
              valueColor: AlwaysStoppedAnimation<Color>(phaseColor),
            ),
          ),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.all(15),
            decoration: BoxDecoration(
              color: _background,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _purple.withOpacity(0.10)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.auto_awesome_rounded,
                  color: _purple,
                  size: 17,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'SUGESTÃO DO DIA',
                        style: TextStyle(
                          color: _purple,
                          fontSize: 9,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.7,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        aiMessage,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                          height: 1.45,
                        ),
                      ),
                    ],
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

class _MedicationCard extends StatelessWidget {
  final dynamic medication;
  final VoidCallback onDelete;

  const _MedicationCard({
    super.key,
    required this.medication,
    required this.onDelete,
  });

  static const Color _background = Color(0xFF070B14);
  static const Color _green = Colors.greenAccent;

  String _getStatus() {
    final endDate = medication.endDate;

    if (endDate == null) {
      return 'Uso contínuo';
    }

    final now = DateTime.now();

    final today = DateTime(now.year, now.month, now.day);

    final end = DateTime(endDate.year, endDate.month, endDate.day);

    final daysRemaining = end.difference(today).inDays;

    if (daysRemaining < 0) {
      return 'Tratamento encerrado';
    }

    if (daysRemaining == 0) {
      return 'Encerra hoje';
    }

    return '$daysRemaining dias restantes';
  }

  @override
  Widget build(BuildContext context) {
    final endDate = medication.endDate;
    final status = _getStatus();

    final now = DateTime.now();

    final today = DateTime(now.year, now.month, now.day);

    final isExpired =
        endDate != null &&
        DateTime(endDate.year, endDate.month, endDate.day).isBefore(today);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _background,
        borderRadius: BorderRadius.circular(17),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: isExpired
                  ? Colors.redAccent.withOpacity(0.08)
                  : _green.withOpacity(0.08),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.medication_rounded,
              color: isExpired ? Colors.redAccent : _green,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  medication.name.toString(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  status,
                  style: TextStyle(
                    color: isExpired ? Colors.redAccent : Colors.white54,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (endDate != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    'Até ${DateFormat('dd/MM/yyyy').format(endDate)}',
                    style: const TextStyle(
                      color: Colors.white30,
                      fontSize: 9.5,
                    ),
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            icon: const Icon(
              Icons.delete_outline_rounded,
              color: Colors.redAccent,
              size: 20,
            ),
            onPressed: onDelete,
            tooltip: 'Excluir medicamento',
          ),
        ],
      ),
    );
  }
}

class _SnapshotItem extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final String value;

  const _SnapshotItem({
    required this.icon,
    required this.color,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.025),
        borderRadius: BorderRadius.circular(15),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(color: Colors.white38, fontSize: 9),
                ),
                const SizedBox(height: 3),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
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

class _DialogField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String hint;
  final TextInputType? keyboardType;

  const _DialogField({
    required this.controller,
    required this.label,
    required this.hint,
    this.keyboardType,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(color: Colors.white54, fontSize: 11),
        ),
        const SizedBox(height: 7),
        TextField(
          controller: controller,
          keyboardType: keyboardType,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(color: Colors.white24, fontSize: 12),
            filled: true,
            fillColor: const Color(0xFF070B14),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 13,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(13),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(13),
              borderSide: const BorderSide(color: Colors.white10),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(13),
              borderSide: const BorderSide(color: Colors.greenAccent),
            ),
          ),
        ),
      ],
    );
  }
}

class _EmptyMedicationState extends StatelessWidget {
  const _EmptyMedicationState();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 12, vertical: 22),
      child: Column(
        children: [
          Icon(Icons.medication_outlined, color: Colors.white24, size: 34),
          SizedBox(height: 10),
          Text(
            'Nenhum medicamento cadastrado',
            style: TextStyle(
              color: Colors.white54,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          SizedBox(height: 4),
          Text(
            'Adicione um tratamento para acompanhá-lo aqui.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white30, fontSize: 10),
          ),
        ],
      ),
    );
  }
}

class _HealthLoading extends StatelessWidget {
  const _HealthLoading();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: CircularProgressIndicator(
        color: Colors.greenAccent,
        strokeWidth: 2.5,
      ),
    );
  }
}

class _HealthError extends StatelessWidget {
  final VoidCallback onRetry;

  const _HealthError({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: Colors.redAccent.withOpacity(0.08),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.cloud_off_rounded,
                color: Colors.redAccent,
                size: 30,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Não foi possível carregar sua saúde',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Verifique sua conexão e tente novamente.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
            const SizedBox(height: 18),
            OutlinedButton.icon(
              onPressed: onRetry,
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.greenAccent,
                side: const BorderSide(color: Colors.greenAccent),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(13),
                ),
              ),
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Tentar novamente'),
            ),
          ],
        ),
      ),
    );
  }
}

class _MoodData {
  final String label;
  final String emoji;

  const _MoodData({required this.label, required this.emoji});
}
