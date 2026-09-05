import 'package:equatable/equatable.dart';

class DashboardEntity extends Equatable {
  final double productivityScore;
  final bool hasProductivityData;
  final double healthScore;
  final bool hasHealthData;
  final double financialScore;
  final bool hasFinancialData;
  final int studyStreak;
  final int studyReviewQueue;
  final double studyProgress;
  final int activeMedications;
  final String? mood;
  final int transactionsCount;
  final double financeBalance;

  const DashboardEntity({
    required this.productivityScore,
    this.hasProductivityData = false,
    required this.healthScore,
    this.hasHealthData = false,
    required this.financialScore,
    this.hasFinancialData = false,
    required this.studyStreak,
    required this.studyReviewQueue,
    required this.studyProgress,
    required this.activeMedications,
    this.mood,
    required this.transactionsCount,
    required this.financeBalance,
  });

  double? get overallScore {
    final scores = <double>[
      if (hasProductivityData) productivityScore,
      if (hasHealthData) healthScore,
      if (hasFinancialData) financialScore,
    ];

    if (scores.isEmpty) return null;
    return scores.reduce((total, score) => total + score) / scores.length;
  }

  @override
  List<Object?> get props => [
    productivityScore,
    hasProductivityData,
    healthScore,
    hasHealthData,
    financialScore,
    hasFinancialData,
    studyStreak,
    studyReviewQueue,
    studyProgress,
    activeMedications,
    mood,
    transactionsCount,
    financeBalance,
  ];
}
