import 'package:equatable/equatable.dart';

class ChallengeEntity extends Equatable {
  final String id;
  final String title;
  final int targetXp;
  final int currentXpContributed;
  final String createdBy;

  const ChallengeEntity({
    required this.id,
    required this.title,
    required this.targetXp,
    required this.currentXpContributed,
    required this.createdBy,
  });

  // Getter inteligente para facilitar as barras de progresso na UI
  double get progressRatio =>
      targetXp > 0 ? (currentXpContributed / targetXp).clamp(0.0, 1.0) : 0.0;
  bool get isCompleted => currentXpContributed >= targetXp;

  // Método mágico para o Riverpod atualizar o estado facilmente
  ChallengeEntity copyWith({
    String? id,
    String? title,
    int? targetXp,
    int? currentXpContributed,
    String? createdBy,
  }) {
    return ChallengeEntity(
      id: id ?? this.id,
      title: title ?? this.title,
      targetXp: targetXp ?? this.targetXp,
      currentXpContributed: currentXpContributed ?? this.currentXpContributed,
      createdBy: createdBy ?? this.createdBy,
    );
  }

  @override
  List<Object?> get props => [
    id,
    title,
    targetXp,
    currentXpContributed,
    createdBy,
  ];
}
