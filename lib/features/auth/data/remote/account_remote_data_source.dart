import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

typedef AccountIdTokenProvider = Future<String?> Function();

class AccountDeletionResponse {
  final bool circleDeleted;

  const AccountDeletionResponse({required this.circleDeleted});
}

class AccountRemoteException implements Exception {
  final int? statusCode;
  final String code;
  final String message;
  final bool isAmbiguous;

  const AccountRemoteException({
    required this.statusCode,
    required this.code,
    required this.message,
    required this.isAmbiguous,
  });

  @override
  String toString() => 'AccountRemoteException($code)';
}

class AccountRemoteDataSource {
  static const String defaultUrl = String.fromEnvironment(
    'LIFE_OS_ACCOUNT_DELETE_URL',
    defaultValue: 'https://life-os-backend-gray.vercel.app/api/account/delete',
  );

  // Account cleanup may include recursive Firestore deletion and a cold start.
  static const Duration defaultTimeout = Duration(seconds: 30);

  final http.Client _client;
  final AccountIdTokenProvider _idTokenProvider;
  final Uri _url;
  final Duration _timeout;
  final bool _ownsClient;

  AccountRemoteDataSource({
    http.Client? client,
    AccountIdTokenProvider? idTokenProvider,
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

  Future<AccountDeletionResponse> deleteAccount() async {
    final token = await _loadFreshToken();
    http.Response response;

    try {
      response = await _client
          .post(
            _url,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode(<String, dynamic>{}),
          )
          .timeout(_timeout);
    } on TimeoutException {
      throw const AccountRemoteException(
        statusCode: null,
        code: 'ACCOUNT_DELETE_TIMEOUT',
        message:
            'Não foi possível confirmar a exclusão. Verifique sua conexão '
            'e tente novamente.',
        isAmbiguous: true,
      );
    } on http.ClientException {
      throw const AccountRemoteException(
        statusCode: null,
        code: 'ACCOUNT_DELETE_TRANSPORT_ERROR',
        message:
            'Não foi possível confirmar a exclusão. Verifique sua conexão '
            'e tente novamente.',
        isAmbiguous: true,
      );
    } catch (_) {
      throw const AccountRemoteException(
        statusCode: null,
        code: 'ACCOUNT_DELETE_TRANSPORT_ERROR',
        message:
            'Não foi possível confirmar a exclusão. Verifique sua conexão '
            'e tente novamente.',
        isAmbiguous: true,
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _backendException(response);
    }

    try {
      final json = _decodeJsonMap(response.body);
      if (json.length != 2 ||
          json['deleted'] != true ||
          json['circleDeleted'] is! bool) {
        throw const FormatException('Invalid account deletion response.');
      }
      return AccountDeletionResponse(
        circleDeleted: json['circleDeleted'] as bool,
      );
    } on FormatException {
      throw AccountRemoteException(
        statusCode: response.statusCode,
        code: 'ACCOUNT_DELETE_AMBIGUOUS_RESPONSE',
        message: 'Não foi possível confirmar a resposta da exclusão da conta.',
        isAmbiguous: true,
      );
    }
  }

  void close() {
    if (_ownsClient) _client.close();
  }

  Future<String> _loadFreshToken() async {
    String? token;
    try {
      token = await _idTokenProvider().timeout(_timeout);
    } on TimeoutException {
      throw const AccountRemoteException(
        statusCode: null,
        code: 'REAUTHENTICATION_REQUIRED',
        message: 'É necessária uma autenticação recente para excluir a conta.',
        isAmbiguous: false,
      );
    } on FirebaseAuthException catch (error) {
      if (error.code == 'requires-recent-login') {
        throw const AccountRemoteException(
          statusCode: null,
          code: 'REAUTHENTICATION_REQUIRED',
          message:
              'É necessária uma autenticação recente para excluir a conta.',
          isAmbiguous: false,
        );
      }
      throw const AccountRemoteException(
        statusCode: null,
        code: 'UNAUTHENTICATED',
        message: 'Sua sessão não é válida. Entre novamente e tente de novo.',
        isAmbiguous: false,
      );
    } on AccountRemoteException {
      rethrow;
    } catch (_) {
      throw const AccountRemoteException(
        statusCode: null,
        code: 'UNAUTHENTICATED',
        message: 'Sua sessão não é válida. Entre novamente e tente de novo.',
        isAmbiguous: false,
      );
    }

    if (token == null || token.trim().isEmpty) {
      throw const AccountRemoteException(
        statusCode: null,
        code: 'UNAUTHENTICATED',
        message: 'Sua sessão não é válida. Entre novamente e tente de novo.',
        isAmbiguous: false,
      );
    }
    return token.trim();
  }

  static AccountRemoteException _backendException(http.Response response) {
    if (response.statusCode >= 500) {
      return AccountRemoteException(
        statusCode: response.statusCode,
        code: 'ACCOUNT_DELETE_SERVER_ERROR',
        message:
            'O servidor não conseguiu confirmar a exclusão da conta. '
            'Tente novamente.',
        isAmbiguous: true,
      );
    }

    String? backendCode;
    try {
      final body = _decodeJsonMap(response.body);
      final code = body['code'];
      if (code is String && _knownBackendCodes.contains(code)) {
        backendCode = code;
      }
    } on FormatException {
      backendCode = null;
    }

    final code = backendCode ?? 'ACCOUNT_DELETE_FAILED';
    return AccountRemoteException(
      statusCode: response.statusCode,
      code: code,
      message: _safeMessage(code, response.statusCode),
      isAmbiguous: response.statusCode == 408,
    );
  }

  static String _safeMessage(String code, int statusCode) {
    switch (code) {
      case 'CIRCLE_ADMIN_ACTION_REQUIRED':
        return 'Antes de excluir sua conta, exclua o Circle que você '
            'administra.';
      case 'ACCOUNT_STATE_CONFLICT':
        return 'Não foi possível validar o estado da conta para exclusão.';
      case 'REAUTHENTICATION_REQUIRED':
        return 'É necessária uma autenticação recente para excluir a conta.';
      case 'UNAUTHENTICATED':
        return 'Sua sessão não é válida. Entre novamente e tente de novo.';
      case 'RATE_LIMITED':
        return 'Muitas tentativas. Aguarde alguns instantes e tente novamente.';
      default:
        if (statusCode == 401) {
          return 'Sua sessão não é válida. Entre novamente e tente de novo.';
        }
        return 'Não foi possível excluir a conta. Tente novamente.';
    }
  }

  static const Set<String> _knownBackendCodes = {
    'CIRCLE_ADMIN_ACTION_REQUIRED',
    'ACCOUNT_STATE_CONFLICT',
    'REAUTHENTICATION_REQUIRED',
    'UNAUTHENTICATED',
    'RATE_LIMITED',
  };

  static Uri _parseUrl(String value) {
    final normalized = value.trim();
    final uri = Uri.tryParse(normalized);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw ArgumentError.value(value, 'url', 'Must be an absolute URL.');
    }
    return uri;
  }
}

Future<String?> _firebaseIdTokenProvider() async {
  return FirebaseAuth.instance.currentUser?.getIdToken(true);
}

Map<String, dynamic> _decodeJsonMap(String body) {
  if (body.trim().isEmpty) {
    throw const FormatException('Empty account deletion response.');
  }
  final decoded = jsonDecode(body);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Account response must be a JSON object.');
  }
  return decoded;
}
