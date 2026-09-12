// ignore_for_file: subtype_of_sealed_class, must_be_immutable

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:life_os/core/errors/failure.dart';
import 'package:life_os/features/auth/data/remote/account_remote_data_source.dart';
import 'package:life_os/features/auth/data/repositories/auth_repository_impl.dart';
import 'package:life_os/features/auth/domain/entities/user_entity.dart';

class FakeFirebaseAuth extends Fake implements FirebaseAuth {
  User? user;
  UserCredential? signInCredential;
  UserCredential? signUpCredential;
  Object? signOutError;
  int signOutCalls = 0;
  int signInCalls = 0;
  int signUpCalls = 0;

  @override
  User? get currentUser => user;

  @override
  Future<void> signOut() async {
    signOutCalls += 1;
    if (signOutError != null) throw signOutError!;
  }

  @override
  Future<UserCredential> signInWithEmailAndPassword({
    required String email,
    required String password,
  }) async {
    signInCalls += 1;
    return signInCredential!;
  }

  @override
  Future<UserCredential> createUserWithEmailAndPassword({
    required String email,
    required String password,
  }) async {
    signUpCalls += 1;
    return signUpCredential!;
  }
}

class FakeFirebaseUser extends Fake implements User {
  FakeFirebaseUser(this.uid, {this.email, this.displayName, this.photoURL});

  @override
  final String uid;
  @override
  final String? email;
  @override
  final String? displayName;
  @override
  final String? photoURL;
  Object? reloadError;
  int reloadCalls = 0;
  int deleteCalls = 0;

  @override
  Future<void> reload() async {
    reloadCalls += 1;
    if (reloadError != null) throw reloadError!;
  }

  @override
  Future<void> delete() async {
    deleteCalls += 1;
  }
}

class FakeUserCredential extends Fake implements UserCredential {
  FakeUserCredential(this.user);

  @override
  final User? user;
}

class FakeUserDocumentSnapshot extends Fake
    implements DocumentSnapshot<Map<String, dynamic>> {
  FakeUserDocumentSnapshot(this.id, this.value);

  @override
  final String id;
  final Map<String, dynamic>? value;

  @override
  bool get exists => value != null;

  @override
  Map<String, dynamic>? data() => value == null ? null : Map.of(value!);
}

class FakeUserDocumentReference extends Fake
    implements DocumentReference<Map<String, dynamic>> {
  FakeUserDocumentReference(this.id);

  @override
  final String id;
  Map<String, dynamic>? value;
  int getCalls = 0;
  int setCalls = 0;
  int setFailuresRemaining = 0;
  bool persistBeforeSetFailure = false;

  @override
  Future<DocumentSnapshot<Map<String, dynamic>>> get([
    GetOptions? options,
  ]) async {
    getCalls += 1;
    return FakeUserDocumentSnapshot(id, value);
  }

  @override
  Future<void> set(Map<String, dynamic> data, [SetOptions? options]) async {
    setCalls += 1;
    if (setFailuresRemaining > 0) {
      setFailuresRemaining -= 1;
      if (persistBeforeSetFailure) value = Map.of(data);
      throw StateError(
        persistBeforeSetFailure
            ? 'technical-after-commit-marker'
            : 'technical-firestore-marker',
      );
    }
    value = Map.of(data);
  }
}

class FakeUsersCollection extends Fake
    implements CollectionReference<Map<String, dynamic>> {
  final Map<String, FakeUserDocumentReference> documents = {};

  FakeUserDocumentReference document(String uid) =>
      documents.putIfAbsent(uid, () => FakeUserDocumentReference(uid));

  @override
  DocumentReference<Map<String, dynamic>> doc([String? path]) {
    if (path == null) throw UnsupportedError('Auto-ID não é usado no teste.');
    return document(path);
  }
}

class FakeFirebaseFirestore extends Fake implements FirebaseFirestore {
  final users = FakeUsersCollection();

  @override
  CollectionReference<Map<String, dynamic>> collection(String collectionPath) {
    if (collectionPath != 'users') {
      throw UnsupportedError('Coleção não suportada no teste.');
    }
    return users;
  }
}

class FakeAccountRemoteDataSource extends AccountRemoteDataSource {
  Object? error;
  Future<void> Function(String expectedUid)? onDelete;
  int calls = 0;
  final List<String> expectedUids = <String>[];

  FakeAccountRemoteDataSource()
    : super(
        client: MockClient((_) async => throw UnimplementedError()),
        idTokenProvider: (_) async => 'token',
      );

  @override
  Future<AccountDeletionResponse> deleteAccount({
    required String expectedUid,
  }) async {
    calls += 1;
    expectedUids.add(expectedUid);
    await onDelete?.call(expectedUid);
    if (error != null) throw error!;
    return const AccountDeletionResponse(circleDeleted: false);
  }
}

const _ambiguousError = AccountRemoteException(
  statusCode: 500,
  code: 'ACCOUNT_DELETE_SERVER_ERROR',
  message: 'Falha segura.',
  isAmbiguous: true,
);

void main() {
  late FakeFirebaseAuth auth;
  late FakeFirebaseUser user;
  late FakeFirebaseFirestore firestore;
  late FakeAccountRemoteDataSource remote;
  late AuthRepositoryImpl repository;

  setUp(() {
    auth = FakeFirebaseAuth();
    user = FakeFirebaseUser('user-a');
    firestore = FakeFirebaseFirestore();
    remote = FakeAccountRemoteDataSource();
    auth.user = user;
    repository = AuthRepositoryImpl(auth, firestore, remote);
  });

  test('sucesso HTTP faz signOut local best-effort', () async {
    final result = await repository.deleteAccount(expectedUid: 'user-a');

    var succeeded = false;
    result.when((_) => succeeded = true, (_) {});
    expect(succeeded, isTrue);
    expect(remote.calls, 1);
    expect(remote.expectedUids, <String>['user-a']);
    expect(auth.signOutCalls, 1);
    expect(user.deleteCalls, 0);
  });

  test('ambiguidade com user-not-found reconcilia como sucesso', () async {
    remote.error = _ambiguousError;
    user.reloadError = FirebaseAuthException(code: 'user-not-found');

    final result = await repository.deleteAccount(expectedUid: 'user-a');

    var succeeded = false;
    result.when((_) => succeeded = true, (_) {});
    expect(succeeded, isTrue);
    expect(user.reloadCalls, 1);
    expect(auth.signOutCalls, 1);
  });

  test('ambiguidade com usuário existente preserva a falha', () async {
    remote.error = _ambiguousError;
    final result = await repository.deleteAccount(expectedUid: 'user-a');

    Failure? capturedFailure;
    result.when((_) {}, (failure) => capturedFailure = failure);
    expect(capturedFailure, isA<AuthFailure>());
    expect(capturedFailure?.code, 'ACCOUNT_DELETE_SERVER_ERROR');
    expect(user.reloadCalls, 1);
    expect(auth.signOutCalls, 0);
  });

  for (final code in [
    'user-disabled',
    'user-token-expired',
    'network-request-failed',
    'requires-recent-login',
    'unknown',
  ]) {
    test('$code não é prova de conta excluída', () async {
      remote.error = _ambiguousError;
      user.reloadError = FirebaseAuthException(code: code);

      final result = await repository.deleteAccount(expectedUid: 'user-a');

      var failed = false;
      result.when((_) {}, (_) => failed = true);
      expect(failed, isTrue);
      expect(auth.signOutCalls, 0);
    });
  }

  test('falha de signOut não reverte sucesso confirmado', () async {
    auth.signOutError = StateError('local sign-out failed');

    final result = await repository.deleteAccount(expectedUid: 'user-a');

    var succeeded = false;
    result.when((_) => succeeded = true, (_) {});
    expect(succeeded, isTrue);
  });

  test('falha não ambígua não tenta reconciliação', () async {
    remote.error = const AccountRemoteException(
      statusCode: 409,
      code: 'ACCOUNT_STATE_CONFLICT',
      message: 'Não foi possível validar o estado da conta para exclusão.',
      isAmbiguous: false,
    );

    final result = await repository.deleteAccount(expectedUid: 'user-a');

    var failed = false;
    result.when((_) {}, (_) => failed = true);
    expect(failed, isTrue);
    expect(user.reloadCalls, 0);
    expect(auth.signOutCalls, 0);
  });

  test('sessão B antes do remote falha sem request ou signOut', () async {
    auth.user = FakeFirebaseUser('user-b');

    final result = await repository.deleteAccount(expectedUid: 'user-a');

    Failure? capturedFailure;
    result.when((_) {}, (failure) => capturedFailure = failure);
    expect(capturedFailure, isA<AuthFailure>());
    expect(capturedFailure?.code, 'UNAUTHENTICATED');
    expect(remote.calls, 0);
    expect(auth.signOutCalls, 0);
    expect(auth.currentUser?.uid, 'user-b');
  });

  test('troca para B após remote não faz signOut de B', () async {
    final remoteStarted = Completer<void>();
    final allowRemote = Completer<void>();
    remote.onDelete = (_) async {
      remoteStarted.complete();
      await allowRemote.future;
    };

    final pending = repository.deleteAccount(expectedUid: 'user-a');
    await remoteStarted.future;
    auth.user = FakeFirebaseUser('user-b');
    allowRemote.complete();
    final result = await pending;

    var succeeded = false;
    result.when((_) => succeeded = true, (_) {});
    expect(succeeded, isTrue);
    expect(remote.expectedUids, <String>['user-a']);
    expect(auth.signOutCalls, 0);
    expect(auth.currentUser?.uid, 'user-b');
  });

  test('ambiguidade reconcilia somente User A e preserva sessão B', () async {
    final remoteStarted = Completer<void>();
    final allowRemote = Completer<void>();
    remote.error = _ambiguousError;
    remote.onDelete = (_) async {
      remoteStarted.complete();
      await allowRemote.future;
    };
    user.reloadError = FirebaseAuthException(code: 'user-not-found');

    final pending = repository.deleteAccount(expectedUid: 'user-a');
    await remoteStarted.future;
    auth.user = FakeFirebaseUser('user-b');
    allowRemote.complete();
    final result = await pending;

    var succeeded = false;
    result.when((_) => succeeded = true, (_) {});
    expect(succeeded, isTrue);
    expect(user.reloadCalls, 1);
    expect(auth.signOutCalls, 0);
    expect(auth.currentUser?.uid, 'user-b');
  });

  group('provisionamento de perfil', () {
    test('perfil existente é retornado sem recriar o documento', () async {
      final document = firestore.users.document('user-a')
        ..value = {
          'email': 'existing@example.invalid',
          'displayName': 'Perfil existente',
          'isPremium': true,
          'photoUrl': null,
          'xp': 42,
          'level': 3,
          'streak': 7,
          'habitsCount': 4,
          'tasksCount': 5,
          'goalsCount': 6,
          'subjectsCount': 2,
          'medicationsCount': 1,
          'transactionsCount': 8,
        };

      final result = await repository.getCurrentUser();

      UserEntity? returnedUser;
      result.when((value) => returnedUser = value, (_) {});
      expect(returnedUser?.displayName, 'Perfil existente');
      expect(returnedUser?.isPremium, isTrue);
      expect(returnedUser?.xp, 42);
      expect(document.getCalls, 1);
      expect(document.setCalls, 0);
    });

    test('login recupera usuário Auth sem perfil Firestore', () async {
      final authUser = FakeFirebaseUser(
        'orphan-user',
        email: 'orphan@example.invalid',
        displayName: 'Usuário recuperado',
      );
      auth.signInCredential = FakeUserCredential(authUser);

      final result = await repository.signInWithEmailAndPassword(
        'orphan@example.invalid',
        'password',
      );

      UserEntity? returnedUser;
      result.when((value) => returnedUser = value, (_) {});
      final document = firestore.users.document('orphan-user');
      expect(returnedUser?.uid, 'orphan-user');
      expect(document.setCalls, 1);
      expect(document.value, {
        'email': 'orphan@example.invalid',
        'displayName': 'Usuário recuperado',
        'isPremium': false,
        'photoUrl': null,
        'xp': 0,
        'level': 1,
        'streak': 0,
        'habitsCount': 0,
        'tasksCount': 0,
        'goalsCount': 0,
        'subjectsCount': 0,
        'medicationsCount': 0,
        'transactionsCount': 0,
      });
    });

    test('cadastro cria perfil inicial e preserva o nome informado', () async {
      final authUser = FakeFirebaseUser(
        'new-user',
        email: 'new@example.invalid',
      );
      auth.signUpCredential = FakeUserCredential(authUser);

      final result = await repository.signUpWithEmailAndPassword(
        'new@example.invalid',
        'password',
        'Rafa',
      );

      UserEntity? returnedUser;
      result.when((value) => returnedUser = value, (_) {});
      final document = firestore.users.document('new-user');
      expect(returnedUser?.displayName, 'Rafa');
      expect(document.value?['displayName'], 'Rafa');
      expect(document.value?['isPremium'], isFalse);
      expect(document.value?['xp'], 0);
      expect(document.value?['level'], 1);
      expect(document.value?['streak'], 0);
      expect(document.value?['habitsCount'], 0);
      expect(document.value?['tasksCount'], 0);
      expect(document.value?['goalsCount'], 0);
      expect(document.value?['subjectsCount'], 0);
      expect(document.value?['medicationsCount'], 0);
      expect(document.value?['transactionsCount'], 0);
    });

    test('falha de provisionamento retorna Failure sanitizado', () async {
      final authUser = FakeFirebaseUser(
        'orphan-user',
        email: 'orphan@example.invalid',
      );
      auth.signInCredential = FakeUserCredential(authUser);
      firestore.users.document('orphan-user').setFailuresRemaining = 1;

      final result = await repository.signInWithEmailAndPassword(
        'orphan@example.invalid',
        'password',
      );

      Failure? failure;
      result.when((_) {}, (value) => failure = value);
      expect(failure, isA<ServerFailure>());
      expect(failure?.code, 'USER_PROFILE_PROVISION_FAILED');
      expect(failure?.message, isNot(contains('technical-firestore-marker')));
      expect(firestore.users.document('orphan-user').value, isNull);
    });

    test('nova tentativa recupera perfil após falha anterior', () async {
      final authUser = FakeFirebaseUser(
        'recoverable-user',
        email: 'recoverable@example.invalid',
        displayName: 'Recuperável',
      );
      auth.signInCredential = FakeUserCredential(authUser);
      final document = firestore.users.document('recoverable-user')
        ..setFailuresRemaining = 1;

      final first = await repository.signInWithEmailAndPassword(
        'recoverable@example.invalid',
        'password',
      );
      final second = await repository.signInWithEmailAndPassword(
        'recoverable@example.invalid',
        'password',
      );

      Failure? firstFailure;
      UserEntity? secondUser;
      first.when((_) {}, (value) => firstFailure = value);
      second.when((value) => secondUser = value, (_) {});
      expect(firstFailure, isA<ServerFailure>());
      expect(secondUser?.uid, 'recoverable-user');
      expect(document.getCalls, 3);
      expect(document.setCalls, 2);
      expect(document.value?['displayName'], 'Recuperável');
      expect(auth.signInCalls, 2);
    });

    test(
      'escrita ambígua é reconciliada quando perfil já foi persistido',
      () async {
        final authUser = FakeFirebaseUser(
          'ambiguous-user',
          email: 'ambiguous@example.invalid',
          displayName: 'Perfil persistido',
        );
        auth.signInCredential = FakeUserCredential(authUser);
        final document = firestore.users.document('ambiguous-user')
          ..setFailuresRemaining = 1
          ..persistBeforeSetFailure = true;

        final result = await repository.signInWithEmailAndPassword(
          'ambiguous@example.invalid',
          'password',
        );

        UserEntity? returnedUser;
        Failure? failure;
        result.when(
          (value) => returnedUser = value,
          (value) => failure = value,
        );
        expect(failure, isNull);
        expect(returnedUser?.uid, 'ambiguous-user');
        expect(returnedUser?.displayName, 'Perfil persistido');
        expect(
          failure?.message ?? '',
          isNot(contains('technical-after-commit-marker')),
        );
        expect(document.setCalls, 1);
        expect(document.getCalls, 2);
        expect(document.value?['displayName'], 'Perfil persistido');
      },
    );

    test('getCurrentUser também repara root profile ausente', () async {
      auth.user = FakeFirebaseUser(
        'restored-user',
        email: 'restored@example.invalid',
        displayName: 'Sessão restaurada',
      );

      final result = await repository.getCurrentUser();

      UserEntity? returnedUser;
      result.when((value) => returnedUser = value, (_) {});
      expect(returnedUser?.uid, 'restored-user');
      expect(firestore.users.document('restored-user').setCalls, 1);
      expect(
        firestore.users.document('restored-user').value?['displayName'],
        'Sessão restaurada',
      );
    });
  });
}
