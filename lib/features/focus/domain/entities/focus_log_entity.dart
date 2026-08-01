class FocusLogEntity {
  final String id;
  final String targetId;
  final String targetType; // 'TASK', 'SUBJECT', 'EXAM'
  final int durationSeconds;
  final DateTime timestamp;

  FocusLogEntity({
    required this.id,
    required this.targetId,
    required this.targetType,
    required this.durationSeconds,
    required this.timestamp,
  });
}
