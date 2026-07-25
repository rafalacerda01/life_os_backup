import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:go_router/go_router.dart';
import 'package:life_os/core/theme/app_colors.dart';
import 'package:life_os/core/widgets/dashboard_components.dart';
import 'package:life_os/features/health/presentation/providers/health_provider.dart';
import 'package:life_os/features/habits/presentation/providers/habits_provider.dart';
import 'package:life_os/features/dashboard/presentation/providers/dashboard_provider.dart';
import 'package:life_os/features/dashboard/data/models/dashboard_model.dart';
import 'package:life_os/features/auth/presentation/providers/auth_provider.dart';
import 'package:life_os/features/study/presentation/providers/study_provider.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  @override
  void initState() {
    super.initState();
    // ✅ Sincronização movida para o ciclo de vida correto (fora do build)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Idealmente, mover isso para um provider de inicialização global,
      // mas mantido aqui de forma segura sem disparar a cada rebuild.
    });
  }

  @override
  Widget build(BuildContext context) {
    final dashboard = ref.watch(dashboardStateProvider);
    final authState = ref.watch(authNotifierProvider);
    final habitsAsync = ref.watch(habitsStreamProvider);
    final medicationsAsync = ref.watch(medicationsStreamProvider);
    final subjectsAsync = ref.watch(subjectsStreamProvider);

    final now = DateTime.now();
    final formattedDate = DateFormat("dd/MM/yyyy - EEEE", "pt_BR").format(now);

    // Dados processados do usuário
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

    // Tratamento seguro de Medicamentos
    final medCount = medicationsAsync.when(
      data: (meds) => meds.length.toString(),
      loading: () => "...",
      error: (_, _) => "0",
    );

    // Processamento otimizado de Provas
    final subjects = subjectsAsync.value ?? [];
    final nextExam = subjects
        .where(
          (s) => s.hasExam && s.examDate != null && s.examDate!.isAfter(now),
        )
        .fold<dynamic>(null, (earliest, current) {
          if (earliest == null ||
              current.examDate!.compareTo(earliest.examDate!) < 0) {
            return current;
          }
          return earliest;
        });

    // Processamento de Hábitos
    final habits = habitsAsync.value ?? [];
    final formattedToday = DateFormat('yyyy-MM-dd').format(now);
    final completedToday = habits
        .where((h) => h.completedDates.contains(formattedToday))
        .length;

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
              _InsightCard(dashboard: dashboard),
              const SizedBox(height: 20),

              // Mini Cards de Acesso Rápido (Usando push para manter histórico de navegação)
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
                    "Medicamentos ativos: $medCount • Humor: ${dashboard.mood ?? "—"}",
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
                subtitle: "Concluídos: $completedToday de ${habits.length}",
                value: habits.isNotEmpty
                    ? "${((completedToday / habits.length) * 100).toInt()}%"
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

class _InsightCard extends StatelessWidget {
  final DashboardModel dashboard;
  const _InsightCard({required this.dashboard});

  @override
  Widget build(BuildContext context) {
    String text = dashboard.productivityScore > 70
        ? "Você está em alta produtividade hoje 🚀"
        : (dashboard.healthScore < 50
              ? "Sua saúde precisa de atenção hoje ❤️"
              : "Você está em equilíbrio hoje ⚖️");
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.cardBackground,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          const Icon(Icons.auto_graph, color: Colors.purpleAccent),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}
