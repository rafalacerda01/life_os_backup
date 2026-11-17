import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'local_database_identity.dart';

class LocalAccountLease {
  LocalAccountLease._(this.identity, this.revision, this._isCurrent);
  final LocalDatabaseIdentity identity;
  final int revision;
  final bool Function() _isCurrent;
  bool get isCurrent => _isCurrent();
  void requireCurrent() {
    if (!isCurrent) throw StateError('LOCAL_ACCOUNT_SESSION_CHANGED');
  }
}

class LocalAccountSessionSnapshot {
  const LocalAccountSessionSnapshot(this.identity, this.revision);
  final LocalDatabaseIdentity? identity;
  final int revision;
}

/// Bound only after R1 receipt admission and database preparation. A local
/// binding is not a server authorization and never opens the CLOSED cohort.
class LocalAccountSession extends Notifier<LocalAccountSessionSnapshot> {
  @override
  LocalAccountSessionSnapshot build() =>
      const LocalAccountSessionSnapshot(null, 0);
  void bind(LocalDatabaseIdentity identity) {
    if (!identity.isBound)
      throw StateError('LOCAL_GENERATION_BINDING_REQUIRED');
    state = LocalAccountSessionSnapshot(identity, state.revision + 1);
  }

  void clear() => state = LocalAccountSessionSnapshot(null, state.revision + 1);

  void clearIfCurrent(LocalDatabaseIdentity identity) {
    if (state.identity == identity) clear();
  }

  bool isClearedAfter(LocalAccountLease lease) =>
      state.identity == null && state.revision == lease.revision + 1;

  LocalAccountLease capture() {
    final snapshot = state, identity = snapshot.identity;
    if (identity == null) throw StateError('LOCAL_ACCOUNT_SESSION_REQUIRED');
    return LocalAccountLease._(
      identity,
      snapshot.revision,
      () =>
          ref.mounted &&
          state.identity == identity &&
          state.revision == snapshot.revision,
    );
  }
}

final localAccountSessionProvider =
    NotifierProvider<LocalAccountSession, LocalAccountSessionSnapshot>(
      LocalAccountSession.new,
    );
