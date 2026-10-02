import 'dart:async';

import 'package:drift/drift.dart';

class LocalMutationUnavailable implements Exception {
  const LocalMutationUnavailable();

  @override
  String toString() => 'A sessão não permite salvar alterações agora.';
}

/// Identity captured before an asynchronous producer can outlive its session.
class LocalMutationTicket {
  const LocalMutationTicket._(this._gate, this._generation, this._uid);

  final LocalMutationGate _gate;
  final int _generation;
  final String? _uid;
}

class _Lease {
  _Lease(this.ticket, {this.system = false});

  final LocalMutationTicket ticket;
  final bool system;
  bool active = true;
}

/// One admission covers the entire logical write, not individual SQL statements.
class LocalMutationGate {
  final Object _zoneKey = Object();
  String? Function()? _currentUserId;
  String? _observedUserId;
  int _generation = 0;
  int _active = 0;
  bool _sealed = false;
  LocalMutationQuiescence? _quiescence;
  Completer<void>? _idle;

  void bindSessionReader(String? Function() currentUserId) {
    final alreadyBound = _currentUserId != null;
    _currentUserId = currentUserId;
    if (alreadyBound) {
      observeSession(currentUserId());
    } else {
      _observedUserId = currentUserId();
      _generation++;
      _sealed = true;
    }
  }

  LocalMutationTicket capture({String? expectedUid}) {
    if (_currentUserId != null) observeSession(_currentUserId!());
    final inherited = Zone.current[_zoneKey] as _Lease?;
    final ticket =
        inherited?.ticket ??
        LocalMutationTicket._(
          this,
          _generation,
          _currentUserId?.call() ?? expectedUid,
        );
    if (expectedUid != null &&
        _currentUserId != null &&
        ticket._uid != expectedUid) {
      throw const LocalMutationUnavailable();
    }
    _validate(ticket);
    return ticket;
  }

  void _validate(LocalMutationTicket ticket) {
    if (_currentUserId != null) observeSession(_currentUserId!());
    if (!identical(ticket._gate, this) ||
        ticket._generation != _generation ||
        (_currentUserId != null && _currentUserId!() != ticket._uid)) {
      throw const LocalMutationUnavailable();
    }
  }

  Future<T> run<T>(
    Future<T> Function() action, {
    LocalMutationTicket? ticket,
    bool waitForReopen = true,
  }) async {
    final inherited = Zone.current[_zoneKey] as _Lease?;
    final admission = ticket ?? capture();
    _validate(admission);
    if (inherited != null &&
        inherited.active &&
        identical(inherited.ticket, admission)) {
      validateCurrentLease();
      return action();
    }

    while (_quiescence != null) {
      if (!waitForReopen) throw const LocalMutationUnavailable();
      await _quiescence!._finished.future;
      _validate(admission);
    }
    if (_sealed) throw const LocalMutationUnavailable();
    return _admit(admission, action);
  }

  Future<T> _admit<T>(
    LocalMutationTicket ticket,
    Future<T> Function() action, {
    bool system = false,
  }) async {
    _validate(ticket);
    final lease = _Lease(ticket, system: system);
    _active++;
    try {
      return await runZoned(action, zoneValues: {_zoneKey: lease});
    } finally {
      lease.active = false;
      if (--_active == 0) {
        _idle?.complete();
        _idle = null;
      }
    }
  }

  /// Only acknowledgements of existing rows and authorized cleanup use this.
  Future<T> systemWrite<T>(
    String? expectedUid,
    Future<T> Function() action, {
    LocalMutationTicket? admission,
  }) {
    if (_currentUserId != null) observeSession(_currentUserId!());
    final ticket =
        admission ?? LocalMutationTicket._(this, _generation, expectedUid);
    if (ticket._uid != expectedUid) throw const LocalMutationUnavailable();
    if (_sealed) throw const LocalMutationUnavailable();
    return _admit(ticket, action, system: true);
  }

  /// Durable Auth cleanup may recover a sealed session without reopening it.
  Future<T> cleanupWrite<T>(Future<T> Function() action) {
    final inherited = Zone.current[_zoneKey] as _Lease?;
    if (inherited != null && inherited.active) {
      validateCurrentLease();
      return action();
    }
    return _admit(capture(), action, system: true);
  }

  void validateCurrentLease() {
    final lease = Zone.current[_zoneKey] as _Lease?;
    if (lease == null || !lease.active) throw const LocalMutationUnavailable();
    _validate(lease.ticket);
    if (!lease.system && _quiescence?._sessionChanged == true) {
      throw const LocalMutationUnavailable();
    }
  }

  LocalMutationQuiescence beginQuiesce(String expectedUid) {
    if (_currentUserId != null) observeSession(_currentUserId!());
    if (_sealed ||
        _quiescence != null ||
        expectedUid.isEmpty ||
        _currentUserId?.call() != expectedUid) {
      throw const LocalMutationUnavailable();
    }
    return _quiescence = LocalMutationQuiescence._(
      this,
      LocalMutationTicket._(this, _generation, expectedUid),
    );
  }

  void observeSession(String? uid) {
    final quiescence = _quiescence;
    if (quiescence != null && uid != quiescence._ticket._uid) {
      quiescence._sessionChanged = true;
    }
    if (uid == _observedUserId) return;
    _observedUserId = uid;
    _generation++;
    _sealed = true;
  }

  void openPreparedSession({LocalMutationTicket? admission}) {
    if (_quiescence != null) throw const LocalMutationUnavailable();
    _validate(admission ?? capture());
    _sealed = false;
  }
}

class LocalMutationQuiescence {
  LocalMutationQuiescence._(this._gate, this._ticket);

  final LocalMutationGate _gate;
  final LocalMutationTicket _ticket;
  final Completer<void> _finished = Completer<void>();
  bool _sessionChanged = false;

  void requireCurrentSession() {
    _gate._validate(_ticket);
    if (!identical(_gate._quiescence, this) || _sessionChanged) {
      throw const LocalMutationUnavailable();
    }
  }

  Future<void> drain() async {
    requireCurrentSession();
    if (_gate._active != 0) {
      await (_gate._idle ??= Completer<void>()).future;
    }
    requireCurrentSession();
  }

  Future<T> cleanup<T>(Future<T> Function() action, {bool signedOut = false}) {
    if (!identical(_gate._quiescence, this)) {
      throw const LocalMutationUnavailable();
    }
    if (signedOut) {
      if (_gate._currentUserId?.call() != null) {
        throw const LocalMutationUnavailable();
      }
      return _gate.cleanupWrite(action);
    }
    requireCurrentSession();
    return _gate.systemWrite(_ticket._uid, action);
  }

  void finish({required bool signOutConfirmed, bool keepSealed = false}) {
    if (!identical(_gate._quiescence, this)) return;
    final sameSession =
        !_sessionChanged && _gate._currentUserId?.call() == _ticket._uid;
    _gate._quiescence = null;
    if (signOutConfirmed || keepSealed || !sameSession) {
      _gate._sealed = true;
      _gate._generation++;
    }
    _finished.complete();
  }
}

/// Defense for direct DAO SQL and batches, including derived local state.
class LocalMutationInterceptor extends QueryInterceptor {
  LocalMutationInterceptor(this.gate);

  final LocalMutationGate gate;

  @override
  Future<bool> ensureOpen(QueryExecutor executor, QueryExecutorUser user) =>
      gate.cleanupWrite(() => executor.ensureOpen(user));

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) =>
      gate.run(() => executor.runInsert(statement, args), waitForReopen: false);
  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) =>
      gate.run(() => executor.runUpdate(statement, args), waitForReopen: false);
  @override
  Future<int> runDelete(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) =>
      gate.run(() => executor.runDelete(statement, args), waitForReopen: false);
  @override
  Future<void> runCustom(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) =>
      gate.run(() => executor.runCustom(statement, args), waitForReopen: false);
  @override
  Future<void> runBatched(
    QueryExecutor executor,
    BatchedStatements statements,
  ) => gate.run(() => executor.runBatched(statements), waitForReopen: false);
  @override
  Future<void> commitTransaction(TransactionExecutor inner) =>
      gate.run(inner.send, waitForReopen: false);
}
