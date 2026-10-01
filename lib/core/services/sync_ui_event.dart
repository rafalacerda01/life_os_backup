enum SyncUiEventType { resumed, recoveryCompleted }

class SyncUiEvent {
  final SyncUiEventType type;
  final String ownerUid;

  const SyncUiEvent({required this.type, required this.ownerUid});
}
