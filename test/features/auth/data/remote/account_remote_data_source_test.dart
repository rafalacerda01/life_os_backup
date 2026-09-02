import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:life_os/features/auth/data/remote/account_remote_data_source.dart';

const _url = 'https://example.test/api/account/delete';
const _token = 'sensitive-firebase-token';
const _appCheckToken = 'mock-app-check-token';
const _appCheckMessage =
    'Não foi possível validar a segurança do aplicativo. Tente novamente.';
const _uid = 'user-a';

AccountRemoteDataSource _source(
  MockClient client, {
  AccountIdTokenProvider? tokenProvider,
  AccountAppCheckTokenProvider? appCheckTokenProvider,
  Duration timeout = AccountRemoteDataSource.defaultTimeout,
}) {
  return AccountRemoteDataSource(
    client: client,
    idTokenProvider: tokenProvider ?? (_) async => _token,
    appCheckTokenProvider: appCheckTokenProvider ?? () async => _appCheckToken,
    url: _url,
    timeout: timeout,
  );
}

class _FirebaseAuth extends Fake implements FirebaseAuth {
  User? user;

  @override
  User? get currentUser => user;
}

class _FirebaseUser extends Fake implements User {
  _FirebaseUser(
    this.uid, {
    this.token = _token,
    this.tokenStarted,
    this.allowToken,
  });

  @override
  final String uid;
  final String token;
  final Completer<void>? tokenStarted;
  final Completer<void>? allowToken;

  @override
  Future<String?> getIdToken([bool forceRefresh = false]) async {
    tokenStarted?.complete();
    await allowToken?.future;
    return token;
  }
}

Future<AccountRemoteException> _capture(
  Future<Object?> Function() action,
) async {
  try {
    await action();
    fail('Expected AccountRemoteException.');
  } on AccountRemoteException catch (error) {
    return error;
  }
}

void main() {
  test('envia POST exato com token provider e corpo vazio', () async {
    late http.Request captured;
    var tokenCalls = 0;
    var appCheckCalls = 0;
    final source = _source(
      MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({'deleted': true, 'circleDeleted': false}),
          200,
        );
      }),
      tokenProvider: (expectedUid) async {
        tokenCalls += 1;
        expect(expectedUid, _uid);
        return _token;
      },
      appCheckTokenProvider: () async {
        expect(tokenCalls, 1);
        appCheckCalls += 1;
        return _appCheckToken;
      },
    );

    final result = await source.deleteAccount(expectedUid: _uid);

    expect(captured.method, 'POST');
    expect(captured.url, Uri.parse(_url));
    expect(captured.headers['content-type'], 'application/json');
    expect(captured.headers['authorization'], 'Bearer $_token');
    expect(captured.headers['x-firebase-appcheck'], _appCheckToken);
    expect(captured.body, '{}');
    expect(jsonDecode(captured.body), <String, dynamic>{});
    expect(captured.body, isNot(contains('uid')));
    expect(captured.body, isNot(contains('email')));
    expect(captured.body, isNot(contains('password')));
    expect(captured.body, isNot(contains('activeCircleId')));
    expect(tokenCalls, 1);
    expect(appCheckCalls, 1);
    expect(result.circleDeleted, isFalse);
  });

  test('URL padrão aponta para o endpoint publicado', () {
    expect(
      AccountRemoteDataSource.defaultUrl,
      'https://life-os-backend-gray.vercel.app/api/account/delete',
    );
  });

  test('rejeita URL que não usa HTTPS', () {
    expect(
      () => AccountRemoteDataSource(
        client: MockClient((_) async => http.Response('{}', 200)),
        idTokenProvider: (_) async => _token,
        url: 'http://example.test/api/account/delete',
      ),
      throwsArgumentError,
    );
  });

  test(
    'aceita sucesso somente com deleted true e circleDeleted bool',
    () async {
      final source = _source(
        MockClient(
          (_) async => http.Response(
            jsonEncode({'deleted': true, 'circleDeleted': true}),
            200,
          ),
        ),
      );

      final result = await source.deleteAccount(expectedUid: _uid);

      expect(result.circleDeleted, isTrue);
    },
  );

  for (final responseBody in [
    '{invalid',
    '[]',
    '{}',
    '{"deleted":true,"circleDeleted":"false"}',
    '{"deleted":true,"circleDeleted":false,"extra":true}',
  ]) {
    test('2xx malformado é ambíguo: $responseBody', () async {
      final source = _source(
        MockClient((_) async => http.Response(responseBody, 200)),
      );

      final error = await _capture(
        () => source.deleteAccount(expectedUid: _uid),
      );

      expect(error.statusCode, 200);
      expect(error.code, 'ACCOUNT_DELETE_AMBIGUOUS_RESPONSE');
      expect(error.isAmbiguous, isTrue);
    });
  }

  test('HTTP 200 com deleted false é resposta ambígua', () async {
    final source = _source(
      MockClient(
        (_) async => http.Response(
          jsonEncode({'deleted': false, 'circleDeleted': false}),
          200,
        ),
      ),
    );

    final error = await _capture(() => source.deleteAccount(expectedUid: _uid));

    expect(error.statusCode, 200);
    expect(error.code, 'ACCOUNT_DELETE_AMBIGUOUS_RESPONSE');
    expect(error.isAmbiguous, isTrue);
  });

  for (final testCase in [
    (status: 401, code: 'APP_CHECK_REQUIRED', message: _appCheckMessage),
    (status: 401, code: 'APP_CHECK_INVALID', message: _appCheckMessage),
    (
      status: 401,
      code: 'UNAUTHENTICATED',
      message: 'Sua sessão não é válida. Entre novamente e tente de novo.',
    ),
    (
      status: 401,
      code: 'REAUTHENTICATION_REQUIRED',
      message: 'É necessária uma autenticação recente para excluir a conta.',
    ),
    (
      status: 409,
      code: 'CIRCLE_ADMIN_ACTION_REQUIRED',
      message:
          'Antes de excluir sua conta, exclua o Circle que você administra.',
    ),
    (
      status: 409,
      code: 'ACCOUNT_STATE_CONFLICT',
      message: 'Não foi possível validar o estado da conta para exclusão.',
    ),
    (
      status: 429,
      code: 'RATE_LIMITED',
      message: 'Muitas tentativas. Aguarde alguns instantes e tente novamente.',
    ),
  ]) {
    test('${testCase.status} ${testCase.code} usa mensagem local', () async {
      final source = _source(
        MockClient(
          (_) async => http.Response(
            jsonEncode({
              'error': 'raw backend details with $_token $_appCheckToken',
              'code': testCase.code,
            }),
            testCase.status,
          ),
        ),
      );

      final error = await _capture(
        () => source.deleteAccount(expectedUid: _uid),
      );

      expect(error.statusCode, testCase.status);
      expect(error.code, testCase.code);
      expect(error.message, testCase.message);
      expect(error.isAmbiguous, isFalse);
      expect(error.message, isNot(contains(_token)));
      expect(error.message, isNot(contains(_appCheckToken)));
      expect(error.toString(), isNot(contains(_appCheckToken)));
    });
  }

  test('HTTP 500 é sanitizado e marcado como ambíguo', () async {
    final source = _source(
      MockClient(
        (_) async => http.Response(
          jsonEncode({
            'error': 'internal stack and $_token',
            'code': 'INTERNAL_ERROR',
          }),
          500,
        ),
      ),
    );

    final error = await _capture(() => source.deleteAccount(expectedUid: _uid));

    expect(error.statusCode, 500);
    expect(error.code, 'ACCOUNT_DELETE_SERVER_ERROR');
    expect(error.isAmbiguous, isTrue);
    expect(error.message, isNot(contains(_token)));
    expect(error.toString(), isNot(contains(_token)));
  });

  test('HTTP 408 é ambíguo e sanitizado', () async {
    final source = _source(
      MockClient(
        (_) async => http.Response(
          jsonEncode({
            'error': 'raw backend details with $_token',
            'code': 'PRIVATE_BACKEND_CODE_$_token',
          }),
          408,
        ),
      ),
    );

    final error = await _capture(() => source.deleteAccount(expectedUid: _uid));

    expect(error.statusCode, 408);
    expect(error.isAmbiguous, isTrue);
    expect(error.message, isNot(contains(_token)));
    expect(error.toString(), isNot(contains(_token)));
  });

  test('código desconhecido do backend não é exposto', () async {
    final source = _source(
      MockClient(
        (_) async => http.Response(
          jsonEncode({
            'error': 'raw backend details with $_token',
            'code': 'PRIVATE_BACKEND_CODE_$_token',
          }),
          400,
        ),
      ),
    );

    final error = await _capture(() => source.deleteAccount(expectedUid: _uid));

    expect(error.code, 'ACCOUNT_DELETE_FAILED');
    expect(error.message, 'Não foi possível excluir a conta. Tente novamente.');
    expect(error.message, isNot(contains(_token)));
    expect(error.toString(), isNot(contains(_token)));
  });

  test('timeout após envio é ambíguo', () async {
    var requests = 0;
    final source = _source(
      MockClient((_) async {
        requests += 1;
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return http.Response('{}', 200);
      }),
      timeout: const Duration(milliseconds: 1),
    );

    final error = await _capture(() => source.deleteAccount(expectedUid: _uid));

    expect(requests, 1);
    expect(error.code, 'ACCOUNT_DELETE_TIMEOUT');
    expect(error.isAmbiguous, isTrue);
  });

  test('ClientException após envio é ambígua e sanitizada', () async {
    final source = _source(
      MockClient((request) async {
        throw http.ClientException('offline $_token', request.url);
      }),
    );

    final error = await _capture(() => source.deleteAccount(expectedUid: _uid));

    expect(error.code, 'ACCOUNT_DELETE_TRANSPORT_ERROR');
    expect(error.isAmbiguous, isTrue);
    expect(error.message, isNot(contains(_token)));
    expect(error.toString(), isNot(contains(_token)));
  });

  for (final token in <String?>[null, '', '   ']) {
    test('App Check ausente/vazio ($token) impede HTTP', () async {
      var requests = 0;
      final source = _source(
        MockClient((_) async {
          requests += 1;
          return http.Response('{}', 200);
        }),
        appCheckTokenProvider: () async => token,
      );

      final error = await _capture(
        () => source.deleteAccount(expectedUid: _uid),
      );

      expect(requests, 0);
      expect(error.statusCode, isNull);
      expect(error.code, 'APP_CHECK_REQUIRED');
      expect(error.message, _appCheckMessage);
      expect(error.isAmbiguous, isFalse);
    });
  }

  test('falha do provider App Check impede HTTP e sanitiza o erro', () async {
    var requests = 0;
    final source = _source(
      MockClient((_) async {
        requests += 1;
        return http.Response('{}', 200);
      }),
      appCheckTokenProvider: () async {
        throw StateError('private Firebase error $_appCheckToken $_token');
      },
    );

    final error = await _capture(() => source.deleteAccount(expectedUid: _uid));

    expect(requests, 0);
    expect(error.statusCode, isNull);
    expect(error.code, 'APP_CHECK_INVALID');
    expect(error.message, _appCheckMessage);
    expect(error.isAmbiguous, isFalse);
    for (final privateValue in [
      _appCheckToken,
      _token,
      'private Firebase error',
    ]) {
      expect(error.message, isNot(contains(privateValue)));
      expect(error.toString(), isNot(contains(privateValue)));
    }
  });

  test('timeout do provider App Check impede HTTP sem ambiguidade', () async {
    var requests = 0;
    final source = _source(
      MockClient((_) async {
        requests += 1;
        return http.Response('{}', 200);
      }),
      appCheckTokenProvider: () => Completer<String?>().future,
      timeout: const Duration(milliseconds: 1),
    );

    final error = await _capture(() => source.deleteAccount(expectedUid: _uid));

    expect(requests, 0);
    expect(error.code, 'APP_CHECK_INVALID');
    expect(error.message, _appCheckMessage);
    expect(error.isAmbiguous, isFalse);
  });

  test('token ausente falha antes de App Check e request', () async {
    var requests = 0;
    var appCheckCalls = 0;
    final source = _source(
      MockClient((_) async {
        requests += 1;
        return http.Response('{}', 200);
      }),
      tokenProvider: (_) async => ' ',
      appCheckTokenProvider: () async {
        appCheckCalls += 1;
        return _appCheckToken;
      },
    );

    final error = await _capture(() => source.deleteAccount(expectedUid: _uid));

    expect(requests, 0);
    expect(appCheckCalls, 0);
    expect(error.code, 'UNAUTHENTICATED');
    expect(error.isAmbiguous, isFalse);
  });

  test('sessão B antes do token impede qualquer request para A', () async {
    var requests = 0;
    final auth = _FirebaseAuth()..user = _FirebaseUser('user-b');
    final source = _source(
      MockClient((_) async {
        requests += 1;
        return http.Response('{}', 200);
      }),
      tokenProvider: (expectedUid) =>
          loadAccountIdTokenForExpectedUser(auth, expectedUid),
    );

    final error = await _capture(() => source.deleteAccount(expectedUid: _uid));

    expect(requests, 0);
    expect(error.code, 'UNAUTHENTICATED');
    expect(error.isAmbiguous, isFalse);
  });

  test('troca A para B durante getIdToken impede o HTTP', () async {
    var requests = 0;
    final tokenStarted = Completer<void>();
    final allowToken = Completer<void>();
    final auth = _FirebaseAuth()
      ..user = _FirebaseUser(
        _uid,
        tokenStarted: tokenStarted,
        allowToken: allowToken,
      );
    final source = _source(
      MockClient((_) async {
        requests += 1;
        return http.Response('{}', 200);
      }),
      tokenProvider: (expectedUid) =>
          loadAccountIdTokenForExpectedUser(auth, expectedUid),
    );

    final pending = _capture(() => source.deleteAccount(expectedUid: _uid));
    await tokenStarted.future;
    auth.user = _FirebaseUser('user-b', token: 'token-b');
    allowToken.complete();
    final error = await pending;

    expect(requests, 0);
    expect(error.code, 'UNAUTHENTICATED');
    expect(error.isAmbiguous, isFalse);
  });
}
