import 'dart:async';
import 'dart:convert';

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'package:life_os/features/ai_companion/data/models/ai_insight.dart';

// ============================================================================
// EXCEÇÕES DO AI COMPANION
// ============================================================================

class AICompanionException implements Exception {
  final String message;

  const AICompanionException(this.message);

  @override
  String toString() => message;
}

class AITimeoutException extends AICompanionException {
  const AITimeoutException()
    : super(
        'O servidor demorou muito para responder. Verifique sua conexão e tente novamente.',
      );
}

class AINetworkException extends AICompanionException {
  const AINetworkException()
    : super(
        'Não foi possível conectar ao serviço de IA. Verifique sua conexão e tente novamente.',
      );
}

class AIAuthenticationException extends AICompanionException {
  const AIAuthenticationException()
    : super(
        'Sua sessão de autenticação é inválida ou expirou. Faça login novamente.',
      );
}

class AIPremiumRequiredException extends AICompanionException {
  const AIPremiumRequiredException()
    : super('O Companion IA está disponível apenas para usuários Premium.');
}

class AIAppCheckException extends AICompanionException {
  const AIAppCheckException()
    : super(
        'Não foi possível verificar a segurança deste aplicativo. Tente novamente.',
      );
}

class AIRateLimitException extends AICompanionException {
  const AIRateLimitException()
    : super(
        'Você atingiu o limite de solicitações. Aguarde alguns instantes e tente novamente.',
      );
}

class AIBadRequestException extends AICompanionException {
  const AIBadRequestException()
    : super(
        'Não foi possível processar sua mensagem. Verifique o conteúdo e tente novamente.',
      );
}

class AIServiceException extends AICompanionException {
  const AIServiceException()
    : super(
        'O serviço de IA está temporariamente indisponível. Tente novamente mais tarde.',
      );
}

// ============================================================================
// CONSENTIMENTO
// ============================================================================

class AIConsentRequiredException extends AICompanionException {
  const AIConsentRequiredException()
    : super(
        'O consentimento do usuário é necessário para utilizar dados pessoais no AI Companion.',
      );
}

// ============================================================================
// REPOSITORY
// ============================================================================

typedef AIIdTokenProvider = Future<String?> Function();
typedef AIAppCheckTokenProvider = Future<String?> Function();
typedef AICurrentUserIdProvider = String? Function();

class AICompanionRepository {
  final http.Client client;
  final AIIdTokenProvider _idTokenProvider;
  final AIAppCheckTokenProvider _appCheckTokenProvider;
  final AICurrentUserIdProvider _currentUserIdProvider;
  final Duration v2Timeout;

  static const Duration _networkTimeout = Duration(seconds: 15);

  AICompanionRepository({
    http.Client? client,
    AIIdTokenProvider? idTokenProvider,
    AIAppCheckTokenProvider? appCheckTokenProvider,
    AICurrentUserIdProvider? currentUserIdProvider,
    this.v2Timeout = _networkTimeout,
  }) : client = client ?? http.Client(),
       _idTokenProvider = idTokenProvider ?? _getFirebaseIdToken,
       _appCheckTokenProvider =
           appCheckTokenProvider ?? _getFirebaseAppCheckToken,
       _currentUserIdProvider =
           currentUserIdProvider ?? _getFirebaseCurrentUserId;

  Future<AIInsight> requestInsight(
    AIInsightIntent intent,
    Map<String, Object?> trustedContext, {
    required String expectedUserId,
  }) async {
    try {
      _ensureExpectedSession(expectedUserId);
      final token = await _idTokenProvider();
      _ensureExpectedSession(expectedUserId);
      if (token == null || token.isEmpty) {
        throw const AIAuthenticationException();
      }

      final appCheckToken = await _getRequiredAppCheckToken();
      _ensureExpectedSession(expectedUserId);
      final url = Uri.parse('https://life-os-backend-gray.vercel.app/api/chat');
      _ensureExpectedSession(expectedUserId);
      final response = await client
          .post(
            url,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
              'X-Firebase-AppCheck': appCheckToken,
            },
            body: jsonEncode({
              'version': 2,
              'intent': intent.wireValue,
              'context': trustedContext,
            }),
          )
          .timeout(v2Timeout);

      _ensureExpectedSession(expectedUserId);
      if (response.statusCode == 200) {
        AIInsight? insight;
        try {
          insight = AIInsight.fromResponse(jsonDecode(response.body), intent);
        } catch (_) {
          throw const AIServiceException();
        }
        if (insight == null) throw const AIServiceException();
        _ensureExpectedSession(expectedUserId);
        return insight;
      }

      switch (response.statusCode) {
        case 400:
          throw const AIBadRequestException();
        case 401:
          final code = _responseCode(response.body);
          if (code == 'APP_CHECK_REQUIRED' || code == 'APP_CHECK_INVALID') {
            throw const AIAppCheckException();
          }
          throw const AIAuthenticationException();
        case 402:
          throw const AIPremiumRequiredException();
        case 403:
          throw const AIAuthenticationException();
        case 451:
          throw const AIConsentRequiredException();
        case 429:
          throw const AIRateLimitException();
        default:
          throw const AIServiceException();
      }
    } on AICompanionException {
      _ensureExpectedSession(expectedUserId);
      rethrow;
    } on TimeoutException {
      _ensureExpectedSession(expectedUserId);
      throw const AITimeoutException();
    } on http.ClientException {
      _ensureExpectedSession(expectedUserId);
      throw const AINetworkException();
    } catch (_) {
      _ensureExpectedSession(expectedUserId);
      throw const AIServiceException();
    }
  }

  void _ensureExpectedSession(String expectedUserId) {
    if (expectedUserId.isEmpty || _currentUserIdProvider() != expectedUserId) {
      throw const AIAuthenticationException();
    }
  }

  Future<String> _getRequiredAppCheckToken() async {
    try {
      final token = await _appCheckTokenProvider();

      if (token == null || token.trim().isEmpty) {
        throw const AIAppCheckException();
      }

      return token;
    } on AIAppCheckException {
      rethrow;
    } catch (_) {
      throw const AIAppCheckException();
    }
  }

  String? _responseCode(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        final code = decoded['code'];
        return code is String ? code : null;
      }
    } catch (_) {
      return null;
    }

    return null;
  }
}

Future<String?> _getFirebaseIdToken() async {
  return FirebaseAuth.instance.currentUser?.getIdToken();
}

String? _getFirebaseCurrentUserId() {
  return FirebaseAuth.instance.currentUser?.uid;
}

Future<String?> _getFirebaseAppCheckToken() {
  return FirebaseAppCheck.instance.getToken();
}
