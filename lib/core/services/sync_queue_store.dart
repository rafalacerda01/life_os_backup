import 'package:life_os/core/database/app_database.dart';

abstract interface class SyncQueueStore {
  Future<List<SyncQueueTableData>> getPendingSyncItems(String ownerUid);

  Future<int> markSyncItemAsSucceeded(int id, String ownerUid);

  Future<int> markSyncItemRetryableFailure(
    int id,
    String ownerUid,
    String errorCode,
  );

  Future<int> markSyncItemRejected(int id, String ownerUid, String errorCode);
}

class AppDatabaseSyncQueueStore implements SyncQueueStore {
  final AppDatabase _db;

  const AppDatabaseSyncQueueStore(this._db);

  @override
  Future<List<SyncQueueTableData>> getPendingSyncItems(String ownerUid) async {
    final items = await _db.getPendingSyncItems(ownerUid);

    return items.whereType<SyncQueueTableData>().toList(growable: false);
  }

  @override
  Future<int> markSyncItemAsSucceeded(int id, String ownerUid) {
    return _db.markSyncItemAsSucceeded(id, ownerUid);
  }

  @override
  Future<int> markSyncItemRetryableFailure(
    int id,
    String ownerUid,
    String errorCode,
  ) {
    return _db.markSyncItemRetryableFailure(id, ownerUid, errorCode);
  }

  @override
  Future<int> markSyncItemRejected(int id, String ownerUid, String errorCode) {
    return _db.markSyncItemRejected(id, ownerUid, errorCode);
  }
}
