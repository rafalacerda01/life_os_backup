import 'package:life_os/features/auth/data/repositories/auth_repository_impl.dart';
import 'package:life_os/features/auth/data/remote/account_remote_data_source.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/services/sync_remote_data_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/services/trusted_account_access.dart';
import 'package:life_os/core/database/local_database_identity.dart';

class _NoAuthIO implements FirebaseAuth {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('AUTH_IO_REFUSED');
}

class _NoFirestoreIO implements FirebaseFirestore {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('FIRESTORE_IO_REFUSED');
}

class _NoAccountIO implements AccountRemoteDataSource {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('ACCOUNT_IO_REFUSED');
}

void main() {
  const generation = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  const next = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
  final receipt = <String, dynamic>{
    'version': 1,
    'projectId': 'demo-life-os',
    'databaseId': '(default)',
    'uid': 'A',
    'generation': generation,
    'policy': 'AUTH_BLOCKING_GENESIS_V1',
    'state': 'ACTIVE',
  };
  test(
    'receipt matching is consistency only, not server cleanup authority',
    () {
      expect(
        TrustedAccountAccess.matchesReceipt(
          receipt,
          'demo-life-os',
          'A',
          generation,
        ),
        isTrue,
      );
      expect(
        TrustedAccountAccess.matchesReceipt(
          null,
          'demo-life-os',
          'A',
          generation,
        ),
        isFalse,
      );
    },
  );
  for (final state in [
    'RESERVED',
    'DELETING',
    'RETIRED',
    'REVIEW_REQUIRED',
    'COMPLETE',
  ]) {
    test('no remote hydration grant for $state', () {
      expect(
        TrustedAccountAccess.matchesReceipt(
          {...receipt, 'state': state},
          'demo-life-os',
          'A',
          generation,
        ),
        isFalse,
      );
    });
  }
  for (final mismatch in [
    <String, dynamic>{'projectId': 'other-project'},
    <String, dynamic>{'databaseId': 'foreign'},
    <String, dynamic>{'uid': 'B'},
    <String, dynamic>{'generation': next},
    <String, dynamic>{'policy': 'client-asserted'},
  ]) {
    test('receipt mismatch $mismatch cannot adopt a cached profile', () {
      expect(
        TrustedAccountAccess.matchesReceipt(
          {...receipt, ...mismatch},
          'demo-life-os',
          'A',
          generation,
        ),
        isFalse,
      );
    });
  }
  test('email, timestamp, UID and a boolean are not a receipt', () {
    expect(
      TrustedAccountAccess.matchesReceipt(
        {
          'uid': 'A',
          'email': 'same@example.invalid',
          'createdAt': 100,
          'eligible': true,
        },
        'demo-life-os',
        'A',
        generation,
      ),
      isFalse,
    );
  });
  test(
    'same UID has separate Drift files and keys for separate generations',
    () {
      final old = LocalDatabaseIdentity('A');
      final a = LocalDatabaseIdentity('A', generation: generation);
      final b = LocalDatabaseIdentity('A', generation: next);
      expect({old.fileName, a.fileName, b.fileName}.length, 3);
      expect({old.keyAlias, a.keyAlias, b.keyAlias}.length, 3);
      expect(a, isNot(b));
      expect(a, LocalDatabaseIdentity('A', generation: generation));
    },
  );
  test('malformed generation cannot create a new Drift namespace', () {
    for (final value in ['', '../old', '-' * 36, 'a' * 36]) {
      expect(
        () => LocalDatabaseIdentity('A', generation: value),
        throwsArgumentError,
      );
    }
  });

  test(
    'CLOSED cohort never sends queued work, reads SDK, or fabricates ACK',
    () async {
      expect(TrustedAccountAccess.localSessionClosed, isTrue);
      final remote = FirestoreSyncRemoteDataSource(
        _NoFirestoreIO(),
        _NoAuthIO(),
        clientFactory: () => throw StateError('HTTP_IO_REFUSED'),
      );
      final item = SyncQueueTableData(
        id: 1,
        ownerUid: 'A',
        collection: 'notes',
        docId: 'old-generation',
        operationType: 'update',
        payloadJson: '{"text":"private"}',
        createdAt: 0,
        isSynced: false,
        status: 'pending',
        attemptCount: 0,
      );
      final result = await remote.process('A', item);
      expect(result.isSuccess, isFalse);
      expect(result.shouldRetry, isTrue);
      expect(result.code, 'TRUSTED_LOCAL_SESSION_CLOSED');
    },
  );

  test(
    'CLOSED client entry cannot create Auth, log in, hydrate or delete',
    () async {
      final repository = AuthRepositoryImpl(
        _NoAuthIO(),
        _NoFirestoreIO(),
        _NoAccountIO(),
      );
      final results = [
        await repository.signInWithEmailAndPassword(
          'synthetic@example.invalid',
          'synthetic',
        ),
        await repository.signUpWithEmailAndPassword(
          'synthetic@example.invalid',
          'synthetic',
          'Synthetic',
        ),
        await repository.signInWithGoogle(),
        await repository.getCurrentUser(),
        await repository.deleteAccount(expectedUid: 'A'),
      ];
      for (final result in results) {
        result.when(
          (_) => fail('Closed entry must never succeed'),
          (failure) => expect(failure.code, 'TRUSTED_LOCAL_SESSION_CLOSED'),
        );
      }
    },
  );
}
