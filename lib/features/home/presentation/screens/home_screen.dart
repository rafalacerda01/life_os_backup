import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:go_router/go_router.dart';
import 'package:life_os/core/theme/app_colors.dart';
import 'package:life_os/core/widgets/dashboard_components.dart';
import 'package:life_os/features/home/presentation/providers/home_provider.dart';
import 'package:life_os/features/auth/presentation/providers/auth_provider.dart';
import 'package:life_os/features/dashboard/data/models/dashboard_model.dart';
import 'package:life_os/features/dashboard/domain/entities/models/insight_model.dart';
import 'package:life_os/features/home/presentation/providers/insight_provider.dart';

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
      authenticated: (user) => user.displayName ?? "Usuário",
      orElse: () => "Usuário",
    );

    final greeting = now.hour < 12
        ? "Bom dia"
        : (now.hour < 18 ? "Boa tarde" : "Boa noite");

    final dashboard = homeState.dashboard;
    final nextExam = homeState.nextExam;

    return Container(
      color: AppColors.scaffoldBackground,
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                "$greeting, $userName",
                                style: const TextStyle(
                                  color: AppColors.textMain,
                                  fontSize: 22,
                                  fontWeight: FontWeight.bold,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (isPremium) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: AppColors.primary.withOpacity(0.15),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: AppColors.primary),
                                ),
                                child: const Text(
                                  "PRO",
                                  style: TextStyle(
                                    color: AppColors.primary,
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          formattedDate,
                          style: const TextStyle(
                            color: AppColors.textHint,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.notifications_none,
                      color: AppColors.textSecondary,
                    ),
                    onPressed: () => context.push('/notifications'),
                  ),
                ],
              ),

              // Próxima Prova (Banner de Alerta)
              if (nextExam != null) ...[
                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.warning.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: AppColors.warning.withOpacity(0.3),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.event_note,
                        color: AppColors.warning,
                        size: 32,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              "Prova de ${nextExam.title}",
                              style: const TextStyle(
                                color: AppColors.textMain,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              "Faltam ${nextExam.examDate!.difference(now).inDays} dias",
                              style: const TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 25),
              _MainScoreCard(dashboard: dashboard),
              const SizedBox(height: 20),

              // Correção aplicada: Substituído o _InsightCard antigo pelo novo motor escalável
              const PremiumInsightCard(),

              const SizedBox(height: 20),

              // Mini Cards de Acesso Rápido
              Row(
                children: [
                  Expanded(
                    child: MiniCard(
                      title: "Produtividade",
                      value: "${dashboard.productivityScore.toInt()}%",
                      color: Colors.purpleAccent,
                      onTap: () => context.push('/tasks'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: MiniCard(
                      title: "Saúde",
                      value: "${dashboard.healthScore.toInt()}%",
                      color: Colors.greenAccent,
                      onTap: () => context.push('/health'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: MiniCard(
                      title: "Financeiro",
                      value: "${dashboard.financialScore.toInt()}%",
                      color: Colors.blueAccent,
                      onTap: () => context.push('/finance'),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 25),
              const SectionTitle("Estudos"),
              const SizedBox(height: 12),
              InfoCard(
                title: "Progresso de estudo",
                subtitle:
                    "Streak: ${dashboard.studyStreak} dias • Revisões: ${dashboard.studyReviewQueue}",
                value: "${(dashboard.studyProgress * 100).toInt()}%",
                color: AppColors.study,
                icon: Icons.school_rounded,
                onTap: () => context.push('/study'),
              ),

              const SizedBox(height: 20),
              const SectionTitle("Saúde"),
              const SizedBox(height: 12),
              InfoCard(
                title: "Estado geral",
                subtitle:
                    "Medicamentos ativos: ${homeState.medicationCount} • Humor: ${dashboard.mood}",
                value: "${dashboard.healthScore.toInt()}%",
                color: AppColors.health,
                icon: Icons.favorite_rounded,
                onTap: () => context.push('/health'),
              ),

              const SizedBox(height: 20),
              const SectionTitle("Finanças"),
              const SizedBox(height: 12),
              InfoCard(
                title: "Saldo atual",
                subtitle: "Transações: ${dashboard.transactionsCount}",
                value: "R\$ ${dashboard.financeBalance.toStringAsFixed(2)}",
                color: AppColors.finance,
                icon: Icons.account_balance_wallet_rounded,
                onTap: () => context.push('/finance'),
              ),

              const SizedBox(height: 20),
              const SectionTitle("Hábitos"),
              const SizedBox(height: 12),
              InfoCard(
                title: "Rotina Diária",
                subtitle:
                    "Concluídos: ${homeState.completedHabitsToday} de ${homeState.totalHabits}",
                value: homeState.totalHabits > 0
                    ? "${((homeState.completedHabitsToday / homeState.totalHabits) * 100).toInt()}%"
                    : "0%",
                color: AppColors.habits,
                icon: Icons.local_fire_department_rounded,
                onTap: () => context.push('/habits'),
              ),
              const SizedBox(height: 30),
            ],
          ),
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
    final score =
        (dashboard.productivityScore +
            dashboard.healthScore +
            dashboard.financialScore) /
        3;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const LinearGradient(
          colors: [AppColors.secondary, AppColors.primary],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "Score geral do dia",
            style: TextStyle(
              color: AppColors.textMain,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 15),
          Text(
            "${score.toInt()}%",
            style: const TextStyle(
              fontSize: 42,
              color: AppColors.textMain,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            "Seu desempenho geral hoje",
            style: TextStyle(color: AppColors.textSecondary),
          ),
        ],
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
      label: 'Insight do dia: ${insight.title}. ${insight.message}',
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
        // boxShadow removido daqui para eliminar a sombra/glow
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
