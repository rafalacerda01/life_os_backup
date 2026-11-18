import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/database/database_provider.dart';
import 'package:life_os/core/database/database_sync_policy.dart';
import 'package:life_os/core/database/local_database_identity.dart';
import 'package:life_os/core/database/local_mutation_gate.dart';
import 'package:life_os/core/services/firebase_auth_provider.dart';
import 'package:life_os/core/services/sync_manager_provider.dart';
import 'package:life_os/features/finance/data/repositories/finance_repository.dart';
import 'package:life_os/features/finance/presentation/providers/finance_provider.dart';
import 'package:life_os/features/premium/domain/services/quota_service.dart';

void main() {
  const uid = 'local-v1-123e4567-e89b-42d3-a456-426614174000';
  late AppDatabase db;
  late FinanceRepository repository;
  setUp(() {
    db = AppDatabase.forUser(
      identity: LocalDatabaseIdentity(uid),
      executor: NativeDatabase.memory(),
      syncPolicy: DatabaseSyncPolicy.localOnly,
    );
    repository = FinanceRepository.local(db);
  });
  tearDown(() => db.close());
  Future<void> add(
    String title, {
    double amount = 20,
    String type = 'expense',
  }) => repository.addTransaction(
    title: title,
    amount: amount,
    type: type,
    category: 'Outros',
  );

  test(
    'income, expense, summary and deletion work without a Firebase user',
    () async {
      final stream = StreamIterator(db.select(db.transactions).watch());
      try {
        expect(await stream.moveNext(), true);
        expect(stream.current, isEmpty);
        await add('  Receita local  ', amount: 100.5, type: 'income');
        expect(await stream.moveNext(), true);
        expect(stream.current.single.title, 'Receita local');
        await add('Despesa local', amount: 25.5);
        expect(await stream.moveNext(), true);
        final summary = calculateFinanceSummary(stream.current);
        expect(summary.income, 100.5);
        expect(summary.expense, 25.5);
        expect(summary.balance, 75);
        await repository.deleteTransaction(stream.current.first.id);
        expect(await stream.moveNext(), true);
        expect(stream.current.single.title, 'Despesa local');
        expect(await db.select(db.syncQueueTable).get(), isEmpty);
      } finally {
        await stream.cancel();
      }
    },
  );

  test(
    'provider never constructs Auth, Firestore, remote sync or account custody',
    () async {
      var remoteReads = 0;
      Never remote() {
        remoteReads++;
        throw StateError('REMOTE_MUST_NOT_BE_READ');
      }

      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          firebaseAuthProvider.overrideWith((ref) => remote()),
          firebaseFirestoreProvider.overrideWith((ref) => remote()),
          syncManagerProvider.overrideWith((ref) => remote()),
        ],
      );
      try {
        final local = container.read(financeRepositoryProvider);
        await local.addTransaction(
          title: 'provider-local',
          amount: 5,
          type: 'expense',
          category: 'Outros',
        );
        await local.syncTransactionsFromFirestore();
        final row = (await db.select(db.transactions).get()).single;
        await local.deleteTransaction(row.id);
        expect(await db.select(db.transactions).get(), isEmpty);
        expect(await db.select(db.syncQueueTable).get(), isEmpty);
        expect(remoteReads, 0);
      } finally {
        container.dispose();
      }
    },
  );

  test('legacy remote pull is inert for local storage', () async {
    await add('preserved');
    final before = await db.select(db.transactions).get();
    await repository.syncTransactionsFromFirestore();
    expect(await db.select(db.transactions).get(), before);
    expect(await db.select(db.syncQueueTable).get(), isEmpty);
  });

  test('Free quota is atomic and deletion releases one slot', () async {
    await add('one');
    await add('two');
    await add('three');
    await expectLater(add('forbidden'), throwsA(isA<PlanQuotaExceeded>()));
    final row = (await db.select(db.transactions).get()).first;
    await repository.deleteTransaction(row.id);
    await add('replacement');
    expect((await db.select(db.transactions).get()).length, 3);
    expect(await db.select(db.syncQueueTable).get(), isEmpty);
  });

  test(
    'eight concurrent local creates commit exactly three transactions',
    () async {
      final results = await Future.wait(
        List.generate(8, (index) async {
          try {
            await add('concurrent-$index');
            return true;
          } on PlanQuotaExceeded {
            return false;
          }
        }),
      );
      expect(results.where((value) => value).length, 3);
      expect((await db.select(db.transactions).get()).length, 3);
      expect(await db.select(db.syncQueueTable).get(), isEmpty);
    },
  );

  test(
    'invalid amounts and types cannot mutate local financial history',
    () async {
      for (final amount in [
        0.0,
        -1.0,
        double.nan,
        double.infinity,
        1000000001.0,
      ]) {
        await expectLater(add('invalid', amount: amount), throwsArgumentError);
      }
      await expectLater(add('invalid', type: 'other'), throwsArgumentError);
      await expectLater(add('   '), throwsArgumentError);
      expect(await db.select(db.transactions).get(), isEmpty);
      expect(await db.select(db.syncQueueTable).get(), isEmpty);
    },
  );

  test('detached local session refuses late financial mutations', () async {
    String? current = uid;
    db.localMutations.bindSessionReader(() => current);
    db.localMutations.openPreparedSession();
    await add('preserved');
    final before = await db.select(db.transactions).get();
    current = null;
    db.localMutations.observeSession(null);
    await expectLater(add('late'), throwsA(isA<LocalMutationUnavailable>()));
    await expectLater(
      repository.deleteTransaction(before.single.id),
      throwsA(isA<LocalMutationUnavailable>()),
    );
    await expectLater(
      db.select(db.transactions).get(),
      throwsA(isA<LocalMutationUnavailable>()),
    );
    current = uid;
    db.localMutations.openPreparedSession();
    expect(await db.select(db.transactions).get(), before);
  });

  test('local constructor refuses a remote-enabled connection', () async {
    final remote = AppDatabase(executor: NativeDatabase.memory());
    try {
      expect(() => FinanceRepository.local(remote), throwsArgumentError);
    } finally {
      await remote.close();
    }
  });
}
