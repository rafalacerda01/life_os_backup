import 'package:life_os/features/notifications/data/repositories/notification_remote_effects_barrier.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:life_os/core/database/database_provider.dart';
import 'package:life_os/core/services/sync_manager.dart';
import 'package:life_os/core/services/sync_queue_store.dart';
import 'package:life_os/core/services/sync_remote_data_source.dart';
import 'package:life_os/core/services/sync_ui_event.dart';
import 'package:life_os/features/auth/presentation/providers/auth_provider.dart';

final syncManagerProvider = Provider<SyncManager>((ref) {
  final database = ref.watch(databaseProvider);

  final firestore = ref.watch(firestoreProvider);

  final auth = ref.watch(firebaseAuthProvider);

  final manager = SyncManager(
    queueStore: AppDatabaseSyncQueueStore(database),
    remoteDataSource: FirestoreSyncRemoteDataSource(
      firestore,
      auth,
      beforeNotificationDelete: () =>
          ref.read(notificationRemoteEffectsBarrierProvider).drainCurrent(),
    ),
    currentUserId: () => auth.currentUser?.uid,
  );
  ref.onDispose(manager.dispose);
  return manager;
});

final syncUiEventsProvider = StreamProvider<SyncUiEvent>((ref) {
  return ref.watch(syncManagerProvider).uiEvents;
});
