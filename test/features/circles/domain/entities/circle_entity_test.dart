import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/features/circles/domain/entities/challenge_entity.dart';
import 'package:life_os/features/circles/domain/entities/circle_entity.dart';

void main() {
  final timestamp = DateTime.utc(2026, 1, 1);

  CircleMemberEntity member(String userId) {
    return CircleMemberEntity(
      userId: userId,
      displayName: userId,
      photoUrl: null,
      role: CircleMemberRole.member,
      joinedAt: timestamp,
    );
  }

  ChallengeProgressEntity progress(
    String userId,
    int value, {
    DateTime? lastEventAt,
  }) {
    return ChallengeProgressEntity(
      userId: userId,
      value: value,
      updatedAt: timestamp,
      lastEventAt: lastEventAt,
    );
  }

  ChallengeEntity challenge(List<ChallengeProgressEntity> progressEntries) {
    return ChallengeEntity(
      id: 'challenge-1',
      type: ChallengeType.taskCompletions,
      title: 'Concluir tarefas',
      targetValue: 10,
      startAt: timestamp,
      endAt: timestamp.add(const Duration(days: 7)),
      createdBy: 'admin',
      createdAt: timestamp,
      updatedAt: timestamp,
      schemaVersion: 2,
      progress: progressEntries,
    );
  }

  CircleEntity circle(
    List<CircleMemberEntity> members,
    ChallengeEntity challenge,
  ) {
    return CircleEntity(
      id: 'circle-1',
      name: 'Circle',
      description: 'Description',
      adminId: 'admin',
      memberCount: members.length,
      memberLimit: 10,
      schemaVersion: 2,
      members: members,
      challenges: [challenge],
    );
  }

  test('membro sem progress aparece com valor zero e desempate por UID', () {
    final currentChallenge = challenge([]);
    final currentCircle = circle([
      member('user-b'),
      member('user-a'),
    ], currentChallenge);

    final ranking = currentCircle.rankingFor(currentChallenge);

    expect(ranking.map((entry) => entry.member.userId), ['user-a', 'user-b']);
    expect(ranking.map((entry) => entry.value), [0, 0]);
  });

  test('ranking ordena por valor e depois pelo menor lastEventAt', () {
    final earlier = timestamp.add(const Duration(minutes: 1));
    final later = timestamp.add(const Duration(minutes: 2));
    final currentChallenge = challenge([
      progress('user-a', 0),
      progress('user-b', 5, lastEventAt: earlier),
      progress('user-c', 5, lastEventAt: later),
    ]);
    final currentCircle = circle([
      member('user-a'),
      member('user-c'),
      member('user-b'),
    ], currentChallenge);

    final ranking = currentCircle.rankingFor(currentChallenge);

    expect(ranking.map((entry) => entry.member.userId), [
      'user-b',
      'user-c',
      'user-a',
    ]);
  });

  test('total considera somente membros atuais do Circle', () {
    final currentChallenge = challenge([
      progress('member', 2),
      progress('former-member', 999),
    ]);
    final currentCircle = circle([member('member')], currentChallenge);

    expect(currentCircle.totalProgressFor(currentChallenge), 2);
    expect(currentCircle.progressRatioFor(currentChallenge), 0.2);
  });
}
