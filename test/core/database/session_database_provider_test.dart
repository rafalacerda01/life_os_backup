import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/database_provider.dart';
import 'package:life_os/core/database/local_mutation_gate.dart';
import 'package:life_os/core/database/session_database_coordinator.dart';
import 'package:life_os/core/services/firebase_auth_provider.dart';

import '../../helpers/test_user_database_factory.dart';

class _User extends Fake implements User {
  _User(this.uid);
  @override
  final String uid;
}

class _Auth extends Fake implements FirebaseAuth {
  User? user;
  @override
  User? get currentUser => user;
}

void main() {
  test(
    'late producer cannot read databaseProvider and acquire B authority',
    () async {
      final auth = _Auth()..user = _User('a');
      final factory = TestUserDatabaseFactory();
      final container = ProviderContainer(
        overrides: [
          firebaseAuthProvider.overrideWithValue(auth),
          userDatabaseFactoryProvider.overrideWithValue(factory),
        ],
      );
      final coordinator = container.read(sessionDatabaseCoordinatorProvider);
      try {
        final a = await coordinator.prepare('a');
        final release = Completer<void>();
        late Future<void> lateRead;
        await a.localMutations.run(() async {
          lateRead = release.future.then((_) {
            container.read(databaseProvider).localMutations.capture();
          });
        });
        auth.user = _User('b');
        coordinator.observeSession('b');
        final b = await coordinator.prepare('b');
        expect(container.read(databaseProvider), same(b));
        final rejected = expectLater(
          lateRead,
          throwsA(isA<LocalMutationUnavailable>()),
        );
        release.complete();
        await rejected;
        expect(await b.select(b.taskTable).get(), isEmpty);
      } finally {
        container.dispose();
        await coordinator.dispose();
        await factory.dispose();
      }
    },
  );

  test(
    'DB dependent provider disposes A and rebuilds exclusively for B',
    () async {
      final auth = _Auth()..user = _User('a');
      final factory = TestUserDatabaseFactory();
      final disposed = <String>[];
      final ownerProvider = Provider<String>((ref) {
        final db = ref.watch(databaseProvider);
        ref.onDispose(() => disposed.add(db.identity!.uid));
        return db.identity!.uid;
      });
      final container = ProviderContainer(
        overrides: [
          firebaseAuthProvider.overrideWithValue(auth),
          userDatabaseFactoryProvider.overrideWithValue(factory),
        ],
      );
      final coordinator = container.read(sessionDatabaseCoordinatorProvider);
      try {
        await coordinator.prepare('a');
        expect(container.read(ownerProvider), 'a');
        auth.user = _User('b');
        coordinator.observeSession('b');
        await coordinator.prepare('b');
        expect(container.read(ownerProvider), 'b');
        expect(disposed, ['a']);
        expect(factory.databases.first.closed, isTrue);
      } finally {
        container.dispose();
        await coordinator.dispose();
        await factory.dispose();
      }
    },
  );

  test(
    'provider is unavailable signed out, publishes A, invalidates for B',
    () async {
      final auth = _Auth();
      final factory = TestUserDatabaseFactory();
      final container = ProviderContainer(
        overrides: [
          firebaseAuthProvider.overrideWithValue(auth),
          userDatabaseFactoryProvider.overrideWithValue(factory),
        ],
      );
      final coordinator = container.read(sessionDatabaseCoordinatorProvider);
      try {
        expect(() => container.read(databaseProvider), throwsA(anything));
        expect(factory.openedUserIds, isEmpty);
        auth.user = _User('a');
        final a = await coordinator.prepare('a');
        expect(container.read(databaseProvider), same(a));
        final generations = <String?>[];
        final sub = container.listen(
          databaseProvider,
          (_, next) => generations.add(next.identity?.uid),
        );
        auth.user = _User('b');
        coordinator.observeSession('b');
        expect(
          coordinator.requirePrepared,
          throwsA(isA<SessionDatabaseUnavailable>()),
        );
        final b = await coordinator.prepare('b');
        expect(container.read(databaseProvider), same(b));
        expect(factory.openedUserIds, ['a', 'b']);
        expect(factory.databases.first.closed, isTrue);
        sub.close();
      } finally {
        container.dispose();
        await coordinator.dispose();
        await factory.dispose();
      }
    },
  );
}
