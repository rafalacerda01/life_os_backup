// ignore_for_file: subtype_of_sealed_class

import 'dart:async';
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
  final String uid;

  _FakeUser(this.uid);
}

class _FakeAuth extends Fake implements FirebaseAuth {
  @override
  User? currentUser = _FakeUser('user-a');
}

class _FakeDocument extends Fake
    implements QueryDocumentSnapshot<Map<String, dynamic>> {
  final String documentId;
  final Map<String, dynamic> values;

  _FakeDocument(this.documentId, this.values);

  @override
  String get id => documentId;

  @override
  Map<String, dynamic> data() => Map<String, dynamic>.from(values);
}

class _FakeSnapshot extends Fake
    implements QuerySnapshot<Map<String, dynamic>> {
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> documents;

  _FakeSnapshot(this.documents);

  @override
  List<QueryDocumentSnapshot<Map<String, dynamic>>> get docs => documents;
}

// ignore: must_be_immutable
class _FakeCollection extends Fake
    implements CollectionReference<Map<String, dynamic>> {
  List<QueryDocumentSnapshot<Map<String, dynamic>>> documents = [];
  Future<void> Function()? beforeGet;
  int getCalls = 0;
  GetOptions? lastGetOptions;

  @override
  DocumentReference<Map<String, dynamic>> doc([String? path]) {
    expect(path, 'user-a');
    return _FakeUserDocument(this);
  }

  @override
  Future<QuerySnapshot<Map<String, dynamic>>> get([GetOptions? options]) async {
    getCalls += 1;
    lastGetOptions = options;
    await beforeGet?.call();
    return _FakeSnapshot(documents);
  }
}

class _FakeUserDocument extends Fake
    implements DocumentReference<Map<String, dynamic>> {
  final _FakeCollection transactions;

  _FakeUserDocument(this.transactions);

  @override
  CollectionReference<Map<String, dynamic>> collection(String path) {
    expect(path, 'transactions');
    return transactions;
  }
}

class _FakeFirestore extends Fake implements FirebaseFirestore {
  final transactions = _FakeCollection();

  @override
  CollectionReference<Map<String, dynamic>> collection(String path) {
    expect(path, 'users');
    return transactions;
  }
}

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
  bool shouldDrain = true;
  Future<void> Function()? duringDrain;

  _FakeSyncManager()
    : super(
        queueStore: _NoopQueueStore(),
        remoteDataSource: _NoopRemoteDataSource(),
        currentUserId: () => 'user-a',
      );

  @override
  Future<bool> processPendingItems() async {
    calls += 1;
    await duringDrain?.call();
    return shouldDrain;
  }
}

void main() {
  late AppDatabase db;
  late _FakeAuth auth;
  late _FakeFirestore firestore;
  late _FakeSyncManager syncManager;
  late FinanceRepository repository;

  setUp(() {
    db = AppDatabase(executor: NativeDatabase.memory());
    auth = _FakeAuth();
    firestore = _FakeFirestore();
    syncManager = _FakeSyncManager();
    repository = FinanceRepository(db, firestore, auth, syncManager);
  });

  tearDown(() async {
    await db.closeDatabase();
  });

  Map<String, dynamic> validRemoteData({
    String title = 'Remota',
    double amount = 42.5,
    String type = 'expense',
    String category = 'Pet',
    Object? date,
  }) {
    return {
      'title': title,
      'amount': amount,
      'type': type,
      'category': category,
      'date': date ?? Timestamp.fromDate(DateTime.utc(2026, 9, 8)),
    };
  }

  Future<int> seedLocal({
    String? firestoreId = 'remote-1',
    String title = 'Local',
  }) {
    return db
        .into(db.transactions)
        .insert(
          TransactionsCompanion.insert(
            firestoreId: Value(firestoreId),
            title: title,
            amount: 10,
            type: 'expense',
            category: 'Outros',
            date: DateTime.utc(2026, 9, 1),
          ),
        );
  }

  Future<int> enqueue({
    required String docId,
    required String operationType,
    int? createdAt,
  }) {
    return db.insertSyncItem(
      ownerUid: 'user-a',
      collection: 'transactions',
      docId: docId,
      operationType: operationType,
      payloadJson: jsonEncode({'transactionId': docId}),
      createdAt: createdAt,
    );
  }

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

  test('fila não drenada impede GET e preserva o estado local', () async {
    await seedLocal();
    syncManager.shouldDrain = false;
    firestore.transactions.documents = [
      _FakeDocument('remote-1', validRemoteData()),
    ];

    await repository.syncTransactionsFromFirestore();

    expect(syncManager.calls, 1);
    expect(firestore.transactions.getCalls, 0);
    expect((await db.select(db.transactions).getSingle()).title, 'Local');
  });

  test('falha no GET preserva dados locais e não propaga para UI', () async {
    await seedLocal();
    firestore.transactions.beforeGet = () async {
      throw StateError('falha privada de transporte');
    };

    await repository.syncTransactionsFromFirestore();

    expect(firestore.transactions.getCalls, 1);
    expect((await db.select(db.transactions).getSingle()).title, 'Local');
  });

  test('GET de transactions exige exclusivamente Source.server', () async {
    await repository.syncTransactionsFromFirestore();

    expect(firestore.transactions.getCalls, 1);
    expect(firestore.transactions.lastGetOptions?.source, Source.server);
  });

  test(
    'snapshot válido hidrata banco local vazio sem fabricar dados',
    () async {
      firestore.transactions.documents = [
        _FakeDocument(
          'remote-1',
          validRemoteData(
            title: '  <b>Consulta</b>  ',
            amount: 89.9,
            type: 'expense',
            category: '  Pet  ',
            date: '2026-09-02T15:30:00.000Z',
          ),
        ),
      ];

      await repository.syncTransactionsFromFirestore();

      final transaction = await db.select(db.transactions).getSingle();
      expect(transaction.firestoreId, 'remote-1');
      expect(transaction.title, 'Consulta');
      expect(transaction.amount, 89.9);
      expect(transaction.type, 'expense');
      expect(transaction.category, 'Pet');
      expect(
        transaction.date.isAtSameMomentAs(
          DateTime.parse('2026-09-02T15:30:00.000Z'),
        ),
        isTrue,
      );
    },
  );

  test('snapshot atualiza o mesmo id local sem duplicar', () async {
    final localId = await seedLocal();
    firestore.transactions.documents = [
      _FakeDocument(
        'remote-1',
        validRemoteData(
          title: 'Canônico',
          amount: 120,
          type: 'income',
          category: 'Freelance',
          date: DateTime.utc(2026, 9, 3),
        ),
      ),
    ];

    await repository.syncTransactionsFromFirestore();

    final transactions = await db.select(db.transactions).get();
    expect(transactions, hasLength(1));
    expect(transactions.single.id, localId);
    expect(transactions.single.title, 'Canônico');
    expect(transactions.single.amount, 120);
    expect(transactions.single.type, 'income');
    expect(transactions.single.category, 'Freelance');
    expect(
      transactions.single.date.isAtSameMomentAs(DateTime.utc(2026, 9, 3)),
      isTrue,
    );
    expect(transactions.single.isDeleted, isFalse);
  });

  final invalidRemoteCases = <({String name, Map<String, dynamic> data})>[
    (
      name: 'amount zero',
      data: {
        'title': 'Inválida',
        'amount': 0,
        'type': 'expense',
        'category': 'Outros',
        'date': Timestamp.fromDate(DateTime.utc(2026, 9, 1)),
      },
    ),
    (
      name: 'tipo desconhecido',
      data: {
        'title': 'Inválida',
        'amount': 10,
        'type': 'unknown',
        'category': 'Outros',
        'date': Timestamp.fromDate(DateTime.utc(2026, 9, 1)),
      },
    ),
    (
      name: 'data inválida',
      data: {
        'title': 'Inválida',
        'amount': 10,
        'type': 'expense',
        'category': 'Outros',
        'date': 'não-é-data',
      },
    ),
  ];

  for (final invalidCase in invalidRemoteCases) {
    test('payload remoto inválido (${invalidCase.name}) é ignorado', () async {
      firestore.transactions.documents = [
        _FakeDocument('invalid-1', invalidCase.data),
      ];

      await repository.syncTransactionsFromFirestore();

      expect(await db.select(db.transactions).get(), isEmpty);
    });
  }

  test('documento remoto inválido conta como presente no snapshot', () async {
    final localId = await seedLocal();
    firestore.transactions.documents = [
      _FakeDocument('remote-1', invalidRemoteCases.first.data),
    ];

    await repository.syncTransactionsFromFirestore();

    final transaction = await db.select(db.transactions).getSingle();
    expect(transaction.id, localId);
    expect(transaction.title, 'Local');
    expect(transaction.amount, 10);
  });

  test('troca de sessão durante GET aborta sem escrita local', () async {
    firestore.transactions.documents = [
      _FakeDocument('remote-1', validRemoteData()),
    ];
    firestore.transactions.beforeGet = () async {
      auth.currentUser = _FakeUser('user-b');
    };

    await repository.syncTransactionsFromFirestore();

    expect(firestore.transactions.getCalls, 1);
    expect(await db.select(db.transactions).get(), isEmpty);
  });

  test(
    'pending CREATE durante pull não é apagado por snapshot antigo',
    () async {
      final started = Completer<void>();
      final release = Completer<void>();
      firestore.transactions.beforeGet = () {
        started.complete();
        return release.future;
      };

      final pull = repository.syncTransactionsFromFirestore();
      await started.future;
      await repository.addTransaction(
        title: 'Nova local',
        amount: 25,
        type: 'expense',
        category: 'Lazer',
      );
      release.complete();
      await pull;

      final transactions = await db.select(db.transactions).get();
      expect(transactions, hasLength(1));
      expect(transactions.single.title, 'Nova local');
      expect(await db.getPendingSyncItems('user-a'), hasLength(1));
    },
  );

  test('succeeded CREATE iniciado durante pull permanece local', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    firestore.transactions.beforeGet = () {
      started.complete();
      return release.future;
    };

    final pull = repository.syncTransactionsFromFirestore();
    await started.future;
    await seedLocal(firestoreId: 'created-during-pull');
    final queueId = await enqueue(
      docId: 'created-during-pull',
      operationType: 'create',
      createdAt: DateTime.now().millisecondsSinceEpoch + 1000,
    );
    await db.markSyncItemAsSucceeded(queueId, 'user-a');
    release.complete();
    await pull;

    expect(await db.select(db.transactions).get(), hasLength(1));
    expect(
      (await db.select(db.transactions).getSingle()).firestoreId,
      'created-during-pull',
    );
  });

  test('succeeded CREATE durante drain pertence à janela do pull', () async {
    final drainStarted = Completer<void>();
    final releaseDrain = Completer<void>();
    syncManager.duringDrain = () {
      drainStarted.complete();
      return releaseDrain.future;
    };

    final pull = repository.syncTransactionsFromFirestore();
    await drainStarted.future;

    await seedLocal(firestoreId: 'created-during-drain');
    final operationCreatedAt = DateTime.now().millisecondsSinceEpoch;
    final queueId = await enqueue(
      docId: 'created-during-drain',
      operationType: 'create',
      createdAt: operationCreatedAt,
    );
    await db.markSyncItemAsSucceeded(queueId, 'user-a');

    while (DateTime.now().millisecondsSinceEpoch <= operationCreatedAt) {
      await Future<void>.value();
    }
    releaseDrain.complete();
    await pull;

    expect(await db.select(db.transactions).get(), hasLength(1));
    expect(
      (await db.select(db.transactions).getSingle()).firestoreId,
      'created-during-drain',
    );
  });

  test('pending DELETE durante pull não ressuscita snapshot antigo', () async {
    final localId = await seedLocal();
    firestore.transactions.documents = [
      _FakeDocument('remote-1', validRemoteData()),
    ];
    final started = Completer<void>();
    final release = Completer<void>();
    firestore.transactions.beforeGet = () {
      started.complete();
      return release.future;
    };

    final pull = repository.syncTransactionsFromFirestore();
    await started.future;
    await repository.deleteTransaction(localId);
    release.complete();
    await pull;

    expect(await db.select(db.transactions).get(), isEmpty);
    expect(await db.getPendingSyncItems('user-a'), hasLength(1));
  });

  test(
    'succeeded DELETE durante pull não ressuscita snapshot antigo',
    () async {
      final localId = await seedLocal();
      firestore.transactions.documents = [
        _FakeDocument('remote-1', validRemoteData()),
      ];
      final started = Completer<void>();
      final release = Completer<void>();
      firestore.transactions.beforeGet = () {
        started.complete();
        return release.future;
      };

      final pull = repository.syncTransactionsFromFirestore();
      await started.future;
      await repository.deleteTransaction(localId);
      final pending =
          (await db.getPendingSyncItems('user-a')).single as SyncQueueTableData;
      await db.markSyncItemAsSucceeded(pending.id, 'user-a');
      release.complete();
      await pull;

      expect(await db.select(db.transactions).get(), isEmpty);
    },
  );

  test('delete remoto normal remove transação local cross-device', () async {
    await seedLocal();

    await repository.syncTransactionsFromFirestore();

    expect(await db.select(db.transactions).get(), isEmpty);
  });

  test('ausência remota preserva identificadores locais legados', () async {
    await seedLocal(firestoreId: null, title: 'Nulo');
    await seedLocal(firestoreId: '', title: 'Vazio');
    await seedLocal(firestoreId: 'pending', title: 'Pending');
    await seedLocal(firestoreId: 'synced', title: 'Synced');

    await repository.syncTransactionsFromFirestore();

    final titles = (await db.select(db.transactions).get())
        .map((transaction) => transaction.title)
        .toSet();
    expect(titles, {'Nulo', 'Vazio', 'Pending', 'Synced'});
  });
}
