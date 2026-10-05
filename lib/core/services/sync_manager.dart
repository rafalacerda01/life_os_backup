import 'dart:async';

import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/utils/app_logger.dart';

import 'sync_operation_result.dart';
import 'sync_queue_store.dart';
import 'sync_remote_data_source.dart';
import 'sync_ui_event.dart';

class SyncManager {
  static const _succeededRetention = Duration(days: 7);

  static const _retryDelays = [
    Duration(seconds: 5),
    Duration(seconds: 15),
    Duration(seconds: 30),
    Duration(minutes: 1),
    Duration(minutes: 5),
  ];

  final SyncQueueStore _queueStore;
  final SyncRemoteDataSource _remoteDataSource;
  final String? Function() _currentUserId;
  final _uiEvents = StreamController<SyncUiEvent>.broadcast();
  String? _recoveryUid;
  bool _recoveryResumed = false;

  Stream<SyncUiEvent> get uiEvents => _uiEvents.stream;

  Future<bool>? _processingFuture;
  Completer<void>? _processingStop;
  bool _processAgain = false;
  Timer? _retryTimer;
  String? _retryUid;
  int _retryAttempt = 0;
  bool _disposed = false;
  String? _pausedUid;
  int _processingGeneration = 0;

  SyncManager({
    required this._queueStore,
    required this._remoteDataSource,
    required this._currentUserId,
  });

  /// Stop session work without uploading or discarding the preserved queue.
  /// An already sent request may finish remotely; its unconfirmed local item
  /// remains pending for the same owner's idempotent replay after relogin.
  Future<bool> prepareForSessionDetach(String expectedUid) async {
    if (_disposed ||
        expectedUid.isEmpty ||
        _currentUserId()?.trim() != expectedUid) {
      return false;
    }
    _pausedUid = expectedUid;
    _processingGeneration++;
    if (_processingStop?.isCompleted == false) _processingStop!.complete();
    _processAgain = false;
    _resetRetry();
    await _processingFuture;
    return !_disposed &&
        _pausedUid == expectedUid &&
        _currentUserId()?.trim() == expectedUid;
  }

  /// Only an aborted exit with the same prepared session can resume this manager.
  bool resumeForPreparedSession(String expectedUid) {
    if (_disposed ||
        _pausedUid != expectedUid ||
        _currentUserId()?.trim() != expectedUid)
      return false;
    _pausedUid = null;
    _processingGeneration++;
    _scheduleRetry(expectedUid);
    return true;
  }

  bool _canProcess(String uid, int generation) =>
      !_disposed &&
      _pausedUid == null &&
      _processingGeneration == generation &&
      _currentUserId()?.trim() == uid;

  Future<bool> prepareForLocalDataDiscard() async {
    final initialUid = _currentUserId()?.trim();
    final store = _queueStore;
    if (_disposed ||
        initialUid == null ||
        initialUid.isEmpty ||
        store is! SyncQueueDiscardSafetyStore) {
      return false;
    }
    final safetyStore = store as SyncQueueDiscardSafetyStore;

    try {
      // Unresolved rejections block destructive cleanup, including later attempts.
      final hasRejected = await safetyStore.hasRejectedSyncItems(initialUid);
      if (_disposed || _currentUserId()?.trim() != initialUid || hasRejected) {
        return false;
      }

      if (!await processPendingItems() ||
          _disposed ||
          _currentUserId()?.trim() != initialUid) {
        return false;
      }

      final hasNewRejected = await safetyStore.hasRejectedSyncItems(initialUid);
      if (_disposed ||
          _currentUserId()?.trim() != initialUid ||
          hasNewRejected) {
        return false;
      }

      final pending = await store.getPendingSyncItems(initialUid);
      return !_disposed &&
          _currentUserId()?.trim() == initialUid &&
          pending.isEmpty;
    } catch (_) {
      AppLogger.w(
        'Não foi possível verificar o descarte seguro da fila de sync.',
      );
      return false;
    }
  }

  Future<bool> processPendingItems() {
    if (_disposed || _pausedUid != null) return Future.value(false);

    final currentUid = _currentUserId()?.trim();
    if (_recoveryUid != currentUid) _resetRecovery();
    if (currentUid == null ||
        currentUid.isEmpty ||
        (_retryUid != null && _retryUid != currentUid)) {
      _resetRetry();
    }

    final running = _processingFuture;

    if (running != null) {
      _processAgain = true;
      return running;
    }

    _retryTimer?.cancel();
    _retryTimer = null;

    final stop = Completer<void>();
    _processingStop = stop;
    late final Future<bool> operation;
    operation = _processPendingItems(_processingGeneration, stop.future)
        .whenComplete(() {
          if (identical(_processingFuture, operation)) {
            _processingFuture = null;
            _processingStop = null;
          }
        });
    _processingFuture = operation;
    return operation;
  }

  Future<bool> _processPendingItems(
    int generation,
    Future<void> stopped,
  ) async {
    final initialUid = _currentUserId()?.trim();

    if (initialUid == null || initialUid.isEmpty) {
      _resetRetry();
      return false;
    }

    try {
      try {
        await _queueStore.cleanupSucceededSyncItems(
          initialUid,
          DateTime.now().subtract(_succeededRetention).millisecondsSinceEpoch,
        );
      } catch (_) {
        AppLogger.w('Não foi possível concluir a manutenção da fila de sync.');
      }

      if (!_canProcess(initialUid, generation)) {
        _resetRetry();
        return false;
      }

      do {
        _processAgain = false;
        final pendingItems = await _queueStore.getPendingSyncItems(initialUid);
        if (!_canProcess(initialUid, generation)) return false;
        if (pendingItems.any(
          (item) =>
              item.ownerUid?.trim() == initialUid && item.attemptCount > 0,
        )) {
          _beginRecovery(initialUid);
        }

        for (final SyncQueueTableData item in pendingItems) {
          final currentUid = _currentUserId()?.trim();
          final ownerUid = item.ownerUid?.trim();

          if (!_canProcess(initialUid, generation)) {
            _resetRetry();
            return false;
          }

          if (ownerUid == null || ownerUid.isEmpty || ownerUid != currentUid) {
            continue;
          }

          SyncOperationResult result;

          try {
            // A session exit ends this loop without waiting for connectivity.
            // Future.any still observes a late remote error; the generation
            // check below prevents late acknowledgements or another send.
            result = await Future.any<SyncOperationResult>([
              _remoteDataSource.process(ownerUid, item),
              stopped.then(
                (_) => const SyncOperationResult.retryable(
                  code: 'SESSION_STOPPED',
                ),
              ),
            ]);
          } catch (_) {
            result = const SyncOperationResult.retryable(
              code: 'UNEXPECTED_SYNC_ERROR',
            );
          }

          if (!_canProcess(ownerUid, generation)) {
            _resetRetry();
            return false;
          }

          switch (result.status) {
            case SyncOperationStatus.success:
              if (_recoveryUid == ownerUid && !_recoveryResumed) {
                _emitUiEvent(SyncUiEventType.resumed, ownerUid);
                _recoveryResumed = true;
              }
              await _queueStore.markSyncItemAsSucceeded(item.id, ownerUid);
              break;

            case SyncOperationStatus.retryableError:
              _beginRecovery(ownerUid);
              final code = result.code ?? 'RETRYABLE_ERROR';
              AppLogger.w('Operação de sync mantida pendente: $code');
              await _queueStore.markSyncItemRetryableFailure(
                item.id,
                ownerUid,
                code,
              );
              _scheduleRetry(ownerUid);
              return false;

            case SyncOperationStatus.quotaExceeded:
            case SyncOperationStatus.permissionDenied:
            case SyncOperationStatus.invalidPayload:
            case SyncOperationStatus.unsupportedOperation:
              final code = result.code ?? 'SYNC_REJECTED';
              AppLogger.w('Operação de sync rejeitada: $code');
              await _queueStore.markSyncItemRejected(item.id, ownerUid, code);
          }
        }
        if (!_processAgain) await _maybeEmitRecoveryCompleted(initialUid);
      } while (_processAgain);
    } catch (_) {
      AppLogger.w('Falha inesperada ao processar a fila de sincronização.');
      return false;
    } finally {
      _processAgain = false;
    }

    final sameUser = _canProcess(initialUid, generation);
    _resetRetry();
    return sameUser;
  }

  void _beginRecovery(String uid) {
    if (_disposed ||
        _pausedUid != null ||
        _currentUserId()?.trim() != uid ||
        _recoveryUid == uid) {
      return;
    }
    _recoveryUid = uid;
    _recoveryResumed = false;
  }

  Future<void> _maybeEmitRecoveryCompleted(String uid) async {
    final store = _queueStore;
    if (_disposed ||
        _pausedUid != null ||
        _recoveryUid != uid ||
        !_recoveryResumed ||
        _currentUserId()?.trim() != uid ||
        store is! SyncQueueDiscardSafetyStore) {
      return;
    }
    try {
      final hasRejected = await (store as SyncQueueDiscardSafetyStore)
          .hasRejectedSyncItems(uid);
      if (_disposed ||
          _pausedUid != null ||
          _currentUserId()?.trim() != uid ||
          hasRejected)
        return;
      final pending = await store.getPendingSyncItems(uid);
      if (_disposed ||
          _currentUserId()?.trim() != uid ||
          _pausedUid != null ||
          _processAgain ||
          pending.isNotEmpty) {
        return;
      }
      _emitUiEvent(SyncUiEventType.recoveryCompleted, uid);
      _resetRecovery();
    } catch (_) {
      // Feedback failure must not change the queue's drain result.
      AppLogger.w('Não foi possível verificar a conclusão da sincronização.');
    }
  }

  void _emitUiEvent(SyncUiEventType type, String uid) {
    if (_disposed || _pausedUid != null || _currentUserId()?.trim() != uid)
      return;
    _uiEvents.add(SyncUiEvent(type: type, ownerUid: uid));
  }

  void _resetRecovery() {
    _recoveryUid = null;
    _recoveryResumed = false;
  }

  void _scheduleRetry(String uid) {
    if (_disposed || _pausedUid != null || _currentUserId()?.trim() != uid) {
      _resetRetry();
      return;
    }
    if (_retryUid != uid) {
      _retryAttempt = 0;
      _retryUid = uid;
    }
    _retryTimer?.cancel();
    final delay = _retryDelays[_retryAttempt];
    if (_retryAttempt < _retryDelays.length - 1) _retryAttempt++;
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      if (_disposed || _pausedUid != null || _currentUserId()?.trim() != uid) {
        _resetRetry();
        return;
      }
      unawaited(processPendingItems());
    });
  }

  void _resetRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _retryUid = null;
    _retryAttempt = 0;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _processingGeneration++;
    if (_processingStop?.isCompleted == false) _processingStop!.complete();
    _resetRetry();
    _resetRecovery();
    unawaited(_uiEvents.close());
  }
}
