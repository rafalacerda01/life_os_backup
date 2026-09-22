import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:life_os/features/ai_companion/data/repositories/ai_companion_repository.dart';
import 'package:life_os/features/ai_companion/data/models/ai_insight.dart';
import 'package:life_os/features/health/data/models/health_model.dart';

const _idToken = 'firebase-id-token';
const _appCheckToken = 'firebase-app-check-token';
const _userA = 'user-a';
const _userB = 'user-b';

class _Medication {
  const _Medication(this.name);

  final String name;
}

AICompanionRepository _repository({
  required http.Client client,
  Future<String?> Function()? idTokenProvider,
  Future<String?> Function()? appCheckTokenProvider,
  String? Function()? currentUserIdProvider,
  Duration? v2Timeout,
}) {
  return AICompanionRepository(
    client: client,
    idTokenProvider: idTokenProvider ?? () async => _idToken,
    appCheckTokenProvider: appCheckTokenProvider ?? () async => _appCheckToken,
    currentUserIdProvider: currentUserIdProvider ?? () => _userA,
    v2Timeout: v2Timeout ?? const Duration(seconds: 15),
  );
}

void main() {
  Map<String, Object?> v2Response({
    Object? version = 2,
    String intent = 'daily_overview',
    Map<String, Object?>? insight,
  }) => {
    'version': version,
    'intent': intent,
    'insight':
        insight ??
        {
          'headline': 'Seu dia',
          'summary': 'Resumo seguro',
          'recommendation': 'Siga em frente',
        },
  };

  test(
    'V2 envia apenas version, intent, context e tokens nos headers',
    () async {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        expect(
          request.url.toString(),
          'https://life-os-backend-gray.vercel.app/api/chat',
        );
        expect(request.headers['Authorization'], 'Bearer $_idToken');
        expect(request.headers['X-Firebase-AppCheck'], _appCheckToken);
        expect(jsonDecode(request.body), {
          'version': 2,
          'intent': 'daily_overview',
          'context': {
            'tasks': {'pending': 2},
          },
        });
        expect(request.body, isNot(contains('message')));
        expect(request.body, isNot(contains(_userA)));
        expect(request.body, isNot(contains(_idToken)));
        return http.Response(jsonEncode(v2Response()), 200);
      });
      addTearDown(client.close);

      final result = await _repository(client: client).requestInsight(
        AIInsightIntent.dailyOverview,
        const {
          'tasks': {'pending': 2},
        },
        expectedUserId: _userA,
      );
      expect(result.headline, 'Seu dia');
      expect(result.summary, 'Resumo seguro');
      expect(result.recommendation, 'Siga em frente');
      expect(calls, 1);
    },
  );

  test(
    'V2 descarta resposta de A quando sessão muda para B durante POST',
    () async {
      String? currentUid = _userA;
      final started = Completer<void>();
      final release = Completer<void>();
      final client = MockClient((_) async {
        started.complete();
        await release.future;
        return http.Response(jsonEncode(v2Response()), 200);
      });
      addTearDown(client.close);
      final pending =
          _repository(
            client: client,
            currentUserIdProvider: () => currentUid,
          ).requestInsight(
            AIInsightIntent.dailyOverview,
            const {},
            expectedUserId: _userA,
          );
      await started.future;
      currentUid = _userB;
      release.complete();
      await expectLater(pending, throwsA(isA<AIAuthenticationException>()));
    },
  );

  test('V2 UID switch before POST prevents request', () async {
    String? currentUid = _userA;
    var calls = 0;
    final client = MockClient((_) async {
      calls++;
      return http.Response(jsonEncode(v2Response()), 200);
    });
    addTearDown(client.close);
    await expectLater(
      _repository(
        client: client,
        currentUserIdProvider: () => currentUid,
        appCheckTokenProvider: () async {
          currentUid = _userB;
          return _appCheckToken;
        },
      ).requestInsight(
        AIInsightIntent.dailyOverview,
        const {},
        expectedUserId: _userA,
      ),
      throwsA(isA<AIAuthenticationException>()),
    );
    expect(calls, 0);
  });

  for (final invalid in [
    v2Response(version: 1),
    v2Response(intent: 'weekly_overview'),
    v2Response(insight: {'headline': 'ok', 'summary': 'ok'}),
    v2Response(
      insight: {
        'headline': 'ok',
        'summary': 'ok',
        'recommendation': 'ok',
        'extra': true,
      },
    ),
    v2Response(
      insight: {'headline': ' ', 'summary': 'ok', 'recommendation': 'ok'},
    ),
    v2Response(
      insight: {'headline': 'a' * 121, 'summary': 'ok', 'recommendation': 'ok'},
    ),
    v2Response(
      insight: {'headline': 'ok', 'summary': 'a' * 801, 'recommendation': 'ok'},
    ),
    v2Response(
      insight: {'headline': 'ok', 'summary': 'ok', 'recommendation': 'a' * 501},
    ),
  ]) {
    test(
      'V2 rejects malformed response ${invalid.toString().length}',
      () async {
        final client = MockClient(
          (_) async => http.Response(jsonEncode(invalid), 200),
        );
        addTearDown(client.close);
        await expectLater(
          _repository(client: client).requestInsight(
            AIInsightIntent.dailyOverview,
            const {},
            expectedUserId: _userA,
          ),
          throwsA(isA<AIServiceException>()),
        );
      },
    );
  }

  for (final status in [400, 401, 402, 429, 451, 500, 502, 503, 504]) {
    test('V2 maps HTTP $status without exposing raw body', () async {
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({'error': 'PRIVATE_BACKEND_MARKER'}),
          status,
        ),
      );
      addTearDown(client.close);
      Object? caught;
      try {
        await _repository(client: client).requestInsight(
          AIInsightIntent.dailyOverview,
          const {},
          expectedUserId: _userA,
        );
      } catch (error) {
        caught = error;
      }
      expect(caught, isA<AICompanionException>());
      expect(caught.toString(), isNot(contains('PRIVATE_BACKEND_MARKER')));
      expect(caught, switch (status) {
        400 => isA<AIBadRequestException>(),
        401 => isA<AIAuthenticationException>(),
        402 => isA<AIPremiumRequiredException>(),
        429 => isA<AIRateLimitException>(),
        451 => isA<AIConsentRequiredException>(),
        _ => isA<AIServiceException>(),
      });
    });
  }

  test('V2 network failure is sanitized', () async {
    final client = MockClient(
      (_) async => throw http.ClientException('PRIVATE_NETWORK_MARKER'),
    );
    addTearDown(client.close);
    await expectLater(
      _repository(client: client).requestInsight(
        AIInsightIntent.dailyOverview,
        const {},
        expectedUserId: _userA,
      ),
      throwsA(
        isA<AINetworkException>().having(
          (error) => error.message,
          'message',
          isNot(contains('PRIVATE_NETWORK_MARKER')),
        ),
      ),
    );
  });

  test('V2 timeout is bounded and sanitized', () async {
    final pending = Completer<http.Response>();
    final client = MockClient((_) => pending.future);
    addTearDown(client.close);
    await expectLater(
      _repository(
        client: client,
        v2Timeout: const Duration(milliseconds: 20),
      ).requestInsight(
        AIInsightIntent.dailyOverview,
        const {},
        expectedUserId: _userA,
      ),
      throwsA(isA<AITimeoutException>()),
    );
  });

  for (final code in ['APP_CHECK_REQUIRED', 'APP_CHECK_INVALID']) {
    test('V2 HTTP 401 $code maps to App Check, not raw body', () async {
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({'code': code, 'error': 'PRIVATE_BACKEND_MARKER'}),
          401,
        ),
      );
      addTearDown(client.close);
      await expectLater(
        _repository(client: client).requestInsight(
          AIInsightIntent.dailyOverview,
          const {},
          expectedUserId: _userA,
        ),
        throwsA(
          isA<AIAppCheckException>().having(
            (error) => error.message,
            'message',
            isNot(contains('PRIVATE_BACKEND_MARKER')),
          ),
        ),
      );
    });
  }

  AICompanionRepository contextRepository() {
    final repository = _repository(
      client: MockClient((_) async => http.Response('{}', 500)),
    );
    addTearDown(repository.client.close);
    return repository;
  }

  HealthModel health({
    String mood = 'bem',
    int water = 500,
    Map<String, dynamic>? cycle,
  }) {
    return HealthModel(
      mood: mood,
      waterIntakeMl: water,
      hasTakenPillToday: false,
      menstrualCycle: cycle,
      date: DateTime.now(),
    );
  }

  test('pergunta financeira inclui somente finanças agregadas', () async {
    final context = await contextRepository().getSystemContext(
      message: 'Como estão meus gastos?',
      hasConsent: true,
      health: health(
        cycle: {
          'isEnabled': true,
          'lastPeriodStart': DateTime.now(),
          'cycleLengthDays': 28,
          'periodLengthDays': 5,
        },
      ),
      medications: const [_Medication('MEDICAMENTO-SECRETO-XYZ')],
      finance: const {
        'saldo_atual': 100,
        'total_entradas': 500,
        'total_saidas': 400,
      },
    );

    expect(context, {
      'financas': {
        'saldo_atual': 100,
        'total_entradas': 500,
        'total_saidas': 400,
      },
    });
  });

  test('pergunta de hidratação inclui somente valor numérico', () async {
    final context = await contextRepository().getSystemContext(
      message: 'Estou bebendo pouca água?',
      hasConsent: true,
      health: health(water: 1500),
      finance: const {
        'saldo_atual': 100,
        'total_entradas': 500,
        'total_saidas': 400,
      },
    );

    expect(context, {'hidratacao_ml': 1500});
  });

  test('medicamentos enviam somente contagem sem nomes', () async {
    const secret = 'MEDICAMENTO-SECRETO-XYZ';
    final context = await contextRepository().getSystemContext(
      message: 'Quais medicamentos estão registrados?',
      hasConsent: true,
      medications: const [_Medication(secret)],
    );

    expect(context, {'medicamentos_ativos': 1});
    expect(jsonEncode(context), isNot(contains(secret)));
  });

  test(
    'ciclo envia somente fase derivada sem datas ou configurações',
    () async {
      final context = await contextRepository().getSystemContext(
        message: 'Em que fase do ciclo estou?',
        hasConsent: true,
        health: health(
          cycle: {
            'isEnabled': true,
            'lastPeriodStart': DateTime.now(),
            'cycleLengthDays': 28,
            'periodLengthDays': 5,
          },
        ),
      );

      expect(context, {'fase_ciclo': 'menstrual'});
      final serialized = jsonEncode(context);
      expect(serialized, isNot(contains('lastPeriodStart')));
      expect(serialized, isNot(contains('cycleLengthDays')));
      expect(serialized, isNot(contains('periodLengthDays')));
    },
  );

  test('produtividade permanece no escopo sem contexto pessoal', () async {
    final context = await contextRepository().getSystemContext(
      message: 'Como melhorar meu foco nos estudos?',
      hasConsent: true,
      health: health(),
      medications: const [_Medication('MEDICAMENTO-SECRETO-XYZ')],
      finance: const {
        'saldo_atual': 100,
        'total_entradas': 500,
        'total_saidas': 400,
      },
    );

    expect(context, isEmpty);
    expect(
      detectAIRelevantDomains('Como melhorar meu foco nos estudos?'),
      containsAll([AIRelevantDomain.productivity, AIRelevantDomain.study]),
    );
    expect(
      detectAIRelevantDomains('preciso estudar'),
      contains(AIRelevantDomain.study),
    );
  });

  test('bolo genérico não monta contexto pessoal', () async {
    final context = await contextRepository().getSystemContext(
      message: 'Como faço um bolo de chocolate?',
      hasConsent: true,
      health: health(),
      medications: const [_Medication('MEDICAMENTO-SECRETO-XYZ')],
      finance: const {
        'saldo_atual': 100,
        'total_entradas': 500,
        'total_saidas': 400,
      },
    );

    expect(context, isEmpty);
    expect(detectAIRelevantDomains('Como faço um bolo de chocolate?'), isEmpty);
  });

  test('finanças não liberam culinária genérica', () async {
    const message = 'Como faço um bolo de chocolate para economizar dinheiro?';
    final domains = detectAIRelevantDomains(message);
    final context = await contextRepository().getSystemContext(
      message: message,
      hasConsent: true,
      health: health(),
      medications: const [_Medication('MEDICAMENTO-SECRETO-XYZ')],
      finance: const {
        'saldo_atual': 100,
        'total_entradas': 500,
        'total_saidas': 400,
      },
    );

    expect(domains, isNot(contains(AIRelevantDomain.foodWellbeing)));
    expect(context, isEmpty);
  });

  test('Life OS não libera culinária genérica', () {
    final domains = detectAIRelevantDomains(
      'Como faço uma receita de bolo de chocolate no Life OS?',
    );

    expect(domains, isNot(contains(AIRelevantDomain.foodWellbeing)));
  });

  test('tarefas não liberam culinária genérica', () {
    final domains = detectAIRelevantDomains(
      'Como fazer bolo de chocolate como uma tarefa?',
    );

    expect(domains, isNot(contains(AIRelevantDomain.foodWellbeing)));
  });

  test('alimentação contextual a estudos continua permitida', () async {
    const message = 'O que posso comer antes de estudar para ter mais energia?';
    final domains = detectAIRelevantDomains(message);
    final context = await contextRepository().getSystemContext(
      message: message,
      hasConsent: true,
    );

    expect(
      domains,
      containsAll([AIRelevantDomain.study, AIRelevantDomain.foodWellbeing]),
    );
    expect(context, isEmpty);
  });

  test('alimentação contextual ao ciclo envia somente fase derivada', () async {
    const message =
        'Estou menstruada e com vontade de chocolate. O que posso comer?';
    final domains = detectAIRelevantDomains(message);
    final context = await contextRepository().getSystemContext(
      message: message,
      hasConsent: true,
      health: health(
        cycle: {
          'isEnabled': true,
          'lastPeriodStart': DateTime.now(),
          'cycleLengthDays': 28,
          'periodLengthDays': 5,
        },
      ),
      medications: const [_Medication('MEDICAMENTO-SECRETO-XYZ')],
      finance: const {
        'saldo_atual': 100,
        'total_entradas': 500,
        'total_saidas': 400,
      },
    );

    expect(
      domains,
      containsAll([AIRelevantDomain.cycle, AIRelevantDomain.foodWellbeing]),
    );
    expect(context, {'fase_ciclo': 'menstrual'});
  });

  test('contexto continua fail-closed sem consentimento', () async {
    await expectLater(
      contextRepository().getSystemContext(
        message: 'Como estão meus gastos?',
        hasConsent: false,
        finance: const {
          'saldo_atual': 100,
          'total_entradas': 500,
          'total_saidas': 400,
        },
      ),
      throwsA(isA<AIConsentRequiredException>()),
    );
  });

  test('sessão estável envia tokens e contexto corretamente', () async {
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
    ).sendMessageToApi('Olá', {'humor': 'bem'}, expectedUserId: _userA);

    expect(reply, 'Resposta');
    expect(requests, 1);
  });

  test('troca após ID token falha autenticada sem request HTTP', () async {
    String? currentUserId = _userA;
    var requests = 0;
    var appCheckCalls = 0;
    final client = MockClient((_) async {
      requests++;
      return http.Response('{}', 200);
    });
    addTearDown(client.close);

    await expectLater(
      _repository(
        client: client,
        currentUserIdProvider: () => currentUserId,
        idTokenProvider: () async {
          currentUserId = _userB;
          return _idToken;
        },
        appCheckTokenProvider: () async {
          appCheckCalls++;
          return _appCheckToken;
        },
      ).sendMessageToApi('Olá', const {}, expectedUserId: _userA),
      throwsA(isA<AIAuthenticationException>()),
    );

    expect(requests, 0);
    expect(appCheckCalls, 0);
  });

  test('troca durante App Check falha autenticada sem request HTTP', () async {
    String? currentUserId = _userA;
    var requests = 0;
    final client = MockClient((_) async {
      requests++;
      return http.Response('{}', 200);
    });
    addTearDown(client.close);

    await expectLater(
      _repository(
        client: client,
        currentUserIdProvider: () => currentUserId,
        appCheckTokenProvider: () async {
          currentUserId = _userB;
          return _appCheckToken;
        },
      ).sendMessageToApi('Olá', const {}, expectedUserId: _userA),
      throwsA(isA<AIAuthenticationException>()),
    );

    expect(requests, 0);
  });

  test('troca imediatamente antes do POST não envia request HTTP', () async {
    var sessionChecks = 0;
    var requests = 0;
    final client = MockClient((_) async {
      requests++;
      return http.Response('{}', 200);
    });
    addTearDown(client.close);

    await expectLater(
      _repository(
        client: client,
        currentUserIdProvider: () {
          sessionChecks++;
          return sessionChecks < 4 ? _userA : _userB;
        },
      ).sendMessageToApi('Olá', const {}, expectedUserId: _userA),
      throwsA(isA<AIAuthenticationException>()),
    );

    expect(sessionChecks, 4);
    expect(requests, 0);
  });

  test('mismatch inicial não obtém tokens nem faz request HTTP', () async {
    var requests = 0;
    var idTokenCalls = 0;
    var appCheckCalls = 0;
    final client = MockClient((_) async {
      requests++;
      return http.Response('{}', 200);
    });
    addTearDown(client.close);

    await expectLater(
      _repository(
        client: client,
        currentUserIdProvider: () => _userB,
        idTokenProvider: () async {
          idTokenCalls++;
          return _idToken;
        },
        appCheckTokenProvider: () async {
          appCheckCalls++;
          return _appCheckToken;
        },
      ).sendMessageToApi('Olá', const {}, expectedUserId: _userA),
      throwsA(isA<AIAuthenticationException>()),
    );

    expect(requests, 0);
    expect(idTokenCalls, 0);
    expect(appCheckCalls, 0);
  });

  test('logout após ID token falha autenticado sem request HTTP', () async {
    String? currentUserId = _userA;
    var requests = 0;
    final client = MockClient((_) async {
      requests++;
      return http.Response('{}', 200);
    });
    addTearDown(client.close);

    await expectLater(
      _repository(
        client: client,
        currentUserIdProvider: () => currentUserId,
        idTokenProvider: () async {
          currentUserId = null;
          return _idToken;
        },
      ).sendMessageToApi('Olá', const {}, expectedUserId: _userA),
      throwsA(isA<AIAuthenticationException>()),
    );

    expect(requests, 0);
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
      ).sendMessageToApi('Olá', const {}, expectedUserId: _userA),
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
      ).sendMessageToApi('Olá', const {}, expectedUserId: _userA),
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
      ).sendMessageToApi('Olá', const {}, expectedUserId: _userA);
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
        _repository(
          client: client,
        ).sendMessageToApi('Olá', const {}, expectedUserId: _userA),
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
        _repository(
          client: client,
        ).sendMessageToApi('Olá', const {}, expectedUserId: _userA),
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
    ).sendMessageToApi('Olá', const {}, expectedUserId: _userA);

    expect(reply, 'Tudo certo');
  });
}
