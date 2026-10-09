import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:life_os/core/database/local_mutation_gate.dart';
import 'package:life_os/core/database/remote_send_permit.dart';
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
  RemoteSendPermit Function()? captureRemoteSend,
}) {
  return FocusRemoteDataSource(
    client: client,
    idTokenProvider: tokenProvider ?? () async => _token,
    appCheckTokenProvider: appCheckTokenProvider ?? () async => _appCheckToken,
    baseUrl: _baseUrl,
    timeout: timeout,
    captureRemoteSend: captureRemoteSend ?? () => RemoteSendPermit(() => true),
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

class _Session {
  String? uid = 'a';
  int captures = 0;
  late final gate = LocalMutationGate(ownerUid: 'a')
    ..bindSessionReader(() => uid)
    ..openPreparedSession();

  RemoteSendPermit capture() {
    captures++;
    return gate.captureRemoteSend(expectedUid: 'a');
  }

  void change(String? nextUid) {
    uid = nextUid;
    gate.observeSession(nextUid);
  }
}

Future<Object> _invoke(
  String operation,
  FocusRemoteDataSource source, {
  RemoteSendPermit? admission,
}) => switch (operation) {
  'start' => source.startFocus(
    targetId: 'task-1',
    targetType: FocusRemoteTargetType.task,
    plannedDurationSeconds: 1500,
    admission: admission,
  ),
  'finish' => source.finishFocus(
    sessionId: 'session-finish',
    admission: admission,
  ),
  _ => source.cancelFocus(sessionId: 'session-cancel', admission: admission),
};

http.Response _success(String operation) => http.Response(
  jsonEncode(switch (operation) {
    'start' => _startResponse,
    'finish' => _finishResponse,
    _ => _cancelResponse,
  }),
  200,
);

void main() {
  group('remote session admission', () {
    for (final operation in ['start', 'finish', 'cancel']) {
      test(
        '$operation: original cycle admission is never replaced after relogin',
        () async {
          final session = _Session();
          final original = session.capture();
          session.change(null);
          session.change('a');
          session.gate.openPreparedSession();
          var posts = 0;
          final source = _dataSource(
            MockClient((_) async {
              posts++;
              return _success(operation);
            }),
            captureRemoteSend: session.capture,
          );
          final error = await _captureRemoteException(
            () => _invoke(operation, source, admission: original),
          );
          expect(error.code, 'SESSION_STOPPED');
          expect(posts, 0);
          expect(session.captures, 1);
        },
      );
      for (final phase in ['ID Token', 'App Check']) {
        for (final transition in [
          'logout',
          'A-B',
          'A-null-A',
          'abort logout',
        ]) {
          test(
            '$operation: $phase pending then $transition sends no POST',
            () async {
              final session = _Session();
              final started = Completer<void>();
              final token = Completer<String?>();
              var posts = 0;
              var idLoads = 0;
              var appLoads = 0;
              final source = _dataSource(
                MockClient((_) async {
                  posts++;
                  return _success(operation);
                }),
                captureRemoteSend: session.capture,
                tokenProvider: () {
                  idLoads++;
                  if (phase == 'ID Token' && !started.isCompleted) {
                    started.complete();
                    return token.future;
                  }
                  return Future.value(_token);
                },
                appCheckTokenProvider: () {
                  appLoads++;
                  if (phase == 'App Check' && !started.isCompleted) {
                    started.complete();
                    return token.future;
                  }
                  return Future.value(_appCheckToken);
                },
              );
              final result = _captureRemoteException(
                () => _invoke(operation, source),
              );
              await started.future;
              final barrier = session.gate.beginQuiesce('a');
              // Remote admission owns no lease: draining does not wait for token.
              await barrier.drain();
              expect(token.isCompleted, isFalse);
              switch (transition) {
                case 'logout':
                  session.change(null);
                  barrier.finish(signOutConfirmed: true);
                case 'A-B':
                  session.change('b');
                  barrier.finish(signOutConfirmed: true);
                case 'A-null-A':
                  session.change(null);
                  barrier.finish(signOutConfirmed: true);
                  session.change('a');
                  session.gate.openPreparedSession();
                case 'abort logout':
                  barrier.finish(signOutConfirmed: false);
              }
              token.complete(phase == 'ID Token' ? _token : _appCheckToken);
              final error = await result;
              expect(error.code, 'SESSION_STOPPED');
              expect(error.isRetryable, isFalse);
              expect(error.isAmbiguous, isFalse);
              expect(posts, 0);
              expect(session.captures, 1);
              expect(idLoads, 1);
              expect(appLoads, phase == 'App Check' ? 1 : 0);
              for (final secret in [_token, _appCheckToken]) {
                expect(error.toString(), isNot(contains(secret)));
              }
              if (transition == 'abort logout' || transition == 'A-null-A') {
                await _invoke(operation, source);
                expect(posts, 1);
                expect(session.captures, 2);
              }
            },
          );
        }
      }

      test(
        '$operation: response after logout is ambiguous and discarded',
        () async {
          final session = _Session();
          final sent = Completer<void>();
          final response = Completer<http.Response>();
          var posts = 0;
          final source = _dataSource(
            MockClient((_) {
              posts++;
              sent.complete();
              return response.future;
            }),
            captureRemoteSend: session.capture,
          );
          final result = _captureRemoteException(
            () => _invoke(operation, source),
          );
          await sent.future;
          final barrier = session.gate.beginQuiesce('a');
          await barrier.drain();
          session.change(null);
          barrier.finish(signOutConfirmed: true);
          response.complete(_success(operation));
          final error = await result;
          expect(error.code, 'SESSION_STOPPED');
          expect(error.isAmbiguous, isTrue);
          expect(error.isRetryable, isFalse);
          expect(posts, 1);
          expect(session.captures, 1);
        },
      );

      test('$operation: final synchronous validation blocks POST', () async {
        var checks = 0;
        var posts = 0;
        var appLoaded = false;
        final source = _dataSource(
          MockClient((_) async {
            posts++;
            return _success(operation);
          }),
          captureRemoteSend: () => RemoteSendPermit(() => ++checks < 4),
          appCheckTokenProvider: () async {
            appLoaded = true;
            return _appCheckToken;
          },
        );
        final error = await _captureRemoteException(
          () => _invoke(operation, source),
        );
        expect(error.code, 'SESSION_STOPPED');
        expect(error.isAmbiguous, isFalse);
        expect(checks, 4);
        expect(appLoaded, isTrue);
        expect(posts, 0);
      });
    }

    test(
      'no configured admission fails closed before providers or HTTP',
      () async {
        var loads = 0;
        var posts = 0;
        final source = FocusRemoteDataSource(
          client: MockClient((_) async {
            posts++;
            return _success('start');
          }),
          idTokenProvider: () async {
            loads++;
            return _token;
          },
          appCheckTokenProvider: () async {
            loads++;
            return _appCheckToken;
          },
          baseUrl: _baseUrl,
        );
        final error = await _captureRemoteException(
          () => _invoke('start', source),
        );
        expect(error.code, 'SESSION_STOPPED');
        expect(error.isAmbiguous, isFalse);
        expect(loads, 0);
        expect(posts, 0);
      },
    );

    test('A cannot capture an operation in session B', () async {
      final session = _Session()..change('b');
      var posts = 0;
      final source = _dataSource(
        MockClient((_) async {
          posts++;
          return _success('start');
        }),
        captureRemoteSend: session.capture,
      );
      final error = await _captureRemoteException(
        () => _invoke('start', source),
      );
      expect(error.code, 'SESSION_STOPPED');
      expect(posts, 0);
    });

    test('backend errors redact tokens without changing known codes', () async {
      final source = _dataSource(
        MockClient(
          (_) async => http.Response(
            jsonEncode({
              'code': 'TARGET_NOT_FOUND',
              'error': 'detail $_token $_appCheckToken',
            }),
            404,
          ),
        ),
      );
      final error = await _captureRemoteException(
        () => _invoke('start', source),
      );
      expect(error.code, 'TARGET_NOT_FOUND');
      expect(error.statusCode, 404);
      expect(error.isAmbiguous, isFalse);
      for (final secret in [_token, _appCheckToken]) {
        expect(error.toString(), isNot(contains(secret)));
      }
    });

    for (final status in [200, 500, 408]) {
      test(
        'sent response $status with no confirmation remains ambiguous',
        () async {
          final source = _dataSource(
            MockClient((_) async => http.Response('{}', status)),
          );
          final error = await _captureRemoteException(
            () => _invoke('start', source),
          );
          expect(error.isAmbiguous, isTrue);
        },
      );
    }

    test('unexpected transport errors are sanitized and ambiguous', () async {
      final source = _dataSource(
        MockClient((_) async {
          throw StateError('private $_token $_appCheckToken');
        }),
      );
      final error = await _captureRemoteException(
        () => _invoke('finish', source),
      );
      expect(error.code, 'FOCUS_FINISH_FAILED');
      expect(error.isAmbiguous, isTrue);
      for (final secret in [_token, _appCheckToken, 'private']) {
        expect(error.toString(), isNot(contains(secret)));
      }
    });

    test('transport errors are ambiguous and never expose tokens', () async {
      var posts = 0;
      final source = _dataSource(
        MockClient((request) async {
          posts++;
          throw http.ClientException(
            'private $_token $_appCheckToken',
            request.url,
          );
        }),
      );
      final error = await _captureRemoteException(
        () => _invoke('cancel', source),
      );
      expect(error.code, 'FOCUS_CANCEL_FAILED');
      expect(error.isRetryable, isTrue);
      expect(error.isAmbiguous, isTrue);
      expect(posts, 1);
      for (final secret in [_token, _appCheckToken, 'private']) {
        expect(error.toString(), isNot(contains(secret)));
      }
    });
  });
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
