import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:life_os/features/focus/data/remote/focus_remote_data_source.dart';

const _baseUrl = 'https://example.test/api/focus';
const _token = 'firebase-id-token';
const _appCheckToken = 'firebase-app-check-token';
const _appCheckMessage =
    'Não foi possível validar a segurança do aplicativo. Tente novamente.';

Map<String, dynamic> get _startResponse => {
  'sessionId': 'session-start',
  'status': 'RUNNING',
  'plannedDurationSeconds': 1500,
  'startedAt': '2026-08-17T12:00:00.000Z',
  'expiresAt': '2026-08-17T12:35:00.000Z',
  'reused': false,
};

Map<String, dynamic> get _finishResponse => {
  'sessionId': 'session-finish',
  'status': 'COMPLETED',
  'verifiedDurationSeconds': 1500,
  'completedAt': '2026-08-17T12:25:00.000Z',
  'replayed': false,
};

Map<String, dynamic> get _cancelResponse => {
  'sessionId': 'session-cancel',
  'status': 'CANCELLED',
  'cancelledAt': '2026-08-17T12:05:00.000Z',
  'replayed': true,
};

FocusRemoteDataSource _dataSource(
  MockClient client, {
  FocusIdTokenProvider? tokenProvider,
  FocusAppCheckTokenProvider? appCheckTokenProvider,
  Duration timeout = FocusRemoteDataSource.defaultTimeout,
}) {
  return FocusRemoteDataSource(
    client: client,
    idTokenProvider: tokenProvider ?? () async => _token,
    appCheckTokenProvider: appCheckTokenProvider ?? () async => _appCheckToken,
    baseUrl: _baseUrl,
    timeout: timeout,
  );
}

Future<FocusRemoteException> _captureRemoteException(
  Future<Object?> Function() action,
) async {
  try {
    await action();
    fail('Expected FocusRemoteException.');
  } on FocusRemoteException catch (error) {
    return error;
  }
}

void main() {
  group('App Check', () {
    test('start envia tokens e payload exatos com App Check trimado', () async {
      late http.Request request;
      var idTokenLoaded = false;
      final remote = _dataSource(
        MockClient((received) async {
          request = received;
          return http.Response(jsonEncode(_startResponse), 200);
        }),
        tokenProvider: () async {
          idTokenLoaded = true;
          return _token;
        },
        appCheckTokenProvider: () async {
          expect(idTokenLoaded, isTrue);
          return '  $_appCheckToken  ';
        },
      );
      await remote.startFocus(
        targetId: 'task-1',
        targetType: FocusRemoteTargetType.task,
        plannedDurationSeconds: 1500,
      );
      expect(request.method, 'POST');
      expect(request.url, Uri.parse('$_baseUrl/start'));
      expect(request.headers['authorization'], 'Bearer $_token');
      expect(request.headers['x-firebase-appcheck'], _appCheckToken);
      expect(request.headers['content-type'], 'application/json');
      expect(
        request.body,
        jsonEncode({
          'targetId': 'task-1',
          'targetType': 'TASK',
          'plannedDurationSeconds': 1500,
        }),
      );
    });

    test(
      'finish envia tokens e payload exatos com App Check trimado',
      () async {
        late http.Request request;
        var idTokenLoaded = false;
        final remote = _dataSource(
          MockClient((received) async {
            request = received;
            return http.Response(jsonEncode(_finishResponse), 200);
          }),
          tokenProvider: () async {
            idTokenLoaded = true;
            return _token;
          },
          appCheckTokenProvider: () async {
            expect(idTokenLoaded, isTrue);
            return '  $_appCheckToken  ';
          },
        );
        await remote.finishFocus(sessionId: 'session-finish');
        expect(request.method, 'POST');
        expect(request.url, Uri.parse('$_baseUrl/finish'));
        expect(request.headers['authorization'], 'Bearer $_token');
        expect(request.headers['x-firebase-appcheck'], _appCheckToken);
        expect(request.headers['content-type'], 'application/json');
        expect(request.body, jsonEncode({'sessionId': 'session-finish'}));
      },
    );

    test(
      'cancel envia tokens e payload exatos com App Check trimado',
      () async {
        late http.Request request;
        var idTokenLoaded = false;
        final remote = _dataSource(
          MockClient((received) async {
            request = received;
            return http.Response(jsonEncode(_cancelResponse), 200);
          }),
          tokenProvider: () async {
            idTokenLoaded = true;
            return _token;
          },
          appCheckTokenProvider: () async {
            expect(idTokenLoaded, isTrue);
            return '  $_appCheckToken  ';
          },
        );
        await remote.cancelFocus(sessionId: 'session-cancel');
        expect(request.method, 'POST');
        expect(request.url, Uri.parse('$_baseUrl/cancel'));
        expect(request.headers['authorization'], 'Bearer $_token');
        expect(request.headers['x-firebase-appcheck'], _appCheckToken);
        expect(request.headers['content-type'], 'application/json');
        expect(request.body, jsonEncode({'sessionId': 'session-cancel'}));
      },
    );

    for (final token in <String?>[null, '', '   ']) {
      test('token ausente/vazio ($token) impede HTTP', () async {
        var requests = 0;
        final remote = _dataSource(
          MockClient((_) async {
            requests += 1;
            return http.Response(jsonEncode(_finishResponse), 200);
          }),
          appCheckTokenProvider: () async => token,
        );
        final error = await _captureRemoteException(
          () => remote.finishFocus(sessionId: 'session-finish'),
        );
        expect(requests, 0);
        expect(error.statusCode, isNull);
        expect(error.code, 'APP_CHECK_REQUIRED');
        expect(error.message, _appCheckMessage);
        expect(error.isRetryable, isFalse);
      });
    }

    test('falha do provider impede HTTP e nao expoe detalhes', () async {
      var requests = 0;
      final remote = _dataSource(
        MockClient((_) async {
          requests += 1;
          return http.Response(jsonEncode(_finishResponse), 200);
        }),
        appCheckTokenProvider: () async {
          throw StateError('private-provider-error $_appCheckToken $_token');
        },
      );
      final error = await _captureRemoteException(
        () => remote.finishFocus(sessionId: 'session-finish'),
      );
      expect(requests, 0);
      expect(error.statusCode, isNull);
      expect(error.code, 'APP_CHECK_INVALID');
      expect(error.message, _appCheckMessage);
      expect(error.isRetryable, isTrue);
      for (final secret in [_appCheckToken, _token, 'private-provider-error']) {
        expect(error.message, isNot(contains(secret)));
        expect(error.toString(), isNot(contains(secret)));
      }
    });

    test('timeout do provider impede HTTP', () async {
      var requests = 0;
      final remote = _dataSource(
        MockClient((_) async {
          requests += 1;
          return http.Response(jsonEncode(_finishResponse), 200);
        }),
        appCheckTokenProvider: () => Completer<String?>().future,
        timeout: const Duration(milliseconds: 1),
      );
      final error = await _captureRemoteException(
        () => remote.finishFocus(sessionId: 'session-finish'),
      );
      expect(requests, 0);
      expect(error.code, 'APP_CHECK_INVALID');
      expect(error.message, _appCheckMessage);
      expect(error.isRetryable, isTrue);
    });

    for (final code in ['APP_CHECK_REQUIRED', 'APP_CHECK_INVALID']) {
      test('401 $code usa mensagem local sanitizada', () async {
        final remote = _dataSource(
          MockClient(
            (_) async => http.Response(
              jsonEncode({
                'code': code,
                'error': 'private-backend-error $_appCheckToken $_token',
              }),
              401,
            ),
          ),
        );
        final error = await _captureRemoteException(
          () => remote.finishFocus(sessionId: 'session-finish'),
        );
        expect(error.statusCode, 401);
        expect(error.code, code);
        expect(error.message, _appCheckMessage);
        expect(error.isRetryable, isFalse);
        for (final secret in [
          _appCheckToken,
          _token,
          'private-backend-error',
        ]) {
          expect(error.message, isNot(contains(secret)));
          expect(error.toString(), isNot(contains(secret)));
        }
      });
    }
  });

  group('startFocus', () {
    test('uses the configured start URL', () async {
      late Uri capturedUrl;
      final source = _dataSource(
        MockClient((request) async {
          capturedUrl = request.url;
          return http.Response(jsonEncode(_startResponse), 200);
        }),
      );

      await source.startFocus(
        targetId: 'task-1',
        targetType: FocusRemoteTargetType.task,
        plannedDurationSeconds: 1500,
      );

      expect(capturedUrl, Uri.parse('$_baseUrl/start'));
    });

    test('sends the Firebase Bearer token', () async {
      late String? authorization;
      final source = _dataSource(
        MockClient((request) async {
          authorization = request.headers['authorization'];
          return http.Response(jsonEncode(_startResponse), 200);
        }),
      );

      await source.startFocus(
        targetId: 'task-1',
        targetType: FocusRemoteTargetType.task,
        plannedDurationSeconds: 1500,
      );

      expect(authorization, 'Bearer $_token');
    });

    test('sends only the exact start payload', () async {
      late Object? payload;
      final source = _dataSource(
        MockClient((request) async {
          payload = jsonDecode(request.body);
          return http.Response(jsonEncode(_startResponse), 200);
        }),
      );

      await source.startFocus(
        targetId: 'task-1',
        targetType: FocusRemoteTargetType.task,
        plannedDurationSeconds: 1500,
      );

      expect(payload, {
        'targetId': 'task-1',
        'targetType': 'TASK',
        'plannedDurationSeconds': 1500,
      });
    });

    test('serializes TASK exactly', () async {
      late Map<String, dynamic> payload;
      final source = _dataSource(
        MockClient((request) async {
          payload = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(jsonEncode(_startResponse), 200);
        }),
      );

      await source.startFocus(
        targetId: 'task-1',
        targetType: FocusRemoteTargetType.task,
        plannedDurationSeconds: 1500,
      );

      expect(payload['targetType'], 'TASK');
    });

    test('serializes SUBJECT exactly', () async {
      late Map<String, dynamic> payload;
      final response = {..._startResponse, 'plannedDurationSeconds': 600};
      final source = _dataSource(
        MockClient((request) async {
          payload = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(jsonEncode(response), 200);
        }),
      );

      await source.startFocus(
        targetId: 'subject-1',
        targetType: FocusRemoteTargetType.subject,
        plannedDurationSeconds: 600,
      );

      expect(payload['targetType'], 'SUBJECT');
    });

    test('parses a valid RUNNING response', () async {
      final source = _dataSource(
        MockClient((_) async => http.Response(jsonEncode(_startResponse), 200)),
      );

      final result = await source.startFocus(
        targetId: 'task-1',
        targetType: FocusRemoteTargetType.task,
        plannedDurationSeconds: 1500,
      );

      expect(result.sessionId, 'session-start');
      expect(result.plannedDurationSeconds, 1500);
      expect(result.startedAt.isUtc, isTrue);
      expect(result.expiresAt.isAfter(result.startedAt), isTrue);
      expect(result.reused, isFalse);
    });
  });

  test('finish sends only sessionId', () async {
    late Object? payload;
    final source = _dataSource(
      MockClient((request) async {
        payload = jsonDecode(request.body);
        return http.Response(jsonEncode(_finishResponse), 200);
      }),
    );

    await source.finishFocus(sessionId: 'session-finish');

    expect(payload, {'sessionId': 'session-finish'});
  });

  test('cancel sends only sessionId', () async {
    late Object? payload;
    final source = _dataSource(
      MockClient((request) async {
        payload = jsonDecode(request.body);
        return http.Response(jsonEncode(_cancelResponse), 200);
      }),
    );

    await source.cancelFocus(sessionId: 'session-cancel');

    expect(payload, {'sessionId': 'session-cancel'});
  });

  test(
    'parses a valid COMPLETED response without calculating duration',
    () async {
      final source = _dataSource(
        MockClient(
          (_) async => http.Response(jsonEncode(_finishResponse), 200),
        ),
      );

      final result = await source.finishFocus(sessionId: 'session-finish');

      expect(result.sessionId, 'session-finish');
      expect(result.verifiedDurationSeconds, 1500);
      expect(result.completedAt.isUtc, isTrue);
      expect(result.replayed, isFalse);
    },
  );

  test('parses a valid CANCELLED response', () async {
    final source = _dataSource(
      MockClient((_) async => http.Response(jsonEncode(_cancelResponse), 200)),
    );

    final result = await source.cancelFocus(sessionId: 'session-cancel');

    expect(result.sessionId, 'session-cancel');
    expect(result.cancelledAt.isUtc, isTrue);
    expect(result.replayed, isTrue);
  });

  group('backend errors', () {
    for (final testCase in [
      (status: 401, code: 'UNAUTHENTICATED'),
      (status: 404, code: 'TARGET_NOT_FOUND'),
      (status: 409, code: 'SESSION_NOT_READY'),
    ]) {
      test('preserves ${testCase.status} ${testCase.code}', () async {
        final source = _dataSource(
          MockClient(
            (_) async => http.Response(
              jsonEncode({'error': 'Backend message', 'code': testCase.code}),
              testCase.status,
            ),
          ),
        );

        final error = await _captureRemoteException(
          () => source.startFocus(
            targetId: 'task-1',
            targetType: FocusRemoteTargetType.task,
            plannedDurationSeconds: 1500,
          ),
        );

        expect(error.statusCode, testCase.status);
        expect(error.code, testCase.code);
        expect(error.message, 'Backend message');
        expect(error.isRetryable, isFalse);
      });
    }

    test('marks 429 as retryable', () async {
      final source = _dataSource(
        MockClient(
          (_) async => http.Response(
            jsonEncode({'error': 'Slow down', 'code': 'RATE_LIMITED'}),
            429,
          ),
        ),
      );

      final error = await _captureRemoteException(
        () => source.cancelFocus(sessionId: 'session-cancel'),
      );

      expect(error.code, 'RATE_LIMITED');
      expect(error.statusCode, 429);
      expect(error.isRetryable, isTrue);
    });

    test('marks 500 as retryable', () async {
      final source = _dataSource(
        MockClient(
          (_) async => http.Response(
            jsonEncode({'error': 'Unavailable', 'code': 'FOCUS_FINISH_FAILED'}),
            500,
          ),
        ),
      );

      final error = await _captureRemoteException(
        () => source.finishFocus(sessionId: 'session-finish'),
      );

      expect(error.code, 'FOCUS_FINISH_FAILED');
      expect(error.statusCode, 500);
      expect(error.isRetryable, isTrue);
    });
  });

  group('malformed success responses', () {
    for (final testCase in [
      (name: 'empty body', body: ''),
      (name: 'invalid JSON', body: '{invalid'),
      (name: 'non-map JSON', body: '[]'),
      (name: 'missing fields', body: '{"sessionId":"only"}'),
      (
        name: 'incorrect field type',
        body: jsonEncode({..._startResponse, 'reused': 'false'}),
      ),
    ]) {
      test('${testCase.name} becomes a typed exception', () async {
        final source = _dataSource(
          MockClient((_) async => http.Response(testCase.body, 200)),
        );

        final error = await _captureRemoteException(
          () => source.startFocus(
            targetId: 'task-1',
            targetType: FocusRemoteTargetType.task,
            plannedDurationSeconds: 1500,
          ),
        );

        expect(error, isNot(isA<TypeError>()));
        expect(error.statusCode, 200);
        expect(error.code, 'FOCUS_START_FAILED');
        expect(error.isRetryable, isFalse);
      });
    }
  });

  test('missing token is UNAUTHENTICATED and performs no request', () async {
    var requestCount = 0;
    final source = _dataSource(
      MockClient((_) async {
        requestCount += 1;
        return http.Response(jsonEncode(_startResponse), 200);
      }),
      tokenProvider: () async => '   ',
    );

    final error = await _captureRemoteException(
      () => source.startFocus(
        targetId: 'task-1',
        targetType: FocusRemoteTargetType.task,
        plannedDurationSeconds: 1500,
      ),
    );

    expect(error.code, 'UNAUTHENTICATED');
    expect(error.statusCode, isNull);
    expect(error.isRetryable, isFalse);
    expect(requestCount, 0);
  });

  test('token provider failure is retryable and performs no request', () async {
    var requestCount = 0;
    final source = _dataSource(
      MockClient((_) async {
        requestCount += 1;
        return http.Response(jsonEncode(_finishResponse), 200);
      }),
      tokenProvider: () async => throw Exception('temporary refresh failure'),
    );

    final error = await _captureRemoteException(
      () => source.finishFocus(sessionId: 'session-finish'),
    );

    expect(error.statusCode, isNull);
    expect(error.code, 'FOCUS_FINISH_FAILED');
    expect(error.isRetryable, isTrue);
    expect(requestCount, 0);
  });

  test(
    'ClientException is typed as retryable without automatic retry',
    () async {
      var requestCount = 0;
      final source = _dataSource(
        MockClient((request) async {
          requestCount += 1;
          throw http.ClientException('offline', request.url);
        }),
      );

      final error = await _captureRemoteException(
        () => source.cancelFocus(sessionId: 'session-cancel'),
      );

      expect(error.code, 'FOCUS_CANCEL_FAILED');
      expect(error.isRetryable, isTrue);
      expect(requestCount, 1);
    },
  );

  test(
    'request timeout is typed as retryable without automatic retry',
    () async {
      var requestCount = 0;
      final source = _dataSource(
        MockClient((_) async {
          requestCount += 1;
          await Future<void>.delayed(const Duration(milliseconds: 50));
          return http.Response(jsonEncode(_finishResponse), 200);
        }),
        timeout: const Duration(milliseconds: 1),
      );

      final error = await _captureRemoteException(
        () => source.finishFocus(sessionId: 'session-finish'),
      );

      expect(error.code, 'FOCUS_FINISH_FAILED');
      expect(error.isRetryable, isTrue);
      expect(requestCount, 1);
    },
  );
}
