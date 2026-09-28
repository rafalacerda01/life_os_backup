import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:life_os/features/circles/data/remote/circle_leave_remote_data_source.dart';

CircleLeaveRemoteDataSource source(
  MockClient client, {
  Future<String?> Function()? auth,
  Future<String?> Function()? appCheck,
  Duration timeout = const Duration(seconds: 30),
}) => CircleLeaveRemoteDataSource(
  client: client,
  idTokenProvider: auth ?? () async => 'auth-token',
  appCheckTokenProvider: appCheck ?? () async => 'app-token',
  timeout: timeout,
);

Future<CircleLeaveRemoteException> capture(
  Future<void> Function() action,
) async {
  try {
    await action();
    fail('Expected failure');
  } on CircleLeaveRemoteException catch (error) {
    return error;
  }
}

void main() {
  test(
    'success sends only circleId and the two tokens to the approved endpoint',
    () async {
      late http.Request request;
      final remote = source(
        MockClient((value) async {
          request = value;
          return http.Response('{"left":true}', 200);
        }),
      );
      await remote.leaveCircle('circle');
      expect(
        request.url.toString(),
        'https://life-os-backend-gray.vercel.app/api/circles/leave',
      );
      expect(request.method, 'POST');
      expect(request.followRedirects, false);
      expect(request.headers['authorization'], 'Bearer auth-token');
      expect(request.headers['x-firebase-appcheck'], 'app-token');
      expect(request.headers['content-type'], 'application/json');
      expect(jsonDecode(request.body), {'circleId': 'circle'});
    },
  );
  for (final app in [false, true]) {
    test('${app ? "App Check" : "Auth"} missing prevents HTTP', () async {
      var calls = 0;
      final remote = source(
        MockClient((_) async {
          calls++;
          return http.Response('{}', 200);
        }),
        auth: app ? null : () async => null,
        appCheck: app ? () async => null : null,
      );
      final error = await capture(() => remote.leaveCircle('circle'));
      expect(error.code, app ? 'APP_CHECK_REQUIRED' : 'UNAUTHENTICATED');
      expect(error.isAmbiguous, false);
      expect(calls, 0);
    });
  }
  test('App Check provider failure remains sanitized without HTTP', () async {
    final remote = source(
      MockClient((_) async {
        fail('Must not send');
      }),
      appCheck: () async => throw StateError('private-marker'),
    );
    final error = await capture(() => remote.leaveCircle('circle'));
    expect(error.code, 'APP_CHECK_INVALID');
    expect(error.message, isNot(contains('private-marker')));
  });
  test('timeout is ambiguous and never confirms leave', () async {
    final pending = Completer<http.Response>();
    final remote = source(
      MockClient((_) => pending.future),
      timeout: const Duration(milliseconds: 1),
    );
    final error = await capture(() => remote.leaveCircle('circle'));
    expect(error.code, 'CIRCLE_LEAVE_TIMEOUT');
    expect(error.isAmbiguous, true);
    pending.complete(http.Response('{"left":true}', 200));
  });
  test('transport exception is sanitized and ambiguous', () async {
    final remote = source(
      MockClient(
        (_) async => throw http.ClientException('private-marker auth-token'),
      ),
    );
    final error = await capture(() => remote.leaveCircle('circle'));
    expect(error.code, 'CIRCLE_LEAVE_TRANSPORT_ERROR');
    expect(error.isAmbiguous, true);
    expect(error.message, isNot(contains('private-marker')));
    expect(error.toString(), isNot(contains('auth-token')));
  });
  for (final status in [401, 403, 404, 409, 429, 500, 503]) {
    test(
      'HTTP $status never exposes backend details or becomes success',
      () async {
        final remote = source(
          MockClient(
            (_) async => http.Response(
              jsonEncode({
                'code': 'CIRCLE_STATE_CONFLICT',
                'error': 'private-marker auth-token app-token',
              }),
              status,
            ),
          ),
        );
        final error = await capture(() => remote.leaveCircle('circle'));
        expect(error.statusCode, status);
        expect(error.isAmbiguous, status >= 500);
        expect(
          error.code,
          status >= 500 ? 'CIRCLE_LEAVE_SERVER_ERROR' : 'CIRCLE_STATE_CONFLICT',
        );
        for (final marker in ['private-marker', 'auth-token', 'app-token']) {
          expect(error.message, isNot(contains(marker)));
          expect(error.toString(), isNot(contains(marker)));
        }
      },
    );
  }
  for (final body in [
    'not-json',
    '{}',
    '{"left":false}',
    '{"left":true,"extra":1}',
    '[]',
  ]) {
    test('malformed 2xx $body is ambiguous', () async {
      final error = await capture(
        () => source(
          MockClient((_) async => http.Response(body, 200)),
        ).leaveCircle('circle'),
      );
      expect(error.code, 'CIRCLE_LEAVE_AMBIGUOUS_RESPONSE');
      expect(error.isAmbiguous, true);
    });
  }
  for (final id in ['', ' circle', 'circle ', 'bad/id', 'x' * 129]) {
    test('invalid circleId rejects before requesting a token', () async {
      final remote = source(
        MockClient((_) async {
          fail('Must not send');
        }),
        auth: () async {
          fail('Must not get token');
        },
      );
      final error = await capture(() => remote.leaveCircle(id));
      expect(error.code, 'INVALID_CIRCLE_LEAVE_PAYLOAD');
      expect(error.isAmbiguous, false);
    });
  }
  for (final url in [
    'http://life-os-backend-gray.vercel.app/api/circles/leave',
    'https://other.test/api/circles/leave',
    'https://life-os-backend-gray.vercel.app/api/circles/delete',
  ]) {
    test('unapproved endpoint is rejected before any token load', () {
      expect(
        () => CircleLeaveRemoteDataSource(
          url: url,
          client: MockClient((_) async => http.Response('{}', 200)),
        ),
        throwsArgumentError,
      );
    });
  }
}
