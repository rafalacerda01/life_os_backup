import 'package:life_os/core/database/app_database.dart';

abstract interface class SyncQueueStore {
  Future<List<SyncQueueTableData>> getPendingSyncItems();

  Future<int> markSyncItemAsSynced(int id);
}

class AppDatabaseSyncQueueStore implements SyncQueueStore {
  final AppDatabase _db;

  const AppDatabaseSyncQueueStore(this._db);

  @override
  Future<List<SyncQueueTableData>> getPendingSyncItems() async {
    final items = await _db.getPendingSyncItems();

    return items.whereType<SyncQueueTableData>().toList(growable: false);
  }

  @override
  Future<int> markSyncItemAsSynced(int id) {
    return _db.markSyncItemAsSynced(id);
  }
}
