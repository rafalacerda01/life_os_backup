import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:life_os/core/network/activity_remote_data_source.dart';

const _baseUrl = 'https://example.test/api/activity';
const _token = 'firebase-id-token';

Map<String, dynamic> get _taskResponse => {
  'type': 'TASK_COMPLETION',
  'resourceId': 'task-1',
  'occurredAt': '2026-08-18T12:00:00.000Z',
  'replayed': false,
};

Map<String, dynamic> get _habitResponse => {
  'type': 'HABIT_COMPLETION',
  'resourceId': 'habit-1',
  'dayKey': '2026-08-18',
  'occurredAt': '2026-08-18T12:00:00.000Z',
  'replayed': true,
};

ActivityRemoteDataSource _source(
  MockClient client, {
  ActivityIdTokenProvider? tokenProvider,
  String baseUrl = _baseUrl,
  Duration timeout = ActivityRemoteDataSource.defaultTimeout,
}) {
  return ActivityRemoteDataSource(
    client: client,
    idTokenProvider: tokenProvider ?? () async => _token,
    baseUrl: baseUrl,
    timeout: timeout,
  );
}

Future<ActivityRemoteException> _capture(
  Future<Object?> Function() action,
) async {
  try {
    await action();
    fail('Expected ActivityRemoteException.');
  } on ActivityRemoteException catch (error) {
    return error;
  }
}

void main() {
  group('requests', () {
    test('Task uses POST, exact URL, Bearer auth, and exact body', () async {
      late http.Request captured;
      final source = _source(
        MockClient((request) async {
          captured = request;
          return http.Response(jsonEncode(_taskResponse), 200);
        }),
      );

      await source.completeTask(taskId: '  task-1  ');

      expect(captured.method, 'POST');
      expect(captured.url, Uri.parse('$_baseUrl/task-complete'));
      expect(captured.headers['authorization'], 'Bearer $_token');
      expect(captured.headers['content-type'], 'application/json');
      expect(jsonDecode(captured.body), {'taskId': 'task-1'});
      expect(captured.body, isNot(contains('uid')));
      expect(captured.body, isNot(contains('circleId')));
    });

    test('Habit uses exact URL and exact body', () async {
      late http.Request captured;
      final source = _source(
        MockClient((request) async {
          captured = request;
          return http.Response(jsonEncode(_habitResponse), 200);
        }),
      );

      await source.completeHabit(habitId: 'habit-1');

      expect(captured.url, Uri.parse('$_baseUrl/habit-complete'));
      expect(jsonDecode(captured.body), {'habitId': 'habit-1'});
      expect(captured.body, isNot(contains('uid')));
      expect(captured.body, isNot(contains('circleId')));
      expect(captured.body, isNot(contains('dayKey')));
      expect(captured.body, isNot(contains('completedDates')));
    });

    test('normalizes a trailing slash in baseUrl', () async {
      late Uri url;
      final source = _source(
        MockClient((request) async {
          url = request.url;
          return http.Response(jsonEncode(_taskResponse), 200);
        }),
        baseUrl: '$_baseUrl///',
      );

      await source.completeTask(taskId: 'task-1');

      expect(url, Uri.parse('$_baseUrl/task-complete'));
    });
  });

  group('success responses', () {
    test('parses a valid Task response', () async {
      final source = _source(
        MockClient((_) async => http.Response(jsonEncode(_taskResponse), 200)),
      );

      final result = await source.completeTask(taskId: 'task-1');

      expect(result.resourceId, 'task-1');
      expect(result.occurredAt.isUtc, isTrue);
      expect(result.replayed, isFalse);
    });

    test('parses a valid Habit response', () async {
      final source = _source(
        MockClient((_) async => http.Response(jsonEncode(_habitResponse), 200)),
      );

      final result = await source.completeHabit(habitId: 'habit-1');

      expect(result.resourceId, 'habit-1');
      expect(result.dayKey, '2026-08-18');
      expect(result.occurredAt.isUtc, isTrue);
      expect(result.replayed, isTrue);
    });

    for (final testCase in [
      (
        name: 'Task type mismatch',
        call: (ActivityRemoteDataSource source) =>
            source.completeTask(taskId: 'task-1'),
        response: {..._taskResponse, 'type': 'HABIT_COMPLETION'},
      ),
      (
        name: 'Habit type mismatch',
        call: (ActivityRemoteDataSource source) =>
            source.completeHabit(habitId: 'habit-1'),
        response: {..._habitResponse, 'type': 'TASK_COMPLETION'},
      ),
      (
        name: 'resourceId mismatch',
        call: (ActivityRemoteDataSource source) =>
            source.completeTask(taskId: 'task-1'),
        response: {..._taskResponse, 'resourceId': 'other-task'},
      ),
      (
        name: 'invalid occurredAt',
        call: (ActivityRemoteDataSource source) =>
            source.completeTask(taskId: 'task-1'),
        response: {..._taskResponse, 'occurredAt': 'not-a-date'},
      ),
      (
        name: 'invalid Habit dayKey',
        call: (ActivityRemoteDataSource source) =>
            source.completeHabit(habitId: 'habit-1'),
        response: {..._habitResponse, 'dayKey': '18-08-2026'},
      ),
      (
        name: 'non-boolean replayed',
        call: (ActivityRemoteDataSource source) =>
            source.completeTask(taskId: 'task-1'),
        response: {..._taskResponse, 'replayed': 'false'},
      ),
    ]) {
      test('${testCase.name} becomes a typed invalid response', () async {
        final source = _source(
          MockClient(
            (_) async => http.Response(jsonEncode(testCase.response), 200),
          ),
        );

        final error = await _capture(() => testCase.call(source));

        expect(error.statusCode, 200);
        expect(error.isRetryable, isFalse);
      });
    }

    test('invalid 2xx JSON becomes a typed invalid response', () async {
      final source = _source(
        MockClient((_) async => http.Response('{invalid', 200)),
      );

      final error = await _capture(() => source.completeTask(taskId: 'task-1'));

      expect(error.statusCode, 200);
      expect(error.code, 'ACTIVITY_TASK_COMPLETION_FAILED');
      expect(error.isRetryable, isFalse);
    });
  });

  group('failures', () {
    test('missing token is UNAUTHENTICATED without a request', () async {
      var requests = 0;
      final source = _source(
        MockClient((_) async {
          requests += 1;
          return http.Response(jsonEncode(_taskResponse), 200);
        }),
        tokenProvider: () async => ' ',
      );

      final error = await _capture(() => source.completeTask(taskId: 'task-1'));

      expect(error.code, 'UNAUTHENTICATED');
      expect(error.statusCode, isNull);
      expect(error.isRetryable, isFalse);
      expect(requests, 0);
    });

    test('timeout and ClientException are retryable without retries', () async {
      var timeoutRequests = 0;
      final timeoutSource = _source(
        MockClient((_) async {
          timeoutRequests += 1;
          await Future<void>.delayed(const Duration(milliseconds: 50));
          return http.Response(jsonEncode(_taskResponse), 200);
        }),
        timeout: const Duration(milliseconds: 1),
      );
      final timeoutError = await _capture(
        () => timeoutSource.completeTask(taskId: 'task-1'),
      );

      var clientRequests = 0;
      final clientSource = _source(
        MockClient((request) async {
          clientRequests += 1;
          throw http.ClientException('offline', request.url);
        }),
      );
      final clientError = await _capture(
        () => clientSource.completeHabit(habitId: 'habit-1'),
      );

      expect(timeoutError.isRetryable, isTrue);
      expect(timeoutRequests, 1);
      expect(clientError.isRetryable, isTrue);
      expect(clientRequests, 1);
    });

    for (final status in [400, 401, 404, 409, 429, 500]) {
      test('$status has the expected retry classification', () async {
        final source = _source(
          MockClient(
            (_) async => http.Response(
              jsonEncode({'error': 'Backend message', 'code': 'BACKEND_CODE'}),
              status,
            ),
          ),
        );

        final error = await _capture(
          () => source.completeTask(taskId: 'task-1'),
        );

        expect(error.statusCode, status);
        expect(error.code, 'BACKEND_CODE');
        expect(error.isRetryable, status == 429 || status >= 500);
      });
    }
  });

  test('invalid local identifiers are rejected before a request', () async {
    var requests = 0;
    final source = _source(
      MockClient((_) async {
        requests += 1;
        return http.Response(jsonEncode(_taskResponse), 200);
      }),
    );

    for (final id in ['', ' ', 'tasks/task-1', 'x' * 129]) {
      final error = await _capture(() => source.completeTask(taskId: id));
      expect(error.code, 'INVALID_ACTIVITY_PAYLOAD');
      expect(error.isRetryable, isFalse);
    }
    expect(requests, 0);
  });
}
