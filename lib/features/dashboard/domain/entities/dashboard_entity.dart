import 'package:equatable/equatable.dart';

class DashboardEntity extends Equatable {
  final double productivityScore;
  final double healthScore;
  final double financialScore;
  final int studyStreak;
  final int studyReviewQueue;
  final double studyProgress;
  final int activeMedications;
  final String? mood;
  final int transactionsCount;
  final double financeBalance;

  const DashboardEntity({
    required this.productivityScore,
    required this.healthScore,
    required this.financialScore,
    required this.studyStreak,
    required this.studyReviewQueue,
    required this.studyProgress,
    required this.activeMedications,
    this.mood,
    required this.transactionsCount,
    required this.financeBalance,
  });

  @override
  List<Object?> get props => [
        productivityScore,
        healthScore,
        financialScore,
        studyStreak,
        studyReviewQueue,
        studyProgress,
        activeMedications,
        mood,
        transactionsCount,
        financeBalance,
      ];
}