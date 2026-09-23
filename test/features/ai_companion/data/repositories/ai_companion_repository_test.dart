import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:life_os/features/ai_companion/data/repositories/ai_companion_repository.dart';
import 'package:life_os/features/ai_companion/data/models/ai_insight.dart';

const _idToken = 'firebase-id-token';
const _appCheckToken = 'firebase-app-check-token';
const _userA = 'user-a';
const _userB = 'user-b';

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
}
