import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../database/local_account_session.dart';
import 'trusted_account_access.dart';
import '../database/local_database_identity.dart';

/// The SDK cache is not a generation namespace. An admitted generation can
/// keep its own Drift offline; it cannot hydrate from a UID-only SDK snapshot.
abstract final class GenerationalReadPolicy {
  // Shared form of the existing Tasks read custody. Namespace/cache alone is
  // never admission. Call before IO and after the last server response.
  static Future<void> verify({
    required LocalDatabaseIdentity? identity,
    required LocalAccountLease? lease,
    required FirebaseAuth auth,
    required FirebaseFirestore store,
    required String expectedUid,
  }) async {
    if (identity?.generation == null) return; // Unbound historical test storage.
    requireCurrent(identity: identity, lease: lease, auth: auth, expectedUid: expectedUid);
    final confirmed = await TrustedAccountAccess.admittedIdentity(auth, store, expectedUid, allowBootstrap:false);
    requireCurrent(identity: identity, lease: lease, auth: auth, expectedUid: expectedUid);
    if (confirmed != identity) throw StateError('REMOTE_LOCAL_BINDING_MISMATCH');
  }

  static void requireCurrent({
    required LocalDatabaseIdentity? identity,
    required LocalAccountLease? lease,
    required FirebaseAuth auth,
    required String expectedUid,
  }) {
    if (identity?.generation == null) return;
    if (identity?.isBound != true || lease == null || lease.identity != identity || auth.currentUser?.uid != expectedUid) {
      throw StateError('REMOTE_READ_CUSTODY_REQUIRED');
    }
    lease.requireCurrent();
  }

  static GetOptions? options(
    LocalDatabaseIdentity? identity,
    FirebaseFirestore store,
  ) {
    if (identity?.generation == null) return null;
    if (identity?.isBound != true ||
        identity!.projectId != store.app.options.projectId ||
        identity.databaseId != store.databaseId)
      throw StateError('REMOTE_LOCAL_BINDING_MISMATCH');
    return const GetOptions(source: Source.server);
  }

  static bool accepts(
    LocalDatabaseIdentity? identity, {
    required bool fromCache,
    required bool pendingWrites,
  }) =>
      identity?.generation == null ||
      identity?.isBound == true && !fromCache && !pendingWrites;
}
