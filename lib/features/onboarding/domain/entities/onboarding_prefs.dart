import 'package:equatable/equatable.dart';

class OnboardingPrefs extends Equatable {
  final List<String> selectedFocusAreas;
  final bool hasCompletedOnboarding;

  const OnboardingPrefs({required this.selectedFocusAreas, required this.hasCompletedOnboarding});

  @override
  List<Object?> get props => [selectedFocusAreas, hasCompletedOnboarding];
}