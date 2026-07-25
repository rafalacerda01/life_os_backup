import 'package:equatable/equatable.dart';

class DailyPerformance extends Equatable {
  final String dayName;
  final double scorePercentage;

  const DailyPerformance({required this.dayName, required this.scorePercentage});

  @override
  List<Object?> get props => [dayName, scorePercentage];
}

class AnalyticsEntity extends Equatable {
  final double productivityIndex;
  final double healthIndex;
  final double financeIndex;
  final double habitConsistency;
  final List<DailyPerformance> weeklyEvolution;

  const AnalyticsEntity({
    required this.productivityIndex,
    required this.healthIndex,
    required this.financeIndex,
    required this.habitConsistency,
    required this.weeklyEvolution,
  });

  @override
  List<Object?> get props => [
        productivityIndex,
        healthIndex,
        financeIndex,
        habitConsistency,
        weeklyEvolution,
      ];
}