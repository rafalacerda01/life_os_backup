import 'dart:async';
import 'dart:convert';

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

abstract interface class CircleLeaveGateway {
  Future<void> leaveCircle(String circleId);
}

class CircleLeaveRemoteException implements Exception {
  final int? statusCode;
  final String code;
  final bool isAmbiguous;
  final String message;

  const CircleLeaveRemoteException({
    this.statusCode,
    required this.code,
    required this.isAmbiguous,
    this.message =
        'Não foi possível confirmar a saída do círculo. Tente novamente.',
  });

  @override
  String toString() => 'CircleLeaveRemoteException($code)';
}

class CircleLeaveRemoteDataSource implements CircleLeaveGateway {
  static const _approvedUrl =
      'https://life-os-backend-gray.vercel.app/api/circles/leave';
  static const defaultUrl = String.fromEnvironment(
    'LIFE_OS_CIRCLE_LEAVE_URL',
    defaultValue: _approvedUrl,
  );
  final http.Client _client;
  final Future<String?> Function() _idTokenProvider;
  final Future<String?> Function() _appCheckTokenProvider;
  final Uri _url;
  final Duration _timeout;
  final bool _ownsClient;

  CircleLeaveRemoteDataSource({
    http.Client? client,
    Future<String?> Function()? idTokenProvider,
    Future<String?> Function()? appCheckTokenProvider,
    String url = defaultUrl,
    Duration timeout = const Duration(seconds: 30),
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _idTokenProvider = idTokenProvider ?? _firebaseIdToken,
       _appCheckTokenProvider = appCheckTokenProvider ?? _firebaseAppCheckToken,
       _url = _parseUrl(url),
       _timeout = timeout {
    if (timeout <= Duration.zero)
      throw ArgumentError('Timeout must be positive.');
  }

  @override
  Future<void> leaveCircle(String circleId) async {
    if (circleId.isEmpty ||
        circleId.trim() != circleId ||
        circleId.length > 128 ||
        circleId.contains('/')) {
      throw const CircleLeaveRemoteException(
        code: 'INVALID_CIRCLE_LEAVE_PAYLOAD',
        isAmbiguous: false,
      );
    }
    final token = await _token(
      _idTokenProvider,
      'UNAUTHENTICATED',
      'UNAUTHENTICATED',
    );
    final appCheck = await _token(
      _appCheckTokenProvider,
      'APP_CHECK_REQUIRED',
      'APP_CHECK_INVALID',
    );
    http.Response response;
    try {
      final request = http.Request('POST', _url)
        ..followRedirects = false
        ..headers.addAll({
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
          'X-Firebase-AppCheck': appCheck,
        })
        ..body = jsonEncode({'circleId': circleId});
      response = await _client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(_timeout);
    } on TimeoutException {
      throw const CircleLeaveRemoteException(
        code: 'CIRCLE_LEAVE_TIMEOUT',
        isAmbiguous: true,
      );
    } catch (_) {
      throw const CircleLeaveRemoteException(
        code: 'CIRCLE_LEAVE_TRANSPORT_ERROR',
        isAmbiguous: true,
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      String code = response.statusCode >= 500
          ? 'CIRCLE_LEAVE_SERVER_ERROR'
          : 'CIRCLE_LEAVE_FAILED';
      if (response.statusCode < 500) {
        try {
          final body = jsonDecode(response.body);
          if (body is Map<String, dynamic> &&
              _knownCodes.contains(body['code']))
            code = body['code'] as String;
        } catch (_) {}
      }
      throw CircleLeaveRemoteException(
        statusCode: response.statusCode,
        code: code,
        isAmbiguous: response.statusCode >= 500 || response.statusCode == 408,
      );
    }
    try {
      final body = jsonDecode(response.body);
      if (body is! Map<String, dynamic> ||
          body.length != 1 ||
          body['left'] != true) {
        throw const FormatException();
      }
    } on FormatException {
      throw CircleLeaveRemoteException(
        statusCode: response.statusCode,
        code: 'CIRCLE_LEAVE_AMBIGUOUS_RESPONSE',
        isAmbiguous: true,
      );
    }
  }

  Future<String> _token(
    Future<String?> Function() provider,
    String missing,
    String failed,
  ) async {
    String? value;
    try {
      value = await provider().timeout(_timeout);
    } catch (_) {
      throw CircleLeaveRemoteException(code: failed, isAmbiguous: false);
    }
    if (value == null || value.trim().isEmpty) {
      throw CircleLeaveRemoteException(code: missing, isAmbiguous: false);
    }
    return value.trim();
  }

  void close() {
    if (_ownsClient) _client.close();
  }

  static const _knownCodes = {
    'UNAUTHENTICATED',
    'APP_CHECK_REQUIRED',
    'APP_CHECK_INVALID',
    'CIRCLE_NOT_FOUND',
    'CIRCLE_STATE_CONFLICT',
    'CIRCLE_ADMIN_CANNOT_LEAVE',
    'RATE_LIMITED',
    'RATE_LIMIT_UNAVAILABLE',
  };

  static Uri _parseUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null || uri != Uri.parse(_approvedUrl)) {
      throw ArgumentError(
        'Only the approved HTTPS Circle leave endpoint is allowed.',
      );
    }
    return uri;
  }
}

Future<String?> _firebaseIdToken() async =>
    FirebaseAuth.instance.currentUser?.getIdToken(true);
Future<String?> _firebaseAppCheckToken() =>
    FirebaseAppCheck.instance.getToken();
