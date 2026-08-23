import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

typedef CircleIdTokenProvider = Future<String?> Function();

abstract interface class CircleDeleteGateway {
  Future<void> deleteCircle(String circleId);
}

class CircleDeleteRemoteException implements Exception {
  final int? statusCode;
  final String code;
  final String message;
  final bool isAmbiguous;

  const CircleDeleteRemoteException({
    required this.statusCode,
    required this.code,
    required this.message,
    required this.isAmbiguous,
  });

  @override
  String toString() => 'CircleDeleteRemoteException($code)';
}

class CircleDeleteRemoteDataSource implements CircleDeleteGateway {
  static const String defaultUrl = String.fromEnvironment(
    'LIFE_OS_CIRCLE_DELETE_URL',
    defaultValue: 'https://life-os-backend-gray.vercel.app/api/circles/delete',
  );
  static const Duration defaultTimeout = Duration(seconds: 30);

  final http.Client _client;
  final CircleIdTokenProvider _idTokenProvider;
  final Uri _url;
  final Duration _timeout;
  final bool _ownsClient;

  CircleDeleteRemoteDataSource({
    http.Client? client,
    CircleIdTokenProvider? idTokenProvider,
    String url = defaultUrl,
    Duration timeout = defaultTimeout,
  }) : _client = client ?? http.Client(),
       _idTokenProvider = idTokenProvider ?? _firebaseIdTokenProvider,
       _url = _parseUrl(url),
       _timeout = timeout,
       _ownsClient = client == null {
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout', 'Must be positive.');
    }
  }

  @override
  Future<void> deleteCircle(String circleId) async {
    final normalizedCircleId = circleId.trim();
    if (normalizedCircleId.isEmpty ||
        normalizedCircleId != circleId ||
        normalizedCircleId.length > 128 ||
        normalizedCircleId.contains('/')) {
      throw const CircleDeleteRemoteException(
        statusCode: null,
        code: 'INVALID_CIRCLE_DELETE_PAYLOAD',
        message: 'Circle inválido.',
        isAmbiguous: false,
      );
    }

    final token = await _loadToken();
    http.Response response;
    try {
      response = await _client
          .post(
            _url,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode({'circleId': normalizedCircleId}),
          )
          .timeout(_timeout);
    } on TimeoutException {
      throw const CircleDeleteRemoteException(
        statusCode: null,
        code: 'CIRCLE_DELETE_TIMEOUT',
        message: 'Não foi possível confirmar a exclusão. Tente novamente.',
        isAmbiguous: true,
      );
    } on http.ClientException {
      throw const CircleDeleteRemoteException(
        statusCode: null,
        code: 'CIRCLE_DELETE_TRANSPORT_ERROR',
        message: 'Não foi possível confirmar a exclusão. Tente novamente.',
        isAmbiguous: true,
      );
    } catch (_) {
      throw const CircleDeleteRemoteException(
        statusCode: null,
        code: 'CIRCLE_DELETE_TRANSPORT_ERROR',
        message: 'Não foi possível confirmar a exclusão. Tente novamente.',
        isAmbiguous: true,
      );
    }

    if (response.statusCode == 404 && _hasCode(response, 'CIRCLE_NOT_FOUND')) {
      return;
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _backendException(response);
    }

    try {
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic> ||
          decoded.length != 1 ||
          decoded['deleted'] != true) {
        throw const FormatException();
      }
    } on FormatException {
      throw CircleDeleteRemoteException(
        statusCode: response.statusCode,
        code: 'CIRCLE_DELETE_AMBIGUOUS_RESPONSE',
        message: 'Não foi possível confirmar a exclusão do Circle.',
        isAmbiguous: true,
      );
    }
  }

  void close() {
    if (_ownsClient) _client.close();
  }

  Future<String> _loadToken() async {
    try {
      final token = await _idTokenProvider().timeout(_timeout);
      if (token == null || token.trim().isEmpty) {
        throw const CircleDeleteRemoteException(
          statusCode: null,
          code: 'UNAUTHENTICATED',
          message: 'Sua sessão não é válida. Entre novamente.',
          isAmbiguous: false,
        );
      }
      return token.trim();
    } on CircleDeleteRemoteException {
      rethrow;
    } catch (_) {
      throw const CircleDeleteRemoteException(
        statusCode: null,
        code: 'UNAUTHENTICATED',
        message: 'Sua sessão não é válida. Entre novamente.',
        isAmbiguous: false,
      );
    }
  }

  static CircleDeleteRemoteException _backendException(http.Response response) {
    if (response.statusCode >= 500) {
      return CircleDeleteRemoteException(
        statusCode: response.statusCode,
        code: 'CIRCLE_DELETE_SERVER_ERROR',
        message: 'O servidor não conseguiu excluir o Circle. Tente novamente.',
        isAmbiguous: true,
      );
    }

    String? backendCode;
    try {
      final decoded = jsonDecode(response.body);
      final code = decoded is Map<String, dynamic> ? decoded['code'] : null;
      if (code is String && _knownCodes.contains(code)) backendCode = code;
    } catch (_) {
      backendCode = null;
    }
    final code = backendCode ?? 'CIRCLE_DELETE_FAILED';
    return CircleDeleteRemoteException(
      statusCode: response.statusCode,
      code: code,
      message: _safeMessage(code),
      isAmbiguous: response.statusCode == 408,
    );
  }

  static bool _hasCode(http.Response response, String expectedCode) {
    try {
      final decoded = jsonDecode(response.body);
      return decoded is Map<String, dynamic> && decoded['code'] == expectedCode;
    } on FormatException {
      return false;
    }
  }

  static String _safeMessage(String code) {
    return switch (code) {
      'CIRCLE_ADMIN_REQUIRED' =>
        'Somente o administrador pode excluir o Circle.',
      'CIRCLE_NOT_FOUND' => 'Circle não encontrado.',
      'CIRCLE_STATE_CONFLICT' =>
        'Não foi possível validar o Circle para exclusão.',
      'UNAUTHENTICATED' => 'Sua sessão não é válida. Entre novamente.',
      'RATE_LIMITED' => 'Muitas tentativas. Aguarde e tente novamente.',
      _ => 'Não foi possível excluir o Circle. Tente novamente.',
    };
  }

  static const Set<String> _knownCodes = {
    'CIRCLE_ADMIN_REQUIRED',
    'CIRCLE_NOT_FOUND',
    'CIRCLE_STATE_CONFLICT',
    'UNAUTHENTICATED',
    'RATE_LIMITED',
  };

  static Uri _parseUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw ArgumentError.value(value, 'url', 'Must be an absolute HTTPS URL.');
    }
    return uri;
  }
}

Future<String?> _firebaseIdTokenProvider() async {
  return FirebaseAuth.instance.currentUser?.getIdToken(true);
}
