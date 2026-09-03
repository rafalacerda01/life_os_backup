import 'dart:async';
import 'dart:convert';

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

typedef ActivityIdTokenProvider = Future<String?> Function();
typedef ActivityAppCheckTokenProvider = Future<String?> Function();

class ActivityTaskCompletionResponse {
  final String resourceId;
  final DateTime occurredAt;
  final bool replayed;

  const ActivityTaskCompletionResponse({
    required this.resourceId,
    required this.occurredAt,
    required this.replayed,
  });

  factory ActivityTaskCompletionResponse.fromJson(Map<String, dynamic> json) {
    _requireExactKeys(json, const [
      'type',
      'resourceId',
      'occurredAt',
      'replayed',
    ]);
    if (json['type'] != 'TASK_COMPLETION') {
      throw const FormatException('Invalid activity type.');
    }

    return ActivityTaskCompletionResponse(
      resourceId: _requireIdentifier(json, 'resourceId'),
      occurredAt: _requireDateTime(json, 'occurredAt'),
      replayed: _requireBool(json, 'replayed'),
    );
  }
}

class ActivityHabitCompletionResponse {
  final String resourceId;
  final String dayKey;
  final DateTime occurredAt;
  final bool replayed;

  const ActivityHabitCompletionResponse({
    required this.resourceId,
    required this.dayKey,
    required this.occurredAt,
    required this.replayed,
  });

  factory ActivityHabitCompletionResponse.fromJson(Map<String, dynamic> json) {
    _requireExactKeys(json, const [
      'type',
      'resourceId',
      'dayKey',
      'occurredAt',
      'replayed',
    ]);
    if (json['type'] != 'HABIT_COMPLETION') {
      throw const FormatException('Invalid activity type.');
    }

    return ActivityHabitCompletionResponse(
      resourceId: _requireIdentifier(json, 'resourceId'),
      dayKey: _requireDayKey(json),
      occurredAt: _requireDateTime(json, 'occurredAt'),
      replayed: _requireBool(json, 'replayed'),
    );
  }
}

class ActivityRemoteException implements Exception {
  final int? statusCode;
  final String code;
  final String message;
  final bool isRetryable;

  const ActivityRemoteException({
    required this.statusCode,
    required this.code,
    required this.message,
    required this.isRetryable,
  });

  @override
  String toString() => 'ActivityRemoteException($code): $message';
}

final activityRemoteDataSourceProvider = Provider<ActivityRemoteDataSource>((
  ref,
) {
  final dataSource = ActivityRemoteDataSource();
  ref.onDispose(dataSource.close);
  return dataSource;
});

class ActivityRemoteDataSource {
  static const String defaultBaseUrl = String.fromEnvironment(
    'LIFE_OS_ACTIVITY_BACKEND_BASE_URL',
    defaultValue: 'https://life-os-backend-gray.vercel.app/api/activity',
  );
  static const Duration defaultTimeout = Duration(seconds: 7);

  final http.Client _client;
  final ActivityIdTokenProvider _idTokenProvider;
  final ActivityAppCheckTokenProvider _appCheckTokenProvider;
  final String _baseUrl;
  final Duration _timeout;
  final bool _ownsClient;

  ActivityRemoteDataSource({
    http.Client? client,
    ActivityIdTokenProvider? idTokenProvider,
    ActivityAppCheckTokenProvider? appCheckTokenProvider,
    String baseUrl = defaultBaseUrl,
    Duration timeout = defaultTimeout,
  }) : _client = client ?? http.Client(),
       _idTokenProvider = idTokenProvider ?? _firebaseIdTokenProvider,
       _appCheckTokenProvider =
           appCheckTokenProvider ?? _firebaseAppCheckTokenProvider,
       _baseUrl = _normalizeBaseUrl(baseUrl),
       _timeout = timeout,
       _ownsClient = client == null {
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout', 'Must be positive.');
    }
  }

  Future<ActivityTaskCompletionResponse> completeTask({
    required String taskId,
  }) async {
    final normalizedTaskId = _validateIdentifier(taskId, 'taskId');
    final response = await _post(
      operation: 'task-complete',
      fallbackCode: 'ACTIVITY_TASK_COMPLETION_FAILED',
      payload: {'taskId': normalizedTaskId},
    );
    final parsed = _parseSuccess(
      response,
      'ACTIVITY_TASK_COMPLETION_FAILED',
      ActivityTaskCompletionResponse.fromJson,
    );
    if (parsed.resourceId != normalizedTaskId) {
      throw _invalidResponse(
        response.statusCode,
        'ACTIVITY_TASK_COMPLETION_FAILED',
      );
    }
    return parsed;
  }

  Future<ActivityHabitCompletionResponse> completeHabit({
    required String habitId,
  }) async {
    final normalizedHabitId = _validateIdentifier(habitId, 'habitId');
    final response = await _post(
      operation: 'habit-complete',
      fallbackCode: 'ACTIVITY_HABIT_COMPLETION_FAILED',
      payload: {'habitId': normalizedHabitId},
    );
    final parsed = _parseSuccess(
      response,
      'ACTIVITY_HABIT_COMPLETION_FAILED',
      ActivityHabitCompletionResponse.fromJson,
    );
    if (parsed.resourceId != normalizedHabitId) {
      throw _invalidResponse(
        response.statusCode,
        'ACTIVITY_HABIT_COMPLETION_FAILED',
      );
    }
    return parsed;
  }

  void close() {
    if (_ownsClient) _client.close();
  }

  Future<_ActivityHttpResponse> _post({
    required String operation,
    required String fallbackCode,
    required Map<String, dynamic> payload,
  }) async {
    final token = await _loadToken(fallbackCode);
    final appCheckToken = await _loadAppCheckToken();
    http.Response response;
    try {
      response = await _client
          .post(
            Uri.parse('$_baseUrl/$operation'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
              'X-Firebase-AppCheck': appCheckToken,
            },
            body: jsonEncode(payload),
          )
          .timeout(_timeout);
    } on TimeoutException {
      throw ActivityRemoteException(
        statusCode: null,
        code: fallbackCode,
        message: 'Tempo limite excedido ao comunicar com o backend.',
        isRetryable: true,
      );
    } on http.ClientException catch (error) {
      throw ActivityRemoteException(
        statusCode: null,
        code: fallbackCode,
        message: error.message,
        isRetryable: true,
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _backendException(response, fallbackCode);
    }

    try {
      return _ActivityHttpResponse(
        statusCode: response.statusCode,
        json: _decodeJsonMap(response.body),
      );
    } on FormatException {
      throw _invalidResponse(response.statusCode, fallbackCode);
    }
  }

  Future<String> _loadToken(String fallbackCode) async {
    String? token;
    try {
      token = await _idTokenProvider().timeout(_timeout);
    } on TimeoutException {
      throw ActivityRemoteException(
        statusCode: null,
        code: fallbackCode,
        message: 'Tempo limite excedido ao obter autenticacao Firebase.',
        isRetryable: true,
      );
    } catch (_) {
      throw ActivityRemoteException(
        statusCode: null,
        code: fallbackCode,
        message: 'Nao foi possivel obter o token Firebase.',
        isRetryable: true,
      );
    }

    if (token == null || token.trim().isEmpty) {
      throw const ActivityRemoteException(
        statusCode: null,
        code: 'UNAUTHENTICATED',
        message: 'Usuario nao autenticado.',
        isRetryable: false,
      );
    }
    return token.trim();
  }

  static T _parseSuccess<T>(
    _ActivityHttpResponse response,
    String fallbackCode,
    T Function(Map<String, dynamic>) parser,
  ) {
    try {
      return parser(response.json);
    } on FormatException {
      throw _invalidResponse(response.statusCode, fallbackCode);
    }
  }

  Future<String> _loadAppCheckToken() async {
    String? token;
    try {
      token = await _appCheckTokenProvider().timeout(_timeout);
    } catch (_) {
      throw const ActivityRemoteException(
        statusCode: null,
        code: 'APP_CHECK_INVALID',
        message: _appCheckFailureMessage,
        isRetryable: true,
      );
    }
    if (token == null || token.trim().isEmpty) {
      throw const ActivityRemoteException(
        statusCode: null,
        code: 'APP_CHECK_REQUIRED',
        message: _appCheckFailureMessage,
        isRetryable: false,
      );
    }
    return token.trim();
  }

  static const _appCheckFailureMessage =
      'Não foi possível validar a segurança do aplicativo. Tente novamente.';

  static ActivityRemoteException _backendException(
    http.Response response,
    String fallbackCode,
  ) {
    Map<String, dynamic>? body;
    try {
      body = _decodeJsonMap(response.body);
    } on FormatException {
      body = null;
    }

    final backendCode = body?['code'];
    if (backendCode == 'APP_CHECK_REQUIRED' ||
        backendCode == 'APP_CHECK_INVALID') {
      return ActivityRemoteException(
        statusCode: response.statusCode,
        code: backendCode as String,
        message: _appCheckFailureMessage,
        isRetryable: response.statusCode == 429 || response.statusCode >= 500,
      );
    }
    final backendMessage = body?['error'];
    return ActivityRemoteException(
      statusCode: response.statusCode,
      code: backendCode is String && backendCode.trim().isNotEmpty
          ? backendCode.trim()
          : fallbackCode,
      message: backendMessage is String && backendMessage.trim().isNotEmpty
          ? backendMessage.trim()
          : 'Falha na atividade competitiva.',
      isRetryable: response.statusCode == 429 || response.statusCode >= 500,
    );
  }

  static ActivityRemoteException _invalidPayload(String message) {
    return ActivityRemoteException(
      statusCode: null,
      code: 'INVALID_ACTIVITY_PAYLOAD',
      message: message,
      isRetryable: false,
    );
  }

  static ActivityRemoteException _invalidResponse(
    int statusCode,
    String fallbackCode,
  ) {
    return ActivityRemoteException(
      statusCode: statusCode,
      code: fallbackCode,
      message: 'Resposta invalida do backend de atividade.',
      isRetryable: false,
    );
  }

  static String _validateIdentifier(String value, String fieldName) {
    final normalized = value.trim();
    if (normalized.isEmpty ||
        normalized.length > 128 ||
        normalized.contains('/')) {
      throw _invalidPayload('$fieldName invalido.');
    }
    return normalized;
  }

  static String _normalizeBaseUrl(String value) {
    final normalized = value.trim().replaceFirst(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(normalized);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw ArgumentError.value(value, 'baseUrl', 'Must be an absolute URL.');
    }
    return normalized;
  }
}

class _ActivityHttpResponse {
  final int statusCode;
  final Map<String, dynamic> json;

  const _ActivityHttpResponse({required this.statusCode, required this.json});
}

Future<String?> _firebaseAppCheckTokenProvider() {
  return FirebaseAppCheck.instance.getToken();
}

Future<String?> _firebaseIdTokenProvider() async {
  final user = FirebaseAuth.instance.currentUser;
  return user?.getIdToken();
}

Map<String, dynamic> _decodeJsonMap(String body) {
  if (body.trim().isEmpty) {
    throw const FormatException('Empty activity response.');
  }
  final decoded = jsonDecode(body);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Activity response must be a JSON object.');
  }
  return decoded;
}

void _requireExactKeys(Map<String, dynamic> json, List<String> expectedKeys) {
  if (json.length != expectedKeys.length ||
      expectedKeys.any((key) => !json.containsKey(key))) {
    throw const FormatException('Invalid activity response shape.');
  }
}

String _requireIdentifier(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String) throw FormatException('Invalid $key.');
  final normalized = value.trim();
  if (normalized.isEmpty ||
      normalized.length > 128 ||
      normalized.contains('/')) {
    throw FormatException('Invalid $key.');
  }
  return normalized;
}

String _requireDayKey(Map<String, dynamic> json) {
  final value = json['dayKey'];
  if (value is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
    throw const FormatException('Invalid dayKey.');
  }
  return value;
}

DateTime _requireDateTime(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String) throw FormatException('Invalid $key.');
  final parsed = DateTime.tryParse(value);
  if (parsed == null) throw FormatException('Invalid $key.');
  return parsed;
}

bool _requireBool(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! bool) throw FormatException('Invalid $key.');
  return value;
}
