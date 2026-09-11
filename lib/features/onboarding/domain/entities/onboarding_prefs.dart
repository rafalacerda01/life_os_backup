import 'package:equatable/equatable.dart';

class OnboardingPrefs extends Equatable {
  final bool hasCompletedOnboarding;
  final bool operationInProgress;

  const OnboardingPrefs({
    required this.hasCompletedOnboarding,
    this.operationInProgress = false,
  });

  @override
  List<Object?> get props => [hasCompletedOnboarding, operationInProgress];
}
