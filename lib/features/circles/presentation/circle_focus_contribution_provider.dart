import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/features/circles/domain/entities/challenge_entity.dart';

class CircleChallengeWindow {
  final ChallengeType type;
  final DateTime startAt;
  final DateTime endAt;

  const CircleChallengeWindow({
    required this.type,
    required this.startAt,
    required this.endAt,
  });
}

bool _isSafeDocumentId(Object? value) {
  return value is String &&
      value.isNotEmpty &&
      value.length <= 128 &&
      value.trim() == value &&
      !value.contains('/');
}

/// Mantém o Focus informado sobre qual Círculo está ativo sem depender
/// da abertura prévia da tela de Círculos.
final activeCircleIdForFocusProvider = StreamProvider<String?>((ref) {
  final user = FirebaseAuth.instance.currentUser;

  if (user == null) {
    return Stream<String?>.value(null);
  }

  return FirebaseFirestore.instance
      .collection('users')
      .doc(user.uid)
      .snapshots()
      .map((snapshot) {
        final activeCircleId = snapshot.data()?['activeCircleId'];

        if (!_isSafeDocumentId(activeCircleId)) {
          return null;
        }

        return activeCircleId as String;
      });
});

/// Observa somente os metadados necessários para informar se uma sessão
/// Focus pode contribuir para desafios ativos.
///
/// A decisão competitiva real continua sendo feita exclusivamente
/// pelo backend.
final circleChallengeWindowsProvider =
    StreamProvider.family<List<CircleChallengeWindow>, String>((ref, circleId) {
      if (!_isSafeDocumentId(circleId)) {
        return Stream<List<CircleChallengeWindow>>.value(
          const <CircleChallengeWindow>[],
        );
      }

      return FirebaseFirestore.instance
          .collection('circles')
          .doc(circleId)
          .collection('challenges')
          .snapshots()
          .map((snapshot) {
            final result = <CircleChallengeWindow>[];

            for (final doc in snapshot.docs) {
              final data = doc.data();

              if (data['schemaVersion'] != 2) {
                continue;
              }

              final type = ChallengeType.fromValue(data['type']);
              final startAt = data['startAt'];
              final endAt = data['endAt'];

              if (type == null ||
                  startAt is! Timestamp ||
                  endAt is! Timestamp) {
                continue;
              }

              final startDate = startAt.toDate();
              final endDate = endAt.toDate();

              if (endDate.isBefore(startDate)) {
                continue;
              }

              result.add(
                CircleChallengeWindow(
                  type: type,
                  startAt: startDate,
                  endAt: endDate,
                ),
              );
            }

            return result;
          });
    });

int countEligibleCircleChallenges({
  required Iterable<CircleChallengeWindow> challenges,
  required Set<ChallengeType> acceptedTypes,
  required int sessionDurationSeconds,
  DateTime? now,
}) {
  if (sessionDurationSeconds <= 0 || acceptedTypes.isEmpty) {
    return 0;
  }

  final sessionStart = now ?? DateTime.now();
  final estimatedCompletion = sessionStart.add(
    Duration(seconds: sessionDurationSeconds),
  );

  return challenges.where((challenge) {
    if (!acceptedTypes.contains(challenge.type)) {
      return false;
    }

    // O backend exige que toda a sessão verificada esteja dentro
    // da janela temporal do desafio.
    if (sessionStart.isBefore(challenge.startAt)) {
      return false;
    }

    if (estimatedCompletion.isAfter(challenge.endAt)) {
      return false;
    }

    return true;
  }).length;
}
