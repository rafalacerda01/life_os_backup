import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:life_os/features/health/data/models/health_model.dart';
import 'package:life_os/features/health/presentation/health_screen.dart';
import 'package:life_os/features/health/presentation/providers/health_provider.dart';

import 'cycle_reminder_section.dart';

DateTime? estimatedNextPeriodDate(HealthModel health, DateTime now) {
  if (health.menstrualCycle?['isEnabled'] != true) return null;

  final cycleInfo = health.cyclePhaseInfo;
  final day = (cycleInfo['day'] as num?)?.toInt() ?? 0;
  final totalDays = (cycleInfo['totalDays'] as num?)?.toInt() ?? 0;
  if (day <= 0 || totalDays <= 0 || day > totalDays) return null;

  final today = DateTime(now.year, now.month, now.day);
  return today.add(Duration(days: totalDays - day + 1));
}

class CycleHealthScreen extends ConsumerWidget {
  const CycleHealthScreen({super.key, this.clock});

  final DateTime Function()? clock;

  static const Color _background = Color(0xFF070B14);
  static const Color _surface = Color(0xFF11182E);
  static const Color _primary = Color(0xFFB026FF);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final healthAsync = ref.watch(healthStreamProvider);

    return Scaffold(
      backgroundColor: _background,
      body: SafeArea(
        child: Column(
          children: [
            _CycleHeader(onBack: () => Navigator.of(context).maybePop()),
            Expanded(
              child: healthAsync.when(
                loading: () => const Center(
                  child: CircularProgressIndicator(color: _primary),
                ),
                error: (_, _) => _CycleLoadError(
                  onRetry: () => ref.invalidate(healthStreamProvider),
                ),
                data: (health) {
                  final cycleInfo = health.cyclePhaseInfo;
                  final day = (cycleInfo['day'] as num?)?.toInt() ?? 0;
                  final totalDays =
                      (cycleInfo['totalDays'] as num?)?.toInt() ?? 0;
                  final isEnabled = health.menstrualCycle?['isEnabled'] == true;
                  final hasUsableEstimate = day > 0 && totalDays > 0;

                  return SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Acompanhe seus registros com contexto e sem previsões absolutas.',
                          style: TextStyle(
                            color: Colors.white60,
                            fontSize: 14,
                            height: 1.45,
                          ),
                        ),
                        const SizedBox(height: 20),
                        CycleHealthDetails(health: health),
                        if (hasUsableEstimate) ...[
                          const SizedBox(height: 16),
                          _NextPeriodEstimateCard(
                            health: health,
                            now: (clock ?? DateTime.now)(),
                          ),
                        ],
                        if (isEnabled) ...[
                          const SizedBox(height: 16),
                          _AvailableRecordsCard(health: health),
                        ],
                        const SizedBox(height: 16),
                        const CycleReminderSection(),
                        const SizedBox(height: 16),
                        const _CycleDisclaimer(),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CycleHeader extends StatelessWidget {
  const _CycleHeader({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 20, 12),
      child: Row(
        children: [
          IconButton(
            onPressed: onBack,
            tooltip: 'Voltar',
            icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
          ),
          const SizedBox(width: 4),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Saúde do ciclo',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  'Estimativas com base nos seus registros',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NextPeriodEstimateCard extends StatelessWidget {
  const _NextPeriodEstimateCard({required this.health, required this.now});

  final HealthModel health;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final estimatedDate = estimatedNextPeriodDate(health, now);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: CycleHealthScreen._surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: CycleHealthScreen._primary.withOpacity(0.16)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: CycleHealthScreen._primary.withOpacity(0.10),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(
              Icons.event_available_rounded,
              color: CycleHealthScreen._primary,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Próxima menstruação estimada',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  estimatedDate == null
                      ? 'Complete os registros para visualizar uma estimativa.'
                      : 'Por volta de ${DateFormat('dd/MM/yyyy').format(estimatedDate)}',
                  style: const TextStyle(
                    color: CycleHealthScreen._primary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 5),
                const Text(
                  'A data pode variar conforme o ciclo e os registros informados.',
                  style: TextStyle(
                    color: Colors.white54,
                    fontSize: 12,
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
}

class _AvailableRecordsCard extends StatelessWidget {
  const _AvailableRecordsCard({required this.health});

  final HealthModel health;

  @override
  Widget build(BuildContext context) {
    final normalizedMood = health.mood.trim();
    final mood = normalizedMood.isEmpty || normalizedMood == '—'
        ? 'Não registrado'
        : normalizedMood;
    final hydration = health.waterIntakeMl > 0
        ? '${health.waterIntakeMl} ml hoje'
        : 'Não registrada hoje';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: CycleHealthScreen._surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Registros disponíveis',
            style: TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Informações já registradas no módulo Saúde.',
            style: TextStyle(color: Colors.white54, fontSize: 12),
          ),
          const SizedBox(height: 14),
          Column(
            children: [
              _RecordChip(
                icon: Icons.sentiment_satisfied_alt_rounded,
                label: 'Humor',
                value: mood,
              ),
              const SizedBox(height: 10),
              _RecordChip(
                icon: Icons.water_drop_rounded,
                label: 'Hidratação',
                value: hydration,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RecordChip extends StatelessWidget {
  const _RecordChip({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
      decoration: BoxDecoration(
        color: CycleHealthScreen._background,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: CycleHealthScreen._primary, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(color: Colors.white38, fontSize: 10),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
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

class _CycleDisclaimer extends StatelessWidget {
  const _CycleDisclaimer();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.035),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white10),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded, color: Colors.white54, size: 19),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'As estimativas do ciclo são informativas e podem variar. '
              'Elas não substituem orientação médica.',
              style: TextStyle(
                color: Colors.white60,
                fontSize: 12,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CycleLoadError extends StatelessWidget {
  const _CycleLoadError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.refresh_rounded, color: Colors.white54, size: 34),
            const SizedBox(height: 12),
            const Text(
              'Não foi possível carregar os dados do ciclo.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70),
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
