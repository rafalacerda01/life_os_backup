import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/features/ai_companion/data/models/ai_insight.dart';
import 'package:life_os/features/ai_companion/presentation/providers/ai_companion_provider.dart';

const _background = Color(0xFF070B14);
const _surface = Color(0xFF11182E);
const _primary = Color(0xFFB026FF);

class AICompanionHub extends StatelessWidget {
  const AICompanionHub({
    super.key,
    required this.state,
    required this.localSummary,
    required this.onIntent,
    required this.onRevoke,
  });

  final AICompanionState state;
  final AsyncValue<AICompanionLocalSummary> localSummary;
  final ValueChanged<AIInsightIntent> onIntent;
  final VoidCallback onRevoke;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: _background,
    child: Stack(
      children: [
        const Positioned.fill(
          child: RepaintBoundary(child: CustomPaint(painter: _GalaxyPainter())),
        ),
        SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 22, 20, 32),
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF5D0EFF), _primary],
                      ),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: const Icon(Icons.auto_awesome, color: Colors.white),
                  ),
                  const SizedBox(width: 14),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Companion IA',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          'Requer internet para novas análises',
                          style: TextStyle(color: Colors.white54, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('revoke-ai-consent'),
                    tooltip: 'Revogar consentimento da IA',
                    onPressed: onRevoke,
                    icon: const Icon(
                      Icons.privacy_tip_outlined,
                      color: Colors.white70,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 28),
              _summaryCard(),
              const SizedBox(height: 28),
              const Text(
                'Escolha uma análise',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Cada análise usa apenas agregados locais necessários.',
                style: TextStyle(color: Colors.white54),
              ),
              const SizedBox(height: 16),
              _action(
                'Analisar meu dia',
                'Um panorama do que importa agora',
                Icons.wb_sunny_outlined,
                AIInsightIntent.dailyOverview,
                primary: true,
              ),
              const SizedBox(height: 10),
              _action(
                'Ver minha semana',
                'Consistência dos últimos sete dias',
                Icons.date_range_outlined,
                AIInsightIntent.weeklyOverview,
              ),
              const SizedBox(height: 10),
              _action(
                'Analisar minhas finanças',
                'Resumo do mês atual',
                Icons.account_balance_wallet_outlined,
                AIInsightIntent.financeMonthSummary,
              ),
              const SizedBox(height: 28),
              _insightCard(),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _summaryCard() => Container(
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: _surface,
      borderRadius: BorderRadius.circular(24),
      border: Border.all(color: _primary.withValues(alpha: 0.25)),
      boxShadow: [
        BoxShadow(color: _primary.withValues(alpha: 0.08), blurRadius: 28),
      ],
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Seu sistema hoje',
          style: TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'Resumo local, sem consulta à IA',
          style: TextStyle(color: Colors.white54, fontSize: 12),
        ),
        const SizedBox(height: 18),
        localSummary.when(
          loading: () => const LinearProgressIndicator(color: _primary),
          error: (_, _) => const Text(
            'Resumo local indisponível.',
            style: TextStyle(color: Colors.white70),
          ),
          data: (value) => Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _metric('Tarefas', value.pendingTasks.toString()),
              _metric(
                'Hábitos',
                '${value.completedHabitsToday}/${value.activeHabits}',
              ),
              _metric('Focus', '${value.focusMinutesToday} min'),
              _metric(
                'Energia',
                value.energy == null
                    ? '—'
                    : '${value.energy!.toStringAsFixed(1)}/5',
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _metric(String label, String value) => Container(
    width: 135,
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: _background.withValues(alpha: 0.8),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    ),
  );

  Widget _action(
    String title,
    String subtitle,
    IconData icon,
    AIInsightIntent intent, {
    bool primary = false,
  }) => Material(
    color: Colors.transparent,
    child: InkWell(
      key: ValueKey('insight-${intent.wireValue}'),
      onTap: state.isLoading ? null : () => onIntent(intent),
      borderRadius: BorderRadius.circular(20),
      child: Ink(
        padding: const EdgeInsets.all(17),
        decoration: BoxDecoration(
          gradient: primary
              ? const LinearGradient(colors: [Color(0xFF5D0EFF), _primary])
              : null,
          color: primary ? null : _surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white12),
        ),
        child: Row(
          children: [
            Icon(icon, color: Colors.white),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ],
              ),
            ),
            const Icon(Icons.arrow_forward_rounded, color: Colors.white70),
          ],
        ),
      ),
    ),
  );

  Widget _insightCard() => Container(
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: _surface,
      borderRadius: BorderRadius.circular(24),
      border: Border.all(color: Colors.white12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Insight do Core',
          style: TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 16),
        if (state.isLoading) ...[
          const LinearProgressIndicator(color: _primary),
          const SizedBox(height: 12),
          const Text(
            'Preparando sua análise...',
            style: TextStyle(color: Colors.white70),
          ),
        ] else if (state.sanitizedError != null) ...[
          const Icon(Icons.error_outline, color: Colors.white54),
          const SizedBox(height: 8),
          Text(
            state.sanitizedError!,
            style: const TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: state.lastIntent == null
                ? null
                : () => onIntent(state.lastIntent!),
            child: const Text('Tentar novamente'),
          ),
        ] else if (state.insight != null) ...[
          Text(
            state.insight!.headline,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 21,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            state.insight!.summary,
            style: const TextStyle(color: Colors.white70, height: 1.5),
          ),
          const SizedBox(height: 16),
          Text(
            state.insight!.recommendation,
            style: const TextStyle(color: Color(0xFFE6BAFF), height: 1.5),
          ),
        ] else
          const Text(
            'Escolha uma análise acima para ver seu insight.',
            style: TextStyle(color: Colors.white54),
          ),
      ],
    ),
  );
}

class _GalaxyPainter extends CustomPainter {
  const _GalaxyPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final glow = Paint()
      ..shader =
          RadialGradient(
            colors: [_primary.withValues(alpha: 0.15), Colors.transparent],
          ).createShader(
            Rect.fromCircle(
              center: Offset(size.width * 0.82, size.height * 0.14),
              radius: size.width * 0.8,
            ),
          );
    canvas.drawRect(Offset.zero & size, glow);
    final star = Paint()..color = Colors.white.withValues(alpha: 0.22);
    for (var i = 0; i < 28; i++) {
      final x = size.width * ((i * 37 % 97) / 97);
      final y = size.height * ((i * 59 % 89) / 89);
      canvas.drawCircle(Offset(x, y), i % 5 == 0 ? 1.2 : 0.65, star);
    }
  }

  @override
  bool shouldRepaint(covariant _GalaxyPainter oldDelegate) => false;
}
