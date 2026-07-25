import 'package:equatable/equatable.dart';

class HealthLogEntity extends Equatable {
  final int waterIntakeMl;
  final int waterTargetMl;
  final double sleepHours;
  final double sleepTargetHours;
  final int steps;
  final int stepsTarget;
  final int caloriesBurned;
  final int caloriesTarget;
  final String mood;

  const HealthLogEntity({
    required this.waterIntakeMl,
    required this.waterTargetMl,
    required this.sleepHours,
    required this.sleepTargetHours,
    required this.steps,
    required this.stepsTarget,
    required this.caloriesBurned,
    required this.caloriesTarget,
    required this.mood,
  });

  HealthLogEntity copyWith({
    int? waterIntakeMl,
    int? waterTargetMl,
    double? sleepHours,
    double? sleepTargetHours,
    int? steps,
    int? stepsTarget,
    int? caloriesBurned,
    int? caloriesTarget,
    String? mood,
  }) {
    return HealthLogEntity(
      waterIntakeMl: waterIntakeMl ?? this.waterIntakeMl,
      waterTargetMl: waterTargetMl ?? this.waterTargetMl,
      sleepHours: sleepHours ?? this.sleepHours,
      sleepTargetHours: sleepTargetHours ?? this.sleepTargetHours,
      steps: steps ?? this.steps,
      stepsTarget: stepsTarget ?? this.stepsTarget,
      caloriesBurned: caloriesBurned ?? this.caloriesBurned,
      caloriesTarget: caloriesTarget ?? this.caloriesTarget,
      mood: mood ?? this.mood,
    );
  }

  @override
  List<Object?> get props => [
        waterIntakeMl,
        waterTargetMl,
        sleepHours,
        sleepTargetHours,
        steps,
        stepsTarget,
        caloriesBurned,
        caloriesTarget,
        mood,
      ];
}