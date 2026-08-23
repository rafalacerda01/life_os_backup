import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:life_os/features/circles/data/remote/circle_delete_remote_data_source.dart';

const _url = 'https://example.test/api/circles/delete';
const _token = 'sensitive-token';

CircleDeleteRemoteDataSource source(
  MockClient client, {
  CircleIdTokenProvider? tokenProvider,
  Duration timeout = const Duration(seconds: 30),
}) {
  return CircleDeleteRemoteDataSource(
    client: client,
    idTokenProvider: tokenProvider ?? () async => _token,
    url: _url,
    timeout: timeout,
  );
}

Future<CircleDeleteRemoteException> capture(
  Future<void> Function() action,
) async {
  try {
    await action();
    fail('Expected CircleDeleteRemoteException.');
  } on CircleDeleteRemoteException catch (error) {
    return error;
  }
}

void main() {
  test('200 com deleted true confirma sucesso', () async {
    late http.Request captured;
    final dataSource = source(
      MockClient((request) async {
        captured = request;
        return http.Response(jsonEncode({'deleted': true}), 200);
      }),
    );

    await dataSource.deleteCircle('circle-1');

    expect(captured.method, 'POST');
    expect(captured.url, Uri.parse(_url));
    expect(captured.headers['authorization'], 'Bearer $_token');
    expect(jsonDecode(captured.body), {'circleId': 'circle-1'});
    expect(captured.body, isNot(contains('uid')));
    expect(captured.body, isNot(contains('adminUid')));
  });

  test('timeout permanece ambíguo', () async {
    final dataSource = source(
      MockClient((_) => Completer<http.Response>().future),
      timeout: const Duration(milliseconds: 1),
    );

    final error = await capture(() => dataSource.deleteCircle('circle-1'));

    expect(error.code, 'CIRCLE_DELETE_TIMEOUT');
    expect(error.isAmbiguous, isTrue);
  });

  test('404 CIRCLE_NOT_FOUND confirma sucesso idempotente', () async {
    final dataSource = source(
      MockClient(
        (_) async => http.Response(
          jsonEncode({
            'code': 'CIRCLE_NOT_FOUND',
            'error': 'Circle não encontrado.',
          }),
          404,
        ),
      ),
    );

    await expectLater(dataSource.deleteCircle('circle-1'), completes);
  });

  test('404 com outro code continua erro', () async {
    final dataSource = source(
      MockClient(
        (_) async =>
            http.Response(jsonEncode({'code': 'CIRCLE_STATE_CONFLICT'}), 404),
      ),
    );

    final error = await capture(() => dataSource.deleteCircle('circle-1'));

    expect(error.statusCode, 404);
    expect(error.code, 'CIRCLE_STATE_CONFLICT');
    expect(error.isAmbiguous, isFalse);
  });

  test('404 com JSON inválido continua erro', () async {
    final dataSource = source(
      MockClient((_) async => http.Response('not-json', 404)),
    );

    final error = await capture(() => dataSource.deleteCircle('circle-1'));

    expect(error.statusCode, 404);
    expect(error.code, 'CIRCLE_DELETE_FAILED');
    expect(error.isAmbiguous, isFalse);
  });

  test('403 CIRCLE_ADMIN_REQUIRED continua não ambíguo', () async {
    final dataSource = source(
      MockClient(
        (_) async =>
            http.Response(jsonEncode({'code': 'CIRCLE_ADMIN_REQUIRED'}), 403),
      ),
    );

    final error = await capture(() => dataSource.deleteCircle('circle-1'));

    expect(error.statusCode, 403);
    expect(error.code, 'CIRCLE_ADMIN_REQUIRED');
    expect(error.isAmbiguous, isFalse);
  });

  test('rejeita configuração HTTP', () {
    expect(
      () => CircleDeleteRemoteDataSource(
        client: MockClient((_) async => http.Response('{}', 200)),
        idTokenProvider: () async => _token,
        url: 'http://example.test/api/circles/delete',
      ),
      throwsArgumentError,
    );
  });

  test('erro do backend não é tratado como sucesso nem expõe token', () async {
    final dataSource = source(
      MockClient(
        (_) async => http.Response(
          jsonEncode({
            'code': 'CIRCLE_STATE_CONFLICT',
            'error': 'internal $_token',
          }),
          409,
        ),
      ),
    );

    final error = await capture(() => dataSource.deleteCircle('circle-1'));

    expect(error.statusCode, 409);
    expect(error.code, 'CIRCLE_STATE_CONFLICT');
    expect(error.isAmbiguous, isFalse);
    expect(error.message, isNot(contains(_token)));
    expect(error.toString(), isNot(contains(_token)));
  });

  test('500 continua ambíguo', () async {
    final dataSource = source(
      MockClient((_) async => http.Response('internal failure', 500)),
    );

    final error = await capture(() => dataSource.deleteCircle('circle-1'));

    expect(error.statusCode, 500);
    expect(error.code, 'CIRCLE_DELETE_SERVER_ERROR');
    expect(error.isAmbiguous, isTrue);
  });

  test('resposta 200 ambígua nunca é sucesso', () async {
    final dataSource = source(
      MockClient(
        (_) async => http.Response(jsonEncode({'deleted': false}), 200),
      ),
    );

    final error = await capture(() => dataSource.deleteCircle('circle-1'));

    expect(error.statusCode, 200);
    expect(error.code, 'CIRCLE_DELETE_AMBIGUOUS_RESPONSE');
    expect(error.isAmbiguous, isTrue);
  });

  test('token ausente impede request', () async {
    var requests = 0;
    final dataSource = source(
      MockClient((_) async {
        requests += 1;
        return http.Response('{}', 200);
      }),
      tokenProvider: () async => null,
    );

    final error = await capture(() => dataSource.deleteCircle('circle-1'));

    expect(requests, 0);
    expect(error.code, 'UNAUTHENTICATED');
  });
}
