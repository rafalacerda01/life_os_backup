import 'app_database.dart';
import 'local_database_identity.dart';
import 'local_installation_identity_service.dart';
import 'session_database_coordinator.dart';
import 'user_database_factory.dart';

/// Staged, Firebase-free database session for a local installation.
///
/// Keep separate from the authenticated app providers until migration of
/// UID-scoped encrypted databases and all module side effects is verified.
class LocalDeviceSession {
  LocalDeviceSession({
    required this.identityService,
    Future<AppDatabase> Function(LocalDatabaseIdentity)? openDatabase,
    void Function(LocalDatabaseIdentity)? clearKeyCache,
  }) {
    coordinator = SessionDatabaseCoordinator(
      currentUserId: () => _uid,
      openDatabase: openDatabase ?? UserDatabaseFactory().open,
      clearKeyCache: clearKeyCache,
    );
  }

  final LocalInstallationIdentityService identityService;
  late final SessionDatabaseCoordinator coordinator;
  String? _uid;
  bool _disposed = false;

  String? get currentLocalId => _uid;

  Future<AppDatabase> open() async {
    if (_disposed) throw const SessionDatabaseUnavailable();
    final identity = await identityService.resolve();
    if (_disposed) throw const SessionDatabaseUnavailable();
    if (_uid != null && _uid != identity.uid) {
      throw const SessionDatabaseUnavailable();
    }
    _uid = identity.uid;
    try {
      return await coordinator.prepare(identity.uid);
    } catch (_) {
      _uid = null;
      coordinator.observeSession(null);
      rethrow;
    }
  }

  AppDatabase requirePrepared() => coordinator.requirePrepared();

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _uid = null;
    coordinator.observeSession(null);
    await coordinator.dispose();
  }
}
