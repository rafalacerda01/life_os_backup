import '../../domain/entities/dashboard_entity.dart';

class DashboardModel extends DashboardEntity {
  const DashboardModel({
    required super.productivityScore,
    super.hasProductivityData = false,
    required super.healthScore,
    super.hasHealthData = false,
    required super.financialScore,
    super.hasFinancialData = false,
    required super.studyStreak,
    required super.studyReviewQueue,
    required super.studyProgress,
    required super.activeMedications,
    super.mood,
    required super.transactionsCount,
    required super.financeBalance,
  });

  factory DashboardModel.fromJson(Map<String, dynamic> json) {
    return DashboardModel(
      productivityScore: (json['productivityScore'] as num? ?? 0.0).toDouble(),
      hasProductivityData: json['hasProductivityData'] == true,
      healthScore: (json['healthScore'] as num? ?? 0.0).toDouble(),
      hasHealthData: json['hasHealthData'] == true,
      financialScore: (json['financialScore'] as num? ?? 0.0).toDouble(),
      hasFinancialData: json['hasFinancialData'] == true,
      studyStreak: json['studyStreak'] as int? ?? 0,
      studyReviewQueue: json['studyReviewQueue'] as int? ?? 0,
      studyProgress: (json['studyProgress'] as num? ?? 0.0).toDouble(),
      activeMedications: json['activeMedications'] as int? ?? 0,
      mood: json['mood'] as String?,
      transactionsCount: json['transactionsCount'] as int? ?? 0,
      financeBalance: (json['financeBalance'] as num? ?? 0.0).toDouble(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'productivityScore': productivityScore,
      'hasProductivityData': hasProductivityData,
      'healthScore': healthScore,
      'hasHealthData': hasHealthData,
      'financialScore': financialScore,
      'hasFinancialData': hasFinancialData,
      'studyStreak': studyStreak,
      'studyReviewQueue': studyReviewQueue,
      'studyProgress': studyProgress,
      'activeMedications': activeMedications,
      'mood': mood,
      'transactionsCount': transactionsCount,
      'financeBalance': financeBalance,
    };
  }
}
