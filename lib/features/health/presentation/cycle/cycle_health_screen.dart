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

class CycleHealthScreen extends ConsumerStatefulWidget {
  const CycleHealthScreen({super.key, this.clock});

  final DateTime Function()? clock;

  static const Color _background = Color(0xFF070B14);
  static const Color _surface = Color(0xFF11182E);
  static const Color _primary = Color(0xFFB026FF);
  static const Color _rose = Color(0xFFFF6B9F);
  static const Color _softRose = Color(0xFFFF9FBA);
  static const Color _lilac = Color(0xFFC58CFF);
  static const Color _turquoise = Color(0xFF58D6C7);

  @override
  ConsumerState<CycleHealthScreen> createState() => _CycleHealthScreenState();
}

class _CycleHealthScreenState extends ConsumerState<CycleHealthScreen>
    with WidgetsBindingObserver {
  static const Color _background = CycleHealthScreen._background;
  static const Color _primary = CycleHealthScreen._primary;

  late DateTime _activeDay;

  DateTime get _now => (widget.clock ?? DateTime.now)();

  DateTime _dateOnly(DateTime value) =>
      DateTime(value.year, value.month, value.day);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _activeDay = _dateOnly(_now);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.invalidate(healthStreamProvider);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !mounted) return;

    final resumedDay = _dateOnly(_now);
    if (resumedDay == _activeDay) return;

    _activeDay = resumedDay;
    ref.invalidate(healthStreamProvider);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final healthAsync = ref.watch(healthStreamProvider);

    return Scaffold(
      backgroundColor: _background,
      body: SafeArea(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: const Alignment(0.85, -0.85),
              radius: 1.15,
              colors: [_primary.withOpacity(0.11), _background],
            ),
          ),
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
                    final isEnabled =
                        health.menstrualCycle?['isEnabled'] == true;
                    final hasUsableEstimate = day > 0 && totalDays > 0;

                    return SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          CycleHealthDetails(
                            health: health,
                            presentation:
                                CycleHealthDetailsPresentation.dedicated,
                          ),
                          if (hasUsableEstimate) ...[
                            const SizedBox(height: 16),
                            _CycleMetricsCard(health: health, now: _now),
                          ],
                          if (isEnabled ||
                              health.mood.trim().isNotEmpty ||
                              health.waterIntakeMl > 0) ...[
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
      padding: const EdgeInsets.fromLTRB(12, 10, 20, 16),
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
                    fontSize: 23,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.4,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  'Entenda seu ritmo',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
            decoration: BoxDecoration(
              color: CycleHealthScreen._surface.withOpacity(0.72),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: Colors.white10),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.lock_outline_rounded,
                  color: CycleHealthScreen._lilac,
                  size: 13,
                ),
                SizedBox(width: 5),
                Text(
                  'PRIVADO',
                  style: TextStyle(
                    color: Colors.white60,
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.8,
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

class _CycleMetricsCard extends StatelessWidget {
  const _CycleMetricsCard({required this.health, required this.now});

  final HealthModel health;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final estimatedDate = estimatedNextPeriodDate(health, now);
    final today = DateTime(now.year, now.month, now.day);
    final daysUntil = estimatedDate?.difference(today).inDays;
    final cycleLength = (health.menstrualCycle?['cycleLengthDays'] as num?)
        ?.toInt();
    final periodLength = (health.menstrualCycle?['periodLengthDays'] as num?)
        ?.toInt();

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
            'VISÃO GERAL',
            style: TextStyle(
              color: Colors.white54,
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.9,
            ),
          ),
          const SizedBox(height: 12),
          _MetricTile(
            icon: Icons.event_available_rounded,
            color: CycleHealthScreen._rose,
            label: 'Próxima menstruação',
            value: daysUntil == null
                ? 'Estimativa indisponível'
                : daysUntil == 1
                ? 'em 1 dia'
                : 'em $daysUntil dias',
            detail: estimatedDate == null
                ? null
                : '${DateFormat('dd/MM').format(estimatedDate)} · estimativa',
          ),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, constraints) {
              final tiles = [
                _MetricTile(
                  icon: Icons.sync_rounded,
                  color: CycleHealthScreen._lilac,
                  label: 'Duração do ciclo',
                  value: cycleLength == null ? '—' : '$cycleLength dias',
                  compact: true,
                ),
                _MetricTile(
                  icon: Icons.water_drop_outlined,
                  color: CycleHealthScreen._softRose,
                  label: 'Duração do período',
                  value: periodLength == null ? '—' : '$periodLength dias',
                  compact: true,
                ),
              ];

              if (constraints.maxWidth < 330) {
                return Column(
                  children: [
                    tiles.first,
                    const SizedBox(height: 10),
                    tiles.last,
                  ],
                );
              }

              return Row(
                children: [
                  Expanded(child: tiles.first),
                  const SizedBox(width: 10),
                  Expanded(child: tiles.last),
                ],
              );
            },
          ),
          const SizedBox(height: 12),
          const Text(
            'A data pode variar conforme o ciclo e os registros informados.',
            style: TextStyle(color: Colors.white38, fontSize: 11, height: 1.4),
          ),
        ],
      ),
    );
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({
    required this.icon,
    required this.color,
    required this.label,
    required this.value,
    this.detail,
    this.compact = false,
  });

  final IconData icon;
  final Color color;
  final String label;
  final String value;
  final String? detail;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(compact ? 13 : 15),
      decoration: BoxDecoration(
        color: CycleHealthScreen._background.withOpacity(0.72),
        borderRadius: BorderRadius.circular(17),
        border: Border.all(color: color.withOpacity(0.15)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: compact ? 18 : 21),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(color: Colors.white54, fontSize: 10),
                ),
                const SizedBox(height: 3),
                Text(
                  value,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (detail != null) ...[
                  const SizedBox(height: 2),
                  Text(detail!, style: TextStyle(color: color, fontSize: 11)),
                ],
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
          LayoutBuilder(
            builder: (context, constraints) {
              final moodCard = _RecordChip(
                icon: Icons.sentiment_satisfied_alt_rounded,
                color: CycleHealthScreen._lilac,
                label: 'Humor',
                value: mood,
              );
              final hydrationCard = _RecordChip(
                icon: Icons.water_drop_rounded,
                color: CycleHealthScreen._turquoise,
                label: 'Hidratação',
                value: hydration,
              );

              if (constraints.maxWidth < 330) {
                return Column(
                  children: [
                    moodCard,
                    const SizedBox(height: 10),
                    hydrationCard,
                  ],
                );
              }

              return Row(
                children: [
                  Expanded(child: moodCard),
                  const SizedBox(width: 10),
                  Expanded(child: hydrationCard),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _RecordChip extends StatelessWidget {
  const _RecordChip({
    required this.icon,
    required this.color,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final Color color;
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
          Icon(icon, color: color, size: 18),
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
          Icon(Icons.shield_outlined, color: Colors.white54, size: 19),
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
