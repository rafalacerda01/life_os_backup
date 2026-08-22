import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/utils/app_logger.dart';

import 'sync_operation_result.dart';
import 'sync_queue_store.dart';
import 'sync_remote_data_source.dart';

class SyncManager {
  final SyncQueueStore _queueStore;
  final SyncRemoteDataSource _remoteDataSource;
  final String? Function() _currentUserId;

  Future<bool>? _processingFuture;
  bool _processAgain = false;

  SyncManager({
    required this._queueStore,
    required this._remoteDataSource,
    required this._currentUserId,
  });

  Future<bool> processPendingItems() {
    final running = _processingFuture;

    if (running != null) {
      _processAgain = true;
      return running;
    }

    late final Future<bool> operation;
    operation = _processPendingItems().whenComplete(() {
      if (identical(_processingFuture, operation)) {
        _processingFuture = null;
      }
    });
    _processingFuture = operation;
    return operation;
  }

  Future<bool> _processPendingItems() async {
    final initialUid = _currentUserId()?.trim();

    if (initialUid == null || initialUid.isEmpty) {
      return false;
    }

    try {
      do {
        _processAgain = false;
        final pendingItems = await _queueStore.getPendingSyncItems(initialUid);

        for (final SyncQueueTableData item in pendingItems) {
          final currentUid = _currentUserId()?.trim();
          final ownerUid = item.ownerUid?.trim();

          if (currentUid == null || currentUid != initialUid) {
            return false;
          }

          if (ownerUid == null || ownerUid.isEmpty || ownerUid != currentUid) {
            continue;
          }

          SyncOperationResult result;

          try {
            result = await _remoteDataSource.process(ownerUid, item);
          } catch (_) {
            result = const SyncOperationResult.retryable(
              code: 'UNEXPECTED_SYNC_ERROR',
            );
          }

          if (_currentUserId()?.trim() != ownerUid) {
            return false;
          }

          switch (result.status) {
            case SyncOperationStatus.success:
              await _queueStore.markSyncItemAsSucceeded(item.id, ownerUid);
              break;

            case SyncOperationStatus.retryableError:
              final code = result.code ?? 'RETRYABLE_ERROR';
              AppLogger.w('Operação de sync mantida pendente: $code');
              await _queueStore.markSyncItemRetryableFailure(
                item.id,
                ownerUid,
                code,
              );
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
      } while (_processAgain);
    } catch (_) {
      AppLogger.w('Falha inesperada ao processar a fila de sincronização.');
      return false;
    } finally {
      _processAgain = false;
    }

    return _currentUserId()?.trim() == initialUid;
  }
}
