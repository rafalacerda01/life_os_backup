class CheckInState {
  final double energy;
  final double focus;
  final double motivation;
  final bool isLoading;

  const CheckInState({
    this.energy = 3.0,
    this.focus = 3.0,
    this.motivation = 3.0,
    this.isLoading = false,
  });

  // O copyWith é padrão no Riverpod para criar novos estados imutáveis
  CheckInState copyWith({
    double? energy,
    double? focus,
    double? motivation,
    bool? isLoading,
  }) {
    return CheckInState(
      energy: energy ?? this.energy,
      focus: focus ?? this.focus,
      motivation: motivation ?? this.motivation,
      isLoading: isLoading ?? this.isLoading,
    );
  }
}
