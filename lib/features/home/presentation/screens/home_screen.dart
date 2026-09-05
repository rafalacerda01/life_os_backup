import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:go_router/go_router.dart';
import 'package:life_os/core/theme/app_colors.dart';
import 'package:life_os/features/home/presentation/providers/home_provider.dart';
import 'package:life_os/features/auth/presentation/providers/auth_provider.dart';
import 'package:life_os/features/dashboard/data/models/dashboard_model.dart';
import 'package:life_os/features/dashboard/domain/entities/models/insight_model.dart';
import 'package:life_os/features/dashboard/presentation/providers/dashboard_provider.dart';
import 'package:life_os/features/finance/presentation/providers/finance_provider.dart';
import 'package:life_os/features/habits/presentation/providers/habits_provider.dart';
import 'package:life_os/features/health/presentation/providers/health_provider.dart';
import 'package:life_os/features/home/presentation/providers/insight_provider.dart';
import 'package:life_os/features/notifications/domain/providers/notification_engine.dart';
import 'package:life_os/features/study/presentation/providers/study_provider.dart';
import 'package:life_os/features/tasks/presentation/providers/tasks_provider.dart';

void _retryHomeData(WidgetRef ref) {
  ref.invalidate(financeStreamProvider);
  ref.invalidate(studyStreamProvider);
  ref.invalidate(healthStreamProvider);
  ref.invalidate(tasksStreamProvider);
  ref.invalidate(medicationsStreamProvider);
  ref.invalidate(habitsStreamProvider);
  ref.invalidate(subjectsStreamProvider);
}

String _formatBrl(double value) => NumberFormat.currency(
  locale: 'pt_BR',
  symbol: 'R\$',
  decimalDigits: 2,
).format(value);

String _firstName(String? displayName) {
  final normalizedName = displayName?.trim();
  if (normalizedName == null || normalizedName.isEmpty) return 'Usuário';
  return normalizedName.split(RegExp(r'\s+')).first;
}

String _pendingLabel(int count) => count == 1 ? 'pendente' : 'pendentes';

String _activeLabel(int count) => count == 1 ? 'ativo' : 'ativos';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final homeState = ref.watch(homeStateProvider);
    final authState = ref.watch(authNotifierProvider);

    final now = DateTime.now();
    final formattedDate = DateFormat("dd/MM/yyyy - EEEE", "pt_BR").format(now);

    final isPremium = authState.maybeWhen(
      authenticated: (user) => user.isPremium,
      orElse: () => false,
    );

    final userName = authState.maybeWhen(
      authenticated: (user) => _firstName(user.displayName),
      orElse: () => "Usuário",
    );

    final greeting = now.hour < 12
        ? "Bom dia"
        : (now.hour < 18 ? "Boa tarde" : "Boa noite");

    final content = homeState.isLoading
        ? const _HomeScreenSkeleton()
        : homeState.isUnavailable
        ? _HomeUnavailableState(onRetry: () => _retryHomeData(ref))
        : _HomeReadyContent(
            homeState: homeState,
            greeting: greeting,
            userName: userName,
            formattedDate: formattedDate,
            isPremium: isPremium,
          );

    return Container(
      color: AppColors.scaffoldBackground,
      child: SafeArea(child: content),
    );
  }
}

class _HomeReadyContent extends StatelessWidget {
  final HomeStateData homeState;
  final String greeting;
  final String userName;
  final String formattedDate;
  final bool isPremium;

  const _HomeReadyContent({
    required this.homeState,
    required this.greeting,
    required this.userName,
    required this.formattedDate,
    required this.isPremium,
  });

  @override
  Widget build(BuildContext context) {
    final dashboard = homeState.dashboard;

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 380),
      curve: Curves.easeOutCubic,
      builder: (context, animation, child) => Opacity(
        opacity: animation,
        child: Transform.translate(
          offset: Offset(0, 10 * (1 - animation)),
          child: child,
        ),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _HomeHeader(
              greeting: greeting,
              userName: userName,
              formattedDate: formattedDate,
              isPremium: isPremium,
            ),
            const SizedBox(height: 22),
            _MainScoreCard(dashboard: dashboard),
            const SizedBox(height: 16),
            _MetricsRow(dashboard: dashboard),
            const SizedBox(height: 18),
            _PlanDayButton(onTap: () => _showDayPlanner(context, homeState)),
            const SizedBox(height: 26),
            const _HomeSectionHeader(
              eyebrow: 'VISÃO DO DIA',
              title: 'Resumo rápido',
            ),
            const SizedBox(height: 12),
            _QuickSummaryGrid(homeState: homeState),
            const SizedBox(height: 26),
            const _HomeSectionHeader(
              eyebrow: 'LIFE OS INSIGHT',
              title: 'Sugestão para você',
            ),
            const SizedBox(height: 12),
            const PremiumInsightCard(),
          ],
        ),
      ),
    );
  }
}

class _HomeHeader extends ConsumerWidget {
  final String greeting;
  final String userName;
  final String formattedDate;
  final bool isPremium;

  const _HomeHeader({
    required this.greeting,
    required this.userName,
    required this.formattedDate,
    required this.isPremium,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unreadCount = ref.watch(unreadNotificationsCountProvider);

    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                formattedDate.toUpperCase(),
                style: const TextStyle(
                  color: AppColors.textHint,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.1,
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Flexible(
                    child: Text(
                      '$greeting, $userName',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textMain,
                        fontSize: 23,
                        height: 1.1,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (isPremium) ...[
                    const SizedBox(width: 9),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.primary.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(9),
                        border: Border.all(
                          color: AppColors.primary.withOpacity(0.45),
                        ),
                      ),
                      child: const Text(
                        'PREMIUM',
                        style: TextStyle(
                          color: AppColors.primary,
                          fontSize: 9,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.8,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Material(
          color: AppColors.cardBackground,
          shape: CircleBorder(
            side: BorderSide(color: Colors.white.withOpacity(0.07)),
          ),
          child: IconButton(
            tooltip: 'Notificações',
            onPressed: () => context.push('/notifications'),
            icon: Badge(
              isLabelVisible: unreadCount > 0,
              label: Text('$unreadCount'),
              backgroundColor: AppColors.primary,
              child: const Icon(
                Icons.notifications_none_rounded,
                color: AppColors.textSecondary,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _HomeUnavailableState extends StatelessWidget {
  final VoidCallback onRetry;

  const _HomeUnavailableState({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.cloud_off_outlined,
              color: AppColors.textSecondary,
              size: 36,
            ),
            const SizedBox(height: 16),
            const Text(
              'Não foi possível carregar seus dados.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textMain,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Verifique sua conexão e tente novamente.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: onRetry,
              child: const Text('Tentar novamente'),
            ),
          ],
        ),
      ),
    );
  }
}

class _MainScoreCard extends StatelessWidget {
  final DashboardModel dashboard;

  const _MainScoreCard({required this.dashboard});

  @override
  Widget build(BuildContext context) {
    final score = dashboard.overallScore;
    final progress = score == null
        ? 0.0
        : (score / 100).clamp(0.0, 1.0).toDouble();

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppColors.primary.withOpacity(0.22)),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppColors.cardBackground,
            AppColors.secondary.withOpacity(0.13),
            AppColors.primary.withOpacity(0.08),
          ],
        ),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withOpacity(0.08),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox.square(
            dimension: 102,
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox.square(
                  dimension: 102,
                  child: CircularProgressIndicator(
                    value: 1,
                    strokeWidth: 8,
                    color: Colors.white.withOpacity(0.06),
                  ),
                ),
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: progress),
                  duration: const Duration(milliseconds: 750),
                  curve: Curves.easeOutCubic,
                  builder: (context, value, _) => SizedBox.square(
                    dimension: 102,
                    child: CircularProgressIndicator(
                      value: value,
                      strokeWidth: 8,
                      strokeCap: StrokeCap.round,
                      color: score == null
                          ? Colors.transparent
                          : AppColors.primary,
                    ),
                  ),
                ),
                Text(
                  score == null ? '—' : '${score.toInt()}%',
                  key: const Key('home-overall-score-value'),
                  style: const TextStyle(
                    color: AppColors.textMain,
                    fontSize: 25,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.8,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Pontuação geral',
                  style: TextStyle(
                    color: AppColors.textMain,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 7),
                const Text(
                  'Visão atual de produtividade, saúde e finanças',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 13),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.04),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Text(
                    'Pequenas ações, grandes resultados.',
                    style: TextStyle(
                      color: AppColors.textHint,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w500,
                    ),
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

class _MetricsRow extends StatelessWidget {
  final DashboardModel dashboard;

  const _MetricsRow({required this.dashboard});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _MetricCard(
            label: 'Produtividade',
            icon: Icons.bolt_rounded,
            score: dashboard.productivityScore,
            hasData: dashboard.hasProductivityData,
            color: AppColors.primary,
            onTap: () => context.push('/tasks'),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _MetricCard(
            label: 'Saúde',
            icon: Icons.favorite_rounded,
            score: dashboard.healthScore,
            hasData: dashboard.hasHealthData,
            color: AppColors.health,
            onTap: () => context.push('/health'),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _MetricCard(
            label: 'Financeiro',
            icon: Icons.account_balance_wallet_rounded,
            score: dashboard.financialScore,
            hasData: dashboard.hasFinancialData,
            color: AppColors.finance,
            onTap: () => context.push('/finance'),
          ),
        ),
      ],
    );
  }
}

class _MetricCard extends StatelessWidget {
  final String label;
  final IconData icon;
  final double score;
  final bool hasData;
  final Color color;
  final VoidCallback onTap;

  const _MetricCard({
    required this.label,
    required this.icon,
    required this.score,
    required this.hasData,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final progress = hasData ? (score / 100).clamp(0.0, 1.0).toDouble() : 0.0;

    return Material(
      color: AppColors.cardBackground,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: color.withOpacity(0.16)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: color.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: color, size: 17),
              ),
              const SizedBox(height: 11),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  label,
                  maxLines: 1,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                hasData ? '${score.toInt()}%' : '—',
                style: TextStyle(
                  color: hasData ? AppColors.textMain : AppColors.textHint,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 9),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: progress),
                  duration: const Duration(milliseconds: 700),
                  curve: Curves.easeOutCubic,
                  builder: (context, value, _) => LinearProgressIndicator(
                    value: value,
                    minHeight: 4,
                    backgroundColor: Colors.white.withOpacity(0.06),
                    color: color,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlanDayButton extends StatelessWidget {
  final VoidCallback onTap;

  const _PlanDayButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(20),
      child: Ink(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: const LinearGradient(
            colors: [AppColors.secondary, AppColors.primary],
          ),
          boxShadow: [
            BoxShadow(
              color: AppColors.primary.withOpacity(0.18),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 18, vertical: 17),
            child: Row(
              children: [
                Icon(Icons.auto_awesome_rounded, color: Colors.white, size: 21),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Planejar meu dia',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Icon(
                  Icons.arrow_forward_rounded,
                  color: Colors.white70,
                  size: 20,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

void _showDayPlanner(BuildContext context, HomeStateData homeState) {
  final dashboard = homeState.dashboard;

  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: const Color(0xFF0A0F1E),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
    ),
    builder: (sheetContext) => SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        20,
        12,
        20,
        20 + MediaQuery.viewInsetsOf(sheetContext).bottom,
      ),
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
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
          const SizedBox(height: 22),
          const Text(
            'Planejar meu dia',
            style: TextStyle(
              color: AppColors.textMain,
              fontSize: 24,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 7),
          const Text(
            'Organize seu próximo passo com o que já está no Life OS.',
            style: TextStyle(color: AppColors.textSecondary, height: 1.4),
          ),
          const SizedBox(height: 22),
          _PlannerStat(
            icon: Icons.local_fire_department_rounded,
            color: AppColors.habits,
            label: 'Hábitos',
            value:
                '${homeState.completedHabitsToday}/${homeState.totalHabits} concluídos',
          ),
          _PlannerStat(
            icon: Icons.school_rounded,
            color: AppColors.study,
            label: 'Revisões',
            value:
                '${dashboard.studyReviewQueue} '
                '${_pendingLabel(dashboard.studyReviewQueue)}',
          ),
          _PlannerStat(
            icon: Icons.medication_rounded,
            color: AppColors.health,
            label: 'Medicamentos',
            value:
                '${homeState.medicationCount} '
                '${_activeLabel(homeState.medicationCount)}',
          ),
          _PlannerStat(
            icon: Icons.account_balance_wallet_rounded,
            color: AppColors.finance,
            label: 'Saldo',
            value: _formatBrl(dashboard.financeBalance),
          ),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 15),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              onPressed: () {
                Navigator.of(sheetContext).pop();
                context.push('/focus');
              },
              icon: const Icon(Icons.timer_rounded),
              label: const Text(
                'Iniciar foco',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () {
                    Navigator.of(sheetContext).pop();
                    context.push('/tasks');
                  },
                  child: const Text('Ver tarefas'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton(
                  onPressed: () {
                    Navigator.of(sheetContext).pop();
                    context.push('/study');
                  },
                  child: const Text('Ver estudos'),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _PlannerStat extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final String value;

  const _PlannerStat({
    required this.icon,
    required this.color,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.cardBackground,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withOpacity(0.05)),
        ),
        child: Row(
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(color: AppColors.textSecondary),
              ),
            ),
            Flexible(
              child: Text(
                value,
                textAlign: TextAlign.end,
                style: const TextStyle(
                  color: AppColors.textMain,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HomeSectionHeader extends StatelessWidget {
  final String eyebrow;
  final String title;

  const _HomeSectionHeader({required this.eyebrow, required this.title});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          eyebrow,
          style: const TextStyle(
            color: AppColors.primary,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.3,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          title,
          style: const TextStyle(
            color: AppColors.textMain,
            fontSize: 19,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _QuickSummaryGrid extends StatelessWidget {
  final HomeStateData homeState;

  const _QuickSummaryGrid({required this.homeState});

  @override
  Widget build(BuildContext context) {
    final dashboard = homeState.dashboard;

    return LayoutBuilder(
      builder: (context, constraints) {
        final itemWidth = (constraints.maxWidth - 12) / 2;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _QuickSummaryCard(
              width: itemWidth,
              icon: Icons.local_fire_department_rounded,
              color: AppColors.habits,
              label: 'Hábitos',
              value:
                  '${homeState.completedHabitsToday}/${homeState.totalHabits}',
              detail: 'concluídos',
              onTap: () => context.push('/habits'),
            ),
            _QuickSummaryCard(
              width: itemWidth,
              icon: Icons.school_rounded,
              color: AppColors.study,
              label: 'Revisões',
              value: '${dashboard.studyReviewQueue}',
              detail: _pendingLabel(dashboard.studyReviewQueue),
              onTap: () => context.push('/study'),
            ),
            _QuickSummaryCard(
              width: itemWidth,
              icon: Icons.medication_rounded,
              color: AppColors.health,
              label: 'Medicamentos',
              value: '${homeState.medicationCount}',
              detail: _activeLabel(homeState.medicationCount),
              onTap: () => context.push('/health'),
            ),
            _QuickSummaryCard(
              key: const Key('home-summary-balance'),
              width: itemWidth,
              icon: Icons.account_balance_wallet_rounded,
              color: AppColors.finance,
              label: 'Saldo',
              value: _formatBrl(dashboard.financeBalance),
              detail: 'saldo atual',
              onTap: () => context.push('/finance'),
            ),
          ],
        );
      },
    );
  }
}

class _QuickSummaryCard extends StatelessWidget {
  final double width;
  final IconData icon;
  final Color color;
  final String label;
  final String value;
  final String detail;
  final VoidCallback onTap;

  const _QuickSummaryCard({
    super.key,
    required this.width,
    required this.icon,
    required this.color,
    required this.label,
    required this.value,
    required this.detail,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Material(
        color: AppColors.cardBackground,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Colors.white.withOpacity(0.05)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(7),
                      decoration: BoxDecoration(
                        color: color.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: Icon(icon, color: color, size: 17),
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 13),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    value,
                    maxLines: 1,
                    style: const TextStyle(
                      color: AppColors.textMain,
                      fontSize: 19,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  detail,
                  style: const TextStyle(
                    color: AppColors.textHint,
                    fontSize: 10.5,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class PremiumInsightCard extends ConsumerWidget {
  const PremiumInsightCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final insight = ref.watch(currentInsightProvider);

    return Semantics(
      label: 'Sugestão do dia: ${insight.title}. ${insight.message}',
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 600),
        switchInCurve: Curves.easeOutExpo,
        switchOutCurve: Curves.easeInExpo,
        transitionBuilder: (Widget child, Animation<double> animation) {
          return FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0.0, 0.1),
                end: Offset.zero,
              ).animate(animation),
              child: child,
            ),
          );
        },
        child: _InsightCardContent(key: ValueKey(insight.id), insight: insight),
      ),
    );
  }
}

class _InsightCardContent extends StatelessWidget {
  final InsightModel insight;

  const _InsightCardContent({required super.key, required this.insight});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final primaryColor = insight.category.gradientColors.first;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.cardBackground,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: primaryColor.withOpacity(0.15), width: 1.5),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: insight.category.gradientColors,
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: primaryColor.withOpacity(0.4),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Icon(insight.category.icon, color: Colors.white, size: 24),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        insight.title,
                        style: textTheme.titleMedium?.copyWith(
                          color: AppColors.textMain,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.2,
                        ),
                      ),
                    ),
                    if (insight.priority == InsightPriority.critical)
                      _buildCriticalBadge(),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  insight.message,
                  style: textTheme.bodyMedium?.copyWith(
                    color: AppColors.textSecondary,
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

  Widget _buildCriticalBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.redAccent.withOpacity(0.15),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.crisis_alert_rounded, color: Colors.redAccent, size: 12),
          SizedBox(width: 4),
          Text(
            "ALERTA",
            style: TextStyle(
              color: Colors.redAccent,
              fontSize: 10,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}

class _HomeScreenSkeleton extends StatelessWidget {
  const _HomeScreenSkeleton();

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      physics: const NeverScrollableScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _SkeletonBox(width: 180, height: 24),
                  const SizedBox(height: 8),
                  _SkeletonBox(width: 120, height: 14),
                ],
              ),
              _SkeletonBox(width: 40, height: 40, isCircle: true),
            ],
          ),
          const SizedBox(height: 25),
          _SkeletonBox(width: double.infinity, height: 160, borderRadius: 24),
          const SizedBox(height: 20),
          _SkeletonBox(width: double.infinity, height: 110, borderRadius: 24),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(child: _SkeletonBox(height: 90, borderRadius: 16)),
              const SizedBox(width: 12),
              Expanded(child: _SkeletonBox(height: 90, borderRadius: 16)),
              const SizedBox(width: 12),
              Expanded(child: _SkeletonBox(height: 90, borderRadius: 16)),
            ],
          ),
          const SizedBox(height: 25),
          _SkeletonBox(width: 100, height: 20),
          const SizedBox(height: 12),
          _SkeletonBox(width: double.infinity, height: 80, borderRadius: 16),
          const SizedBox(height: 20),
          _SkeletonBox(width: 90, height: 20),
          const SizedBox(height: 12),
          _SkeletonBox(width: double.infinity, height: 80, borderRadius: 16),
        ],
      ),
    );
  }
}

class _SkeletonBox extends StatelessWidget {
  final double width;
  final double height;
  final double borderRadius;
  final bool isCircle;

  const _SkeletonBox({
    this.width = double.infinity,
    required this.height,
    this.borderRadius = 8,
    this.isCircle = false,
  });

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0.2, end: 0.6),
      duration: const Duration(milliseconds: 800),
      curve: Curves.easeInOut,
      builder: (context, opacity, child) {
        return Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.05 * opacity),
            shape: isCircle ? BoxShape.circle : BoxShape.rectangle,
            borderRadius: isCircle ? null : BorderRadius.circular(borderRadius),
          ),
        );
      },
    );
  }
}
