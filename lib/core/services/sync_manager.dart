import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/utils/app_logger.dart';

import 'sync_operation_result.dart';
import 'sync_queue_store.dart';
import 'sync_remote_data_source.dart';

class SyncManager {
  final SyncQueueStore _queueStore;
  final SyncRemoteDataSource _remoteDataSource;
  final String? Function() _currentUserId;

  bool _isProcessing = false;
  bool _processAgain = false;

  SyncManager({
    required this._queueStore,
    required this._remoteDataSource,
    required this._currentUserId,
  });

  Future<void> processPendingItems() async {
    if (_isProcessing) {
      _processAgain = true;
      return;
    }

    final uid = _currentUserId();

    if (uid == null || uid.trim().isEmpty) {
      return;
    }

    _isProcessing = true;

    try {
      do {
        _processAgain = false;
        final pendingItems = await _queueStore.getPendingSyncItems();

        for (final SyncQueueTableData item in pendingItems) {
          final currentUid = _currentUserId();

          if (currentUid == null || currentUid != uid) {
            return;
          }

          final result = await _remoteDataSource.process(uid, item);

          switch (result.status) {
            case SyncOperationStatus.success:
              await _queueStore.markSyncItemAsSynced(item.id);
              break;

            case SyncOperationStatus.retryableError:
              AppLogger.w(
                'Operação de sync mantida pendente '
                '${item.collection}/${item.docId}: '
                '${result.code ?? 'RETRYABLE_ERROR'}',
              );
              return;

            case SyncOperationStatus.quotaExceeded:
            case SyncOperationStatus.permissionDenied:
            case SyncOperationStatus.invalidPayload:
            case SyncOperationStatus.unsupportedOperation:
              AppLogger.w(
                'Operação de sync rejeitada '
                '${item.collection}/${item.docId}: '
                '${result.code ?? 'SYNC_REJECTED'}',
              );
              await _queueStore.markSyncItemAsSynced(item.id);
              continue;
          }
        }
      } while (_processAgain);
    } catch (error, stackTrace) {
      AppLogger.e(
        'Erro geral ao processar fila de sincronização.',
        error,
        stackTrace,
      );
    } finally {
      _isProcessing = false;
      _processAgain = false;
    }
  }
}
