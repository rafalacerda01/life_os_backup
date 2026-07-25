import '../../domain/entities/dashboard_entity.dart';

class DashboardModel extends DashboardEntity {
  const DashboardModel({
    required super.productivityScore,
    required super.healthScore,
    required super.financialScore,
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
      healthScore: (json['healthScore'] as num? ?? 0.0).toDouble(),
      financialScore: (json['financialScore'] as num? ?? 0.0).toDouble(),
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
      'healthScore': healthScore,
      'financialScore': financialScore,
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