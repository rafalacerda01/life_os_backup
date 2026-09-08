// ignore_for_file: subtype_of_sealed_class

import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:life_os/core/database/app_database.dart';
import 'package:life_os/core/services/sync_manager.dart';
import 'package:life_os/core/services/sync_operation_result.dart';
import 'package:life_os/core/services/sync_queue_store.dart';
import 'package:life_os/core/services/sync_remote_data_source.dart';
import 'package:life_os/features/finance/data/repositories/finance_repository.dart';

class _FakeUser extends Fake implements User {
  @override
  String get uid => 'user-a';
}

class _FakeAuth extends Fake implements FirebaseAuth {
  @override
  User? get currentUser => _FakeUser();
}

class _FakeFirestore extends Fake implements FirebaseFirestore {}

class _NoopQueueStore implements SyncQueueStore {
  @override
  Future<List<SyncQueueTableData>> getPendingSyncItems(String ownerUid) async =>
      const [];

  @override
  Future<int> markSyncItemAsSucceeded(int id, String ownerUid) async => 0;

  @override
  Future<int> markSyncItemRejected(
    int id,
    String ownerUid,
    String errorCode,
  ) async => 0;

  @override
  Future<int> markSyncItemRetryableFailure(
    int id,
    String ownerUid,
    String errorCode,
  ) async => 0;
}

class _NoopRemoteDataSource implements SyncRemoteDataSource {
  @override
  Future<SyncOperationResult> process(
    String uid,
    SyncQueueTableData item,
  ) async {
    return const SyncOperationResult.success();
  }
}

class _FakeSyncManager extends SyncManager {
  int calls = 0;

  _FakeSyncManager()
    : super(
        queueStore: _NoopQueueStore(),
        remoteDataSource: _NoopRemoteDataSource(),
        currentUserId: () => 'user-a',
      );

  @override
  Future<bool> processPendingItems() async {
    calls += 1;
    return true;
  }
}

void main() {
  late AppDatabase db;
  late _FakeSyncManager syncManager;
  late FinanceRepository repository;

  setUp(() {
    db = AppDatabase(executor: NativeDatabase.memory());
    syncManager = _FakeSyncManager();
    repository = FinanceRepository(
      db,
      _FakeFirestore(),
      _FakeAuth(),
      syncManager,
    );
  });

  tearDown(() async {
    await db.closeDatabase();
  });

  test('addTransaction salva dados sanitizados e agenda sync', () async {
    await repository.addTransaction(
      title: '  <b>Salário</b>  ',
      amount: 2500.50,
      type: 'income',
      category: '  Trabalho  ',
    );

    final transactions = await db.select(db.transactions).get();
    final pending = await db.getPendingSyncItems('user-a');

    expect(transactions, hasLength(1));
    expect(transactions.single.title, 'Salário');
    expect(transactions.single.category, 'Trabalho');
    expect(transactions.single.amount, 2500.50);
    expect(transactions.single.type, 'income');
    expect(pending, hasLength(1));
    expect(pending.single.collection, 'transactions');
    expect(pending.single.operationType, 'create');
    expect(
      jsonDecode(pending.single.payloadJson),
      containsPair('category', 'Trabalho'),
    );
    expect(syncManager.calls, 1);
  });

  test('categoria personalizada permanece com o nome real', () async {
    await repository.addTransaction(
      title: 'Consulta',
      amount: 80,
      type: 'expense',
      category: 'Pet',
    );

    final transactions = await db.select(db.transactions).get();

    expect(transactions.single.category, 'Pet');
  });

  test('delete remoto cria SyncQueue e agenda sync', () async {
    final localId = await db
        .into(db.transactions)
        .insert(
          TransactionsCompanion.insert(
            firestoreId: const Value('remote-1'),
            title: 'Mercado',
            amount: 100,
            type: 'expense',
            category: 'Alimentação',
            date: DateTime(2026, 9, 7),
          ),
        );

    await repository.deleteTransaction(localId);

    final transactions = await db.select(db.transactions).get();
    final pending = await db.getPendingSyncItems('user-a');

    expect(transactions, isEmpty);
    expect(pending, hasLength(1));
    expect(pending.single.collection, 'transactions');
    expect(pending.single.docId, 'remote-1');
    expect(pending.single.operationType, 'delete');
    expect(syncManager.calls, 1);
  });

  test('delete local legado não cria SyncQueue nem agenda sync', () async {
    final localId = await db
        .into(db.transactions)
        .insert(
          TransactionsCompanion.insert(
            firestoreId: const Value('pending'),
            title: 'Local',
            amount: 10,
            type: 'expense',
            category: 'Outros',
            date: DateTime(2026, 9, 7),
          ),
        );

    await repository.deleteTransaction(localId);

    expect(await db.select(db.transactions).get(), isEmpty);
    expect(await db.getPendingSyncItems('user-a'), isEmpty);
    expect(syncManager.calls, 0);
  });

  final invalidCases =
      <
        ({
          String name,
          String title,
          double amount,
          String type,
          String category,
        })
      >[
        (
          name: 'title vazio',
          title: '  ',
          amount: 10,
          type: 'expense',
          category: 'Lazer',
        ),
        (
          name: 'title acima de 200',
          title: List.filled(201, 'a').join(),
          amount: 10,
          type: 'expense',
          category: 'Lazer',
        ),
        (
          name: 'categoria vazia',
          title: 'Teste',
          amount: 10,
          type: 'expense',
          category: '  ',
        ),
        (
          name: 'categoria acima de 100',
          title: 'Teste',
          amount: 10,
          type: 'expense',
          category: List.filled(101, 'a').join(),
        ),
        (
          name: 'valor zero',
          title: 'Teste',
          amount: 0,
          type: 'expense',
          category: 'Lazer',
        ),
        (
          name: 'valor negativo',
          title: 'Teste',
          amount: -1,
          type: 'expense',
          category: 'Lazer',
        ),
        (
          name: 'valor acima do limite',
          title: 'Teste',
          amount: 1000000000.01,
          type: 'expense',
          category: 'Lazer',
        ),
        (
          name: 'valor NaN',
          title: 'Teste',
          amount: double.nan,
          type: 'expense',
          category: 'Lazer',
        ),
        (
          name: 'valor infinito',
          title: 'Teste',
          amount: double.infinity,
          type: 'expense',
          category: 'Lazer',
        ),
        (
          name: 'tipo inválido',
          title: 'Teste',
          amount: 10,
          type: 'unknown',
          category: 'Lazer',
        ),
      ];

  for (final invalidCase in invalidCases) {
    test('${invalidCase.name} falha antes de Drift e SyncQueue', () async {
      await expectLater(
        repository.addTransaction(
          title: invalidCase.title,
          amount: invalidCase.amount,
          type: invalidCase.type,
          category: invalidCase.category,
        ),
        throwsArgumentError,
      );

      expect(await db.select(db.transactions).get(), isEmpty);
      expect(await db.getPendingSyncItems('user-a'), isEmpty);
      expect(syncManager.calls, 0);
    });
  }
}
