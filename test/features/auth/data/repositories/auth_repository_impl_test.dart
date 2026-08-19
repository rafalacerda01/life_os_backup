import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:life_os/core/errors/failure.dart';
import 'package:life_os/features/auth/data/remote/account_remote_data_source.dart';
import 'package:life_os/features/auth/data/repositories/auth_repository_impl.dart';

class FakeFirebaseAuth extends Fake implements FirebaseAuth {
  User? user;
  Object? signOutError;
  int signOutCalls = 0;

  @override
  User? get currentUser => user;

  @override
  Future<void> signOut() async {
    signOutCalls += 1;
    if (signOutError != null) throw signOutError!;
  }
}

class FakeFirebaseUser extends Fake implements User {
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

class FakeFirebaseFirestore extends Fake implements FirebaseFirestore {}

class FakeAccountRemoteDataSource extends AccountRemoteDataSource {
  Object? error;
  int calls = 0;

  FakeAccountRemoteDataSource()
    : super(
        client: MockClient((_) async => throw UnimplementedError()),
        idTokenProvider: () async => 'token',
      );

  @override
  Future<AccountDeletionResponse> deleteAccount() async {
    calls += 1;
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
  late FakeAccountRemoteDataSource remote;
  late AuthRepositoryImpl repository;

  setUp(() {
    auth = FakeFirebaseAuth();
    user = FakeFirebaseUser();
    remote = FakeAccountRemoteDataSource();
    auth.user = user;
    repository = AuthRepositoryImpl(auth, FakeFirebaseFirestore(), remote);
  });

  test('sucesso HTTP faz signOut local best-effort', () async {
    final result = await repository.deleteAccount();

    var succeeded = false;
    result.when((_) => succeeded = true, (_) {});
    expect(succeeded, isTrue);
    expect(remote.calls, 1);
    expect(auth.signOutCalls, 1);
    expect(user.deleteCalls, 0);
  });

  test('ambiguidade com user-not-found reconcilia como sucesso', () async {
    remote.error = _ambiguousError;
    user.reloadError = FirebaseAuthException(code: 'user-not-found');

    final result = await repository.deleteAccount();

    var succeeded = false;
    result.when((_) => succeeded = true, (_) {});
    expect(succeeded, isTrue);
    expect(user.reloadCalls, 1);
    expect(auth.signOutCalls, 1);
  });

  test('ambiguidade com usuário existente preserva a falha', () async {
    remote.error = _ambiguousError;
    final result = await repository.deleteAccount();

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

      final result = await repository.deleteAccount();

      var failed = false;
      result.when((_) {}, (_) => failed = true);
      expect(failed, isTrue);
      expect(auth.signOutCalls, 0);
    });
  }

  test('falha de signOut não reverte sucesso confirmado', () async {
    auth.signOutError = StateError('local sign-out failed');

    final result = await repository.deleteAccount();

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

    final result = await repository.deleteAccount();

    var failed = false;
    result.when((_) {}, (_) => failed = true);
    expect(failed, isTrue);
    expect(user.reloadCalls, 0);
    expect(auth.signOutCalls, 0);
  });
}
