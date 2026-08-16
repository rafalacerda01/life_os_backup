import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:life_os/core/database/database_provider.dart';
import 'package:life_os/core/services/sync_manager.dart';
import 'package:life_os/core/services/sync_queue_store.dart';
import 'package:life_os/core/services/sync_remote_data_source.dart';
import 'package:life_os/features/auth/presentation/providers/auth_provider.dart';

final syncManagerProvider = Provider<SyncManager>((ref) {
  final database = ref.watch(databaseProvider);

  final firestore = ref.watch(firestoreProvider);

  final auth = ref.watch(firebaseAuthProvider);

  return SyncManager(
    queueStore: AppDatabaseSyncQueueStore(database),
    remoteDataSource: FirestoreSyncRemoteDataSource(firestore, auth),
    currentUserId: () => auth.currentUser?.uid,
  );
});
