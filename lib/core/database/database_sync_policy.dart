/// Explicit behavior of this connection, never inferred from Auth absence.
enum DatabaseSyncPolicy { remoteEnabled, localOnly }

class LocalRemoteSyncDisabled implements Exception {
  const LocalRemoteSyncDisabled();
  static const code = 'LOCAL_PROFILE_REMOTE_SYNC_DISABLED';
  @override
  String toString() => code;
}
