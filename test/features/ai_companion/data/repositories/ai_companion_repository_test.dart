import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:life_os/features/ai_companion/data/repositories/ai_companion_repository.dart';

const _idToken = 'firebase-id-token';
const _appCheckToken = 'firebase-app-check-token';

AICompanionRepository _repository({
  required http.Client client,
  Future<String?> Function()? idTokenProvider,
  Future<String?> Function()? appCheckTokenProvider,
}) {
  return AICompanionRepository(
    client: client,
    idTokenProvider: idTokenProvider ?? () async => _idToken,
    appCheckTokenProvider: appCheckTokenProvider ?? () async => _appCheckToken,
  );
}

void main() {
  test('token App Check válido é enviado apenas no header', () async {
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      expect(request.headers['Authorization'], 'Bearer $_idToken');
      expect(request.headers['X-Firebase-AppCheck'], _appCheckToken);
      expect(request.headers['Content-Type'], 'application/json');
      expect(request.body, isNot(contains(_idToken)));
      expect(request.body, isNot(contains(_appCheckToken)));
      expect(jsonDecode(request.body), {
        'message': 'Olá',
        'context': {'humor': 'bem'},
      });
      return http.Response(jsonEncode({'reply': 'Resposta'}), 200);
    });
    addTearDown(client.close);

    final reply = await _repository(
      client: client,
    ).sendMessageToApi('Olá', {'humor': 'bem'});

    expect(reply, 'Resposta');
    expect(requests, 1);
  });

  test('token App Check null falha fechado sem chamada HTTP', () async {
    var requests = 0;
    final client = MockClient((_) async {
      requests++;
      return http.Response('{}', 200);
    });
    addTearDown(client.close);

    await expectLater(
      _repository(
        client: client,
        appCheckTokenProvider: () async => null,
      ).sendMessageToApi('Olá', const {}),
      throwsA(isA<AIAppCheckException>()),
    );
    expect(requests, 0);
  });

  test('token App Check vazio falha fechado sem chamada HTTP', () async {
    var requests = 0;
    final client = MockClient((_) async {
      requests++;
      return http.Response('{}', 200);
    });
    addTearDown(client.close);

    await expectLater(
      _repository(
        client: client,
        appCheckTokenProvider: () async => '   ',
      ).sendMessageToApi('Olá', const {}),
      throwsA(isA<AIAppCheckException>()),
    );
    expect(requests, 0);
  });

  test('erro ao obter App Check é sanitizado e não chama HTTP', () async {
    var requests = 0;
    final client = MockClient((_) async {
      requests++;
      return http.Response('{}', 200);
    });
    addTearDown(client.close);

    Object? capturedError;
    try {
      await _repository(
        client: client,
        appCheckTokenProvider: () async {
          throw StateError('firebase-app-check-token segredo');
        },
      ).sendMessageToApi('Olá', const {});
    } catch (error) {
      capturedError = error;
    }

    expect(capturedError, isA<AIAppCheckException>());
    expect(capturedError.toString(), isNot(contains('segredo')));
    expect(capturedError.toString(), isNot(contains(_appCheckToken)));
    expect(requests, 0);
  });

  for (final code in ['APP_CHECK_REQUIRED', 'APP_CHECK_INVALID']) {
    test('backend $code é mapeado para AIAppCheckException', () async {
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({'code': code, 'error': 'detalhe interno'}),
          401,
        ),
      );
      addTearDown(client.close);

      await expectLater(
        _repository(client: client).sendMessageToApi('Olá', const {}),
        throwsA(
          isA<AIAppCheckException>().having(
            (error) => error.message,
            'message',
            isNot(contains('detalhe interno')),
          ),
        ),
      );
    });
  }

  test(
    'HTTP 402 usa erro Premium fixo sem expor resposta do backend',
    () async {
      const sensitiveMessage = 'mensagem interna sensível';
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({'error': sensitiveMessage, 'code': 'PREMIUM_REQUIRED'}),
          402,
        ),
      );
      addTearDown(client.close);

      await expectLater(
        _repository(client: client).sendMessageToApi('Olá', const {}),
        throwsA(
          isA<AIPremiumRequiredException>()
              .having(
                (error) => error.message,
                'message',
                'O Companion IA está disponível apenas para usuários Premium.',
              )
              .having(
                (error) => error.message,
                'sanitized message',
                isNot(contains(sensitiveMessage)),
              ),
        ),
      );
    },
  );

  test('resposta 200 válida continua retornando reply', () async {
    final client = MockClient(
      (_) async => http.Response(jsonEncode({'reply': 'Tudo certo'}), 200),
    );
    addTearDown(client.close);

    final reply = await _repository(
      client: client,
    ).sendMessageToApi('Olá', const {});

    expect(reply, 'Tudo certo');
  });
}
