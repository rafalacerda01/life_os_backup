import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/core/db/user_db_key_manager.dart';
import 'package:life_os/core/services/firebase_auth_provider.dart';

import 'app_database.dart';
import 'session_database_coordinator.dart';
import 'user_database_factory.dart';

final userDatabaseFactoryProvider = Provider<UserDatabaseFactory>((ref) {
  return UserDatabaseFactory();
});

class SessionDatabaseNotifier extends Notifier<SessionDatabaseSnapshot> {
  late final SessionDatabaseCoordinator coordinator;

  @override
  SessionDatabaseSnapshot build() {
    final auth = ref.read(firebaseAuthProvider);
    coordinator = SessionDatabaseCoordinator(
      currentUserId: () => auth.currentUser?.uid,
      openDatabase: ref.read(userDatabaseFactoryProvider).open,
      clearKeyCache: UserDbKeyManager.instance.clearCache,
      onChanged: (snapshot) {
        if (ref.mounted) state = snapshot;
      },
    );
    ref.onDispose(() {
      unawaited(coordinator.dispose().catchError((Object _) {}));
    });
    return coordinator.snapshot;
  }
}

final sessionDatabaseStateProvider =
    NotifierProvider<SessionDatabaseNotifier, SessionDatabaseSnapshot>(
      SessionDatabaseNotifier.new,
    );

final sessionDatabaseCoordinatorProvider = Provider<SessionDatabaseCoordinator>(
  (ref) => ref.watch(sessionDatabaseStateProvider.notifier).coordinator,
);

/// Only an explicitly prepared database is available; never opens legacy.
final databaseProvider = Provider<AppDatabase>((ref) {
  ref.watch(sessionDatabaseStateProvider);
  return ref.read(sessionDatabaseCoordinatorProvider).requirePrepared();
});
