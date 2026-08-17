import 'package:equatable/equatable.dart';

enum ChallengeType {
  focusMinutes('FOCUS_MINUTES', 'minutos de foco'),
  habitCompletions('HABIT_COMPLETIONS', 'habitos concluidos'),
  studyMinutes('STUDY_MINUTES', 'minutos de estudo'),
  taskCompletions('TASK_COMPLETIONS', 'tarefas concluidas');

  final String value;
  final String label;

  const ChallengeType(this.value, this.label);

  static ChallengeType? fromValue(Object? value) {
    for (final type in values) {
      if (type.value == value) return type;
    }
    return null;
  }
}

class ChallengeProgressEntity extends Equatable {
  final String userId;
  final int value;
  final DateTime? updatedAt;
  final DateTime? lastEventAt;

  const ChallengeProgressEntity({
    required this.userId,
    required this.value,
    this.updatedAt,
    this.lastEventAt,
  });

  @override
  List<Object?> get props => [userId, value, updatedAt, lastEventAt];
}

class ChallengeEntity extends Equatable {
  final String id;
  final ChallengeType type;
  final String title;
  final int targetValue;
  final DateTime startAt;
  final DateTime endAt;
  final String createdBy;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int schemaVersion;
  final List<ChallengeProgressEntity> progress;

  const ChallengeEntity({
    required this.id,
    required this.type,
    required this.title,
    required this.targetValue,
    required this.startAt,
    required this.endAt,
    required this.createdBy,
    required this.createdAt,
    required this.updatedAt,
    required this.schemaVersion,
    required this.progress,
  });

  bool get isExpired => !DateTime.now().isBefore(endAt);

  ChallengeProgressEntity? progressFor(String userId) {
    for (final entry in progress) {
      if (entry.userId == userId) return entry;
    }
    return null;
  }

  @override
  List<Object?> get props => [
    id,
    type,
    title,
    targetValue,
    startAt,
    endAt,
    createdBy,
    createdAt,
    updatedAt,
    schemaVersion,
    progress,
  ];
}
