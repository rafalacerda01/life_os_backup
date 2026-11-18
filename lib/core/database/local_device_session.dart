import 'app_database.dart';
import 'database_sync_policy.dart';
import 'local_database_identity.dart';
import 'local_installation_identity_service.dart';
import 'local_profile_admission.dart';
import 'session_database_coordinator.dart';
import 'user_database_factory.dart';

/// Staged, Firebase-free database session for a local installation.
///
/// Keep separate from the authenticated app providers until migration of
/// UID-scoped encrypted databases and all module side effects is verified.
/// Its connection cannot enqueue or mutate historical queue rows, and cannot
/// grant remote-send permits. Module wiring is a separate qualification stage.
class LocalDeviceSession {
  LocalDeviceSession({
    required this.identityService,
    Future<AppDatabase> Function(LocalDatabaseIdentity)? openDatabase,
    void Function(LocalDatabaseIdentity)? clearKeyCache,
  }) {
    final open =
        openDatabase ??
        UserDatabaseFactory(syncPolicy: DatabaseSyncPolicy.localOnly).open;
    coordinator = SessionDatabaseCoordinator(
      currentUserId: () => _uid,
      openDatabase: (identity) async {
        final database = await open(identity);
        if (!database.isLocalOnly) {
          await database.closeDatabase();
          throw StateError('LOCAL_PROFILE_SYNC_POLICY_REQUIRED');
        }
        return database;
      },
      clearKeyCache: clearKeyCache,
    );
  }

  final LocalInstallationIdentityService identityService;
  late final SessionDatabaseCoordinator coordinator;
  String? _uid;
  bool _disposed = false;
  Future<void>? _disposal;
  Future<AppDatabase>? _opening;

  String? get currentLocalId => _uid;

  Future<AppDatabase> open() {
    if (_disposed) return Future.error(const SessionDatabaseUnavailable());
    return _opening ??= _openWithAdmission().whenComplete(
      () => _opening = null,
    );
  }

  Future<AppDatabase> _openWithAdmission() async {
    final directory = await identityService.documentsDirectory();
    return LocalProfileAdmission(directory).run(_openAdmitted);
  }

  Future<AppDatabase> _openAdmitted() async {
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

  Future<void> dispose() {
    if (_disposal != null) return _disposal!;
    _disposed = true;
    _uid = null;
    coordinator.observeSession(null);
    return _disposal = coordinator.dispose();
  }
}
