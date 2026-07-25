import 'package:equatable/equatable.dart';
import 'package:life_os/features/circles/domain/entities/challenge_entity.dart';

class RankingMemberEntity extends Equatable {
  final String userId;
  final String name;
  final int totalXp;
  final int rankPosition;
  final bool isCurrentUser;
  final String? photoUrl;

  const RankingMemberEntity({
    required this.userId,
    required this.name,
    required this.totalXp,
    required this.rankPosition,
    required this.isCurrentUser,
    this.photoUrl,
  });

  RankingMemberEntity copyWith({
    String? userId,
    String? name,
    int? totalXp,
    int? rankPosition,
    bool? isCurrentUser,
    String? photoUrl,
  }) {
    return RankingMemberEntity(
      userId: userId ?? this.userId,
      name: name ?? this.name,
      totalXp: totalXp ?? this.totalXp,
      rankPosition: rankPosition ?? this.rankPosition,
      isCurrentUser: isCurrentUser ?? this.isCurrentUser,
      photoUrl: photoUrl ?? this.photoUrl,
    );
  }

  @override
  List<Object?> get props => [
    userId,
    name,
    totalXp,
    rankPosition,
    isCurrentUser,
    photoUrl,
  ];
}

class CircleEntity extends Equatable {
  final String id;
  final String name;
  final String description;
  final String adminId;
  final int memberCount;
  final List<RankingMemberEntity> ranking;
  final List<ChallengeEntity> activeChallenges;

  const CircleEntity({
    required this.id,
    required this.name,
    required this.description,
    required this.adminId,
    required this.memberCount,
    required this.ranking,
    required this.activeChallenges,
  });

  // Atalho para a UI esconder/mostrar botões de deletar círculo
  bool isAdmin(String currentUserId) => adminId == currentUserId;

  CircleEntity copyWith({
    String? id,
    String? name,
    String? description,
    String? adminId,
    int? memberCount,
    List<RankingMemberEntity>? ranking,
    List<ChallengeEntity>? activeChallenges,
  }) {
    return CircleEntity(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      adminId: adminId ?? this.adminId,
      memberCount: memberCount ?? this.memberCount,
      ranking: ranking ?? this.ranking,
      activeChallenges: activeChallenges ?? this.activeChallenges,
    );
  }

  @override
  List<Object?> get props => [
    id,
    name,
    description,
    adminId,
    memberCount,
    ranking,
    activeChallenges,
  ];
}
