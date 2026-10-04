import 'dart:async';

import 'app_database.dart';
import 'local_database_identity.dart';
import 'user_database_factory.dart';

enum SessionDatabasePhase { detached, opening, prepared, closing }

class SessionDatabaseUnavailable implements Exception {
  const SessionDatabaseUnavailable();

  @override
  String toString() => 'O armazenamento da sessao nao esta disponivel.';
}

class SessionDatabaseSnapshot {
  const SessionDatabaseSnapshot(this.phase, this.generation, this.identity);
  final SessionDatabasePhase phase;
  final int generation;
  final LocalDatabaseIdentity? identity;
}

/// Serializes lifecycle. The reader validates explicit identity, never picks it.
class SessionDatabaseCoordinator {
  SessionDatabaseCoordinator({
    required this.currentUserId,
    Future<AppDatabase> Function(LocalDatabaseIdentity)? openDatabase,
    this.clearKeyCache,
    this.onChanged,
  }) : _openDatabase = openDatabase ?? UserDatabaseFactory().open;

  final String? Function() currentUserId;
  final Future<AppDatabase> Function(LocalDatabaseIdentity) _openDatabase;
  final void Function(LocalDatabaseIdentity)? clearKeyCache;
  final void Function(SessionDatabaseSnapshot)? onChanged;
  Future<void> _tail = Future<void>.value();
  Future<void>? _disposal;
  AppDatabase? _database;
  LocalDatabaseIdentity? _requestedIdentity;
  SessionDatabasePhase _phase = SessionDatabasePhase.detached;
  int _generation = 0;
  bool _disposed = false;

  SessionDatabaseSnapshot get snapshot => SessionDatabaseSnapshot(
    _phase,
    _generation,
    _database?.identity ?? _requestedIdentity,
  );
  AppDatabase? get attachedDatabase => _database;

  AppDatabase requirePrepared() {
    final database = _database;
    if (_disposed ||
        _phase != SessionDatabasePhase.prepared ||
        database == null ||
        database.identity?.uid != currentUserId()) {
      throw const SessionDatabaseUnavailable();
    }
    database.localMutations.capture(expectedUid: database.identity!.uid);
    return database;
  }

  void observeSession(String? uid) {
    _database?.localMutations.observeSession(uid);
    if (_requestedIdentity != null && _requestedIdentity!.uid != uid) {
      _generation++;
      _requestedIdentity = null;
      _phase = _database == null
          ? SessionDatabasePhase.detached
          : SessionDatabasePhase.closing;
      _notify();
    }
  }

  Future<AppDatabase> prepare(
    String expectedUid, {
    Future<void> Function()? beforePublish,
  }) {
    final identity = LocalDatabaseIdentity(expectedUid);
    if (_disposed || currentUserId() != identity.uid) {
      return Future.error(const SessionDatabaseUnavailable());
    }
    if (_requestedIdentity != identity) {
      _requestedIdentity = identity;
      _generation++;
      _database?.localMutations.observeSession(currentUserId());
    }
    final generation = _generation;
    return _serialize(() async {
      _requireRequest(identity, generation);
      if (_phase == SessionDatabasePhase.prepared &&
          _database?.identity == identity) {
        return requirePrepared();
      }
      await _closeAttached();
      _requireRequest(identity, generation);
      _phase = SessionDatabasePhase.opening;
      _notify();
      AppDatabase? candidate;
      try {
        candidate = await _openDatabase(identity);
        _requireRequest(identity, generation);
        if (candidate.identity != identity)
          throw const SessionDatabaseUnavailable();
        candidate.localMutations.bindSessionReader(currentUserId);
        final admission = candidate.localMutations.capture(
          expectedUid: identity.uid,
        );
        await candidate.customSelect('SELECT 1').get();
        await beforePublish?.call();
        _requireRequest(identity, generation);
        candidate.localMutations.openPreparedSession(admission: admission);
        _database = candidate;
        _phase = SessionDatabasePhase.prepared;
        _notify();
        return candidate;
      } catch (_) {
        if (candidate != null) {
          // Retain failed-close candidates so the next open cannot bypass them.
          _database = candidate;
          await _closeAttached();
        } else {
          _phase = SessionDatabasePhase.detached;
          _notify();
        }
        rethrow;
      }
    });
  }

  Future<void> detach({required String expectedUid}) {
    final identity = LocalDatabaseIdentity(expectedUid);
    if (_database?.identity != identity && _requestedIdentity != identity) {
      return Future<void>.value();
    }
    _generation++;
    _requestedIdentity = null;
    _phase = SessionDatabasePhase.closing;
    final drain = _database?.localMutations.sealAndDrainForDetach();
    _notify();
    return _serialize(() async {
      await drain;
      if (_database?.identity == identity) await _closeAttached();
    });
  }

  Future<void> _closeAttached() async {
    final database = _database;
    if (database == null) return;
    _phase = SessionDatabasePhase.closing;
    _notify();
    await database.localMutations.sealAndDrainForDetach();
    await database.closeDatabase();
    clearKeyCache?.call(database.identity!);
    _database = null;
    _phase = SessionDatabasePhase.detached;
    _notify();
  }

  void _requireRequest(LocalDatabaseIdentity identity, int generation) {
    if (_disposed ||
        _generation != generation ||
        _requestedIdentity != identity ||
        currentUserId() != identity.uid) {
      throw const SessionDatabaseUnavailable();
    }
  }

  Future<T> _serialize<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  void _notify() {
    if (!_disposed) onChanged?.call(snapshot);
  }

  Future<void> dispose() {
    if (_disposal != null) return _disposal!;
    _disposed = true;
    _generation++;
    _requestedIdentity = null;
    return _disposal = _serialize(_closeAttached);
  }
}
