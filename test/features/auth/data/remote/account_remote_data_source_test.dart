import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:life_os/features/auth/data/remote/account_remote_data_source.dart';

const _url = 'https://example.test/api/account/delete';
const _token = 'sensitive-firebase-token';

AccountRemoteDataSource _source(
  MockClient client, {
  AccountIdTokenProvider? tokenProvider,
  Duration timeout = AccountRemoteDataSource.defaultTimeout,
}) {
  return AccountRemoteDataSource(
    client: client,
    idTokenProvider: tokenProvider ?? () async => _token,
    url: _url,
    timeout: timeout,
  );
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
    final source = _source(
      MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({'deleted': true, 'circleDeleted': false}),
          200,
        );
      }),
      tokenProvider: () async {
        tokenCalls += 1;
        return _token;
      },
    );

    final result = await source.deleteAccount();

    expect(captured.method, 'POST');
    expect(captured.url, Uri.parse(_url));
    expect(captured.headers['content-type'], 'application/json');
    expect(captured.headers['authorization'], 'Bearer $_token');
    expect(captured.body, '{}');
    expect(jsonDecode(captured.body), <String, dynamic>{});
    expect(captured.body, isNot(contains('uid')));
    expect(captured.body, isNot(contains('email')));
    expect(captured.body, isNot(contains('password')));
    expect(captured.body, isNot(contains('activeCircleId')));
    expect(tokenCalls, 1);
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
        idTokenProvider: () async => _token,
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

      final result = await source.deleteAccount();

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

      final error = await _capture(source.deleteAccount);

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

    final error = await _capture(source.deleteAccount);

    expect(error.statusCode, 200);
    expect(error.code, 'ACCOUNT_DELETE_AMBIGUOUS_RESPONSE');
    expect(error.isAmbiguous, isTrue);
  });

  for (final testCase in [
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
              'error': 'raw backend details with $_token',
              'code': testCase.code,
            }),
            testCase.status,
          ),
        ),
      );

      final error = await _capture(source.deleteAccount);

      expect(error.statusCode, testCase.status);
      expect(error.code, testCase.code);
      expect(error.message, testCase.message);
      expect(error.isAmbiguous, isFalse);
      expect(error.message, isNot(contains(_token)));
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

    final error = await _capture(source.deleteAccount);

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

    final error = await _capture(source.deleteAccount);

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

    final error = await _capture(source.deleteAccount);

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

    final error = await _capture(source.deleteAccount);

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

    final error = await _capture(source.deleteAccount);

    expect(error.code, 'ACCOUNT_DELETE_TRANSPORT_ERROR');
    expect(error.isAmbiguous, isTrue);
    expect(error.message, isNot(contains(_token)));
    expect(error.toString(), isNot(contains(_token)));
  });

  test('token ausente falha antes de enviar request', () async {
    var requests = 0;
    final source = _source(
      MockClient((_) async {
        requests += 1;
        return http.Response('{}', 200);
      }),
      tokenProvider: () async => ' ',
    );

    final error = await _capture(source.deleteAccount);

    expect(requests, 0);
    expect(error.code, 'UNAUTHENTICATED');
    expect(error.isAmbiguous, isFalse);
  });
}
