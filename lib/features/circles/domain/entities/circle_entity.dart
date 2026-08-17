import 'package:equatable/equatable.dart';
import 'package:life_os/features/circles/domain/entities/challenge_entity.dart';

enum CircleMemberRole {
  admin('admin'),
  member('member');

  final String value;

  const CircleMemberRole(this.value);

  static CircleMemberRole? fromValue(Object? value) {
    for (final role in values) {
      if (role.value == value) return role;
    }
    return null;
  }
}

class CircleMemberEntity extends Equatable {
  final String userId;
  final String displayName;
  final String? photoUrl;
  final CircleMemberRole role;
  final DateTime joinedAt;

  const CircleMemberEntity({
    required this.userId,
    required this.displayName,
    required this.photoUrl,
    required this.role,
    required this.joinedAt,
  });

  @override
  List<Object?> get props => [userId, displayName, photoUrl, role, joinedAt];
}

class ChallengeRankingEntry extends Equatable {
  final CircleMemberEntity member;
  final int value;
  final DateTime? lastEventAt;

  const ChallengeRankingEntry({
    required this.member,
    required this.value,
    required this.lastEventAt,
  });

  @override
  List<Object?> get props => [member, value, lastEventAt];
}

class CircleEntity extends Equatable {
  final String id;
  final String name;
  final String description;
  final String adminId;
  final int memberCount;
  final int memberLimit;
  final int schemaVersion;
  final List<CircleMemberEntity> members;
  final List<ChallengeEntity> challenges;

  const CircleEntity({
    required this.id,
    required this.name,
    required this.description,
    required this.adminId,
    required this.memberCount,
    required this.memberLimit,
    required this.schemaVersion,
    required this.members,
    required this.challenges,
  });

  bool isAdmin(String currentUserId) => adminId == currentUserId;

  int progressValueFor(ChallengeEntity challenge, String userId) {
    return challenge.progressFor(userId)?.value ?? 0;
  }

  int totalProgressFor(ChallengeEntity challenge) {
    return members.fold(
      0,
      (total, member) => total + progressValueFor(challenge, member.userId),
    );
  }

  double progressRatioFor(ChallengeEntity challenge) {
    if (challenge.targetValue <= 0) return 0;
    return (totalProgressFor(challenge) / challenge.targetValue).clamp(
      0.0,
      1.0,
    );
  }

  List<ChallengeRankingEntry> rankingFor(ChallengeEntity challenge) {
    final entries = members.map((member) {
      final progress = challenge.progressFor(member.userId);
      return ChallengeRankingEntry(
        member: member,
        value: progress?.value ?? 0,
        lastEventAt: progress?.lastEventAt,
      );
    }).toList();

    entries.sort((a, b) {
      final byValue = b.value.compareTo(a.value);
      if (byValue != 0) return byValue;

      final aTime = a.lastEventAt;
      final bTime = b.lastEventAt;
      if (aTime != null && bTime != null) {
        final byTime = aTime.compareTo(bTime);
        if (byTime != 0) return byTime;
      } else if (aTime != null) {
        return -1;
      } else if (bTime != null) {
        return 1;
      }

      return a.member.userId.compareTo(b.member.userId);
    });

    return entries;
  }

  @override
  List<Object?> get props => [
    id,
    name,
    description,
    adminId,
    memberCount,
    memberLimit,
    schemaVersion,
    members,
    challenges,
  ];
}
