import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

typedef FocusIdTokenProvider = Future<String?> Function();

enum FocusRemoteTargetType {
  task('TASK'),
  subject('SUBJECT');

  const FocusRemoteTargetType(this.backendValue);

  final String backendValue;
}

class FocusStartResponse {
  String get status => 'RUNNING';

  final String sessionId;
  final int plannedDurationSeconds;
  final DateTime startedAt;
  final DateTime expiresAt;
  final bool reused;

  const FocusStartResponse({
    required this.sessionId,
    required this.plannedDurationSeconds,
    required this.startedAt,
    required this.expiresAt,
    required this.reused,
  });

  factory FocusStartResponse.fromJson(Map<String, dynamic> json) {
    _requireStatus(json, 'RUNNING');

    final startedAt = _requireDateTime(json, 'startedAt');
    final expiresAt = _requireDateTime(json, 'expiresAt');
    if (expiresAt.isBefore(startedAt)) {
      throw const FormatException('Invalid Focus expiration.');
    }

    return FocusStartResponse(
      sessionId: _requireIdentifier(json, 'sessionId'),
      plannedDurationSeconds: _requirePositiveInt(
        json,
        'plannedDurationSeconds',
      ),
      startedAt: startedAt,
      expiresAt: expiresAt,
      reused: _requireBool(json, 'reused'),
    );
  }
}

class FocusFinishResponse {
  String get status => 'COMPLETED';

  final String sessionId;
  final int verifiedDurationSeconds;
  final DateTime completedAt;
  final bool replayed;

  const FocusFinishResponse({
    required this.sessionId,
    required this.verifiedDurationSeconds,
    required this.completedAt,
    required this.replayed,
  });

  factory FocusFinishResponse.fromJson(Map<String, dynamic> json) {
    _requireStatus(json, 'COMPLETED');

    return FocusFinishResponse(
      sessionId: _requireIdentifier(json, 'sessionId'),
      verifiedDurationSeconds: _requirePositiveInt(
        json,
        'verifiedDurationSeconds',
      ),
      completedAt: _requireDateTime(json, 'completedAt'),
      replayed: _requireBool(json, 'replayed'),
    );
  }
}

class FocusCancelResponse {
  String get status => 'CANCELLED';

  final String sessionId;
  final DateTime cancelledAt;
  final bool replayed;

  const FocusCancelResponse({
    required this.sessionId,
    required this.cancelledAt,
    required this.replayed,
  });

  factory FocusCancelResponse.fromJson(Map<String, dynamic> json) {
    _requireStatus(json, 'CANCELLED');

    return FocusCancelResponse(
      sessionId: _requireIdentifier(json, 'sessionId'),
      cancelledAt: _requireDateTime(json, 'cancelledAt'),
      replayed: _requireBool(json, 'replayed'),
    );
  }
}

class FocusRemoteException implements Exception {
  final int? statusCode;
  final String code;
  final String message;
  final bool isRetryable;

  const FocusRemoteException({
    required this.statusCode,
    required this.code,
    required this.message,
    required this.isRetryable,
  });

  @override
  String toString() => 'FocusRemoteException($code): $message';
}

class FocusRemoteDataSource {
  static const String defaultBaseUrl = String.fromEnvironment(
    'LIFE_OS_FOCUS_BACKEND_BASE_URL',
    defaultValue: 'https://life-os-backend-gray.vercel.app/api/focus',
  );

  // Short enough for UI calls while still allowing a serverless cold start.
  static const Duration defaultTimeout = Duration(seconds: 7);

  static const Set<int> _allowedDurations = {60, 180, 600, 1500, 2700};

  final http.Client _client;
  final FocusIdTokenProvider _idTokenProvider;
  final String _baseUrl;
  final Duration _timeout;
  final bool _ownsClient;

  FocusRemoteDataSource({
    http.Client? client,
    FocusIdTokenProvider? idTokenProvider,
    String baseUrl = defaultBaseUrl,
    Duration timeout = defaultTimeout,
  }) : _client = client ?? http.Client(),
       _idTokenProvider = idTokenProvider ?? _firebaseIdTokenProvider,
       _baseUrl = _normalizeBaseUrl(baseUrl),
       _timeout = timeout,
       _ownsClient = client == null {
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout', 'Must be positive.');
    }
  }

  Future<FocusStartResponse> startFocus({
    required String targetId,
    required FocusRemoteTargetType targetType,
    required int plannedDurationSeconds,
  }) async {
    final normalizedTargetId = _validateRequestIdentifier(targetId, 'targetId');
    if (!_allowedDurations.contains(plannedDurationSeconds)) {
      throw _invalidPayload('plannedDurationSeconds inválido.');
    }

    final response = await _post(
      operation: 'start',
      fallbackCode: 'FOCUS_START_FAILED',
      payload: {
        'targetId': normalizedTargetId,
        'targetType': targetType.backendValue,
        'plannedDurationSeconds': plannedDurationSeconds,
      },
    );

    final parsed = _parseSuccess(
      response,
      'FOCUS_START_FAILED',
      FocusStartResponse.fromJson,
    );
    if (parsed.plannedDurationSeconds != plannedDurationSeconds) {
      throw _invalidResponse(response.statusCode, 'FOCUS_START_FAILED');
    }
    return parsed;
  }

  Future<FocusFinishResponse> finishFocus({required String sessionId}) async {
    final response = await _post(
      operation: 'finish',
      fallbackCode: 'FOCUS_FINISH_FAILED',
      payload: {
        'sessionId': _validateRequestIdentifier(sessionId, 'sessionId'),
      },
    );

    return _parseSuccess(
      response,
      'FOCUS_FINISH_FAILED',
      FocusFinishResponse.fromJson,
    );
  }

  Future<FocusCancelResponse> cancelFocus({required String sessionId}) async {
    final response = await _post(
      operation: 'cancel',
      fallbackCode: 'FOCUS_CANCEL_FAILED',
      payload: {
        'sessionId': _validateRequestIdentifier(sessionId, 'sessionId'),
      },
    );

    return _parseSuccess(
      response,
      'FOCUS_CANCEL_FAILED',
      FocusCancelResponse.fromJson,
    );
  }

  void close() {
    if (_ownsClient) _client.close();
  }

  Future<_FocusHttpResponse> _post({
    required String operation,
    required String fallbackCode,
    required Map<String, dynamic> payload,
  }) async {
    final token = await _loadToken(fallbackCode);
    http.Response response;

    try {
      response = await _client
          .post(
            Uri.parse('$_baseUrl/$operation'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode(payload),
          )
          .timeout(_timeout);
    } on TimeoutException {
      throw FocusRemoteException(
        statusCode: null,
        code: fallbackCode,
        message: 'Tempo limite excedido ao comunicar com o backend Focus.',
        isRetryable: true,
      );
    } on http.ClientException catch (error) {
      throw FocusRemoteException(
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
      return _FocusHttpResponse(
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
      throw FocusRemoteException(
        statusCode: null,
        code: fallbackCode,
        message: 'Tempo limite excedido ao obter autenticação Firebase.',
        isRetryable: true,
      );
    } on FocusRemoteException {
      rethrow;
    } catch (_) {
      throw FocusRemoteException(
        statusCode: null,
        code: fallbackCode,
        message: 'Não foi possível obter o token Firebase.',
        isRetryable: true,
      );
    }

    if (token == null || token.trim().isEmpty) {
      throw const FocusRemoteException(
        statusCode: null,
        code: 'UNAUTHENTICATED',
        message: 'Usuário não autenticado.',
        isRetryable: false,
      );
    }
    return token.trim();
  }

  static T _parseSuccess<T>(
    _FocusHttpResponse response,
    String fallbackCode,
    T Function(Map<String, dynamic>) parser,
  ) {
    try {
      return parser(response.json);
    } on FormatException {
      throw _invalidResponse(response.statusCode, fallbackCode);
    }
  }

  static FocusRemoteException _backendException(
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
    final backendMessage = body?['error'];
    return FocusRemoteException(
      statusCode: response.statusCode,
      code: backendCode is String && backendCode.trim().isNotEmpty
          ? backendCode.trim()
          : fallbackCode,
      message: backendMessage is String && backendMessage.trim().isNotEmpty
          ? backendMessage.trim()
          : 'Falha na operação remota de Focus.',
      isRetryable: _isRetryableStatus(response.statusCode),
    );
  }

  static bool _isRetryableStatus(int statusCode) {
    return statusCode == 429 || statusCode >= 500;
  }

  static FocusRemoteException _invalidPayload(String message) {
    return FocusRemoteException(
      statusCode: null,
      code: 'INVALID_FOCUS_PAYLOAD',
      message: message,
      isRetryable: false,
    );
  }

  static FocusRemoteException _invalidResponse(
    int statusCode,
    String fallbackCode,
  ) {
    return FocusRemoteException(
      statusCode: statusCode,
      code: fallbackCode,
      message: 'Resposta inválida do backend Focus.',
      isRetryable: false,
    );
  }

  static String _validateRequestIdentifier(String value, String fieldName) {
    final normalized = value.trim();
    if (normalized.isEmpty ||
        normalized.length > 128 ||
        normalized.contains('/')) {
      throw _invalidPayload('$fieldName inválido.');
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

class _FocusHttpResponse {
  final int statusCode;
  final Map<String, dynamic> json;

  const _FocusHttpResponse({required this.statusCode, required this.json});
}

Future<String?> _firebaseIdTokenProvider() async {
  final user = FirebaseAuth.instance.currentUser;
  return user?.getIdToken();
}

Map<String, dynamic> _decodeJsonMap(String body) {
  if (body.trim().isEmpty) {
    throw const FormatException('Empty Focus response.');
  }

  final decoded = jsonDecode(body);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Focus response must be a JSON object.');
  }
  return decoded;
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

String _requireStatus(Map<String, dynamic> json, String expected) {
  final value = json['status'];
  if (value != expected) throw const FormatException('Invalid Focus status.');
  return expected;
}

int _requirePositiveInt(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! int || value <= 0) throw FormatException('Invalid $key.');
  return value;
}

bool _requireBool(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! bool) throw FormatException('Invalid $key.');
  return value;
}

DateTime _requireDateTime(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String) throw FormatException('Invalid $key.');

  final parsed = DateTime.tryParse(value);
  if (parsed == null) throw FormatException('Invalid $key.');
  return parsed;
}
