import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'package:life_os/core/utils/app_logger.dart';

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

class AICompanionRepository {
  final http.Client client;
  final AIIdTokenProvider _idTokenProvider;
  final AIAppCheckTokenProvider _appCheckTokenProvider;

  static const Duration _networkTimeout = Duration(seconds: 15);

  AICompanionRepository({
    http.Client? client,
    AIIdTokenProvider? idTokenProvider,
    AIAppCheckTokenProvider? appCheckTokenProvider,
  }) : client = client ?? http.Client(),
       _idTokenProvider = idTokenProvider ?? _getFirebaseIdToken,
       _appCheckTokenProvider =
           appCheckTokenProvider ?? _getFirebaseAppCheckToken;

  // ==========================================================================
  // CONTEXTO DO SISTEMA
  // ==========================================================================

  Future<Map<String, dynamic>> getSystemContext({
    required bool hasConsent,
    dynamic health,
    List medications = const [],
    Map<String, dynamic>? finance,
  }) async {
    // ------------------------------------------------------------------------
    // BARREIRA DE CONSENTIMENTO
    //
    // Mesmo que a camada de apresentação seja burlada ou chamada
    // diretamente, o repository não poderá montar contexto pessoal
    // sem consentimento explícito.
    // ------------------------------------------------------------------------

    if (!hasConsent) {
      throw const AIConsentRequiredException();
    }

    final Map<String, dynamic> healthContext = {};

    // ------------------------------------------------------------------------
    // 1. SAÚDE E MEDICAMENTOS
    // ------------------------------------------------------------------------

    if (health != null) {
      healthContext["humor"] = health.mood.isNotEmpty
          ? health.mood
          : "Ainda não registrado";

      healthContext["hidratacao"] = "${health.waterIntakeMl}ml";

      healthContext["medicamentos"] = medications.isNotEmpty
          ? medications.map((m) => m.name).join(', ')
          : "Nenhum medicamento ativo";
    } else {
      healthContext["humor"] = "Dados indisponíveis";
      healthContext["hidratacao"] = "0ml";
      healthContext["medicamentos"] = "Dados indisponíveis";
    }

    // ------------------------------------------------------------------------
    // 2. FINANÇAS
    // ------------------------------------------------------------------------

    healthContext["financas"] = finance ?? "Dados indisponíveis";

    // ------------------------------------------------------------------------
    // 3. DADOS EXTRAS DO USUÁRIO
    // ------------------------------------------------------------------------

    try {
      final user = FirebaseAuth.instance.currentUser;

      if (user != null) {
        final userDoc = await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .get()
            .timeout(
              _networkTimeout,
              onTimeout: () => throw const AITimeoutException(),
            );

        if (userDoc.exists) {
          healthContext["ciclo_menstrual"] =
              userDoc.data()?['menstrualCycle'] ?? "Não rastreado";
        }
      }
    } catch (e, stack) {
      AppLogger.e('Erro ao buscar contexto para IA', e, stack);

      healthContext["ciclo_menstrual"] = "Erro ao carregar";
    }

    // ------------------------------------------------------------------------
    // METADADOS
    // ------------------------------------------------------------------------

    healthContext["data_coleta"] = DateTime.now().toIso8601String();

    healthContext["status"] = "Online";

    return healthContext;
  }

  // ==========================================================================
  // ENVIO PARA API
  // ==========================================================================

  Future<String> sendMessageToApi(
    String text,
    Map<String, dynamic> contextData,
  ) async {
    try {
      // ----------------------------------------------------------------------
      // AUTENTICAÇÃO
      // ----------------------------------------------------------------------

      final token = await _idTokenProvider();

      if (token == null || token.isEmpty) {
        throw const AIAuthenticationException();
      }

      // ----------------------------------------------------------------------
      // APP CHECK
      // ----------------------------------------------------------------------

      final appCheckToken = await _getRequiredAppCheckToken();

      // ----------------------------------------------------------------------
      // ENDPOINT
      // ----------------------------------------------------------------------

      final url = Uri.parse('https://life-os-backend-gray.vercel.app/api/chat');

      // ----------------------------------------------------------------------
      // REQUEST
      // ----------------------------------------------------------------------

      final response = await client
          .post(
            url,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
              'X-Firebase-AppCheck': appCheckToken,
            },
            body: jsonEncode({"message": text, "context": contextData}),
          )
          .timeout(
            _networkTimeout,
            onTimeout: () {
              throw const AITimeoutException();
            },
          );

      // ----------------------------------------------------------------------
      // SUCESSO
      // ----------------------------------------------------------------------

      if (response.statusCode == 200) {
        try {
          final data = jsonDecode(response.body);

          final reply = data['reply'];

          if (reply is String && reply.isNotEmpty) {
            return reply;
          }

          throw const AIServiceException();
        } catch (e) {
          if (e is AICompanionException) {
            rethrow;
          }

          throw const AIServiceException();
        }
      }

      // ----------------------------------------------------------------------
      // TRATAMENTO HTTP
      // ----------------------------------------------------------------------

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

        case 500:
        case 502:
        case 503:
        case 504:
          throw const AIServiceException();

        default:
          throw const AIServiceException();
      }

      // FINAL DO SWITCH
    } on AICompanionException {
      rethrow;
    } on TimeoutException {
      throw const AITimeoutException();
    } on http.ClientException catch (e, stack) {
      AppLogger.e('Erro de rede na comunicação com a API de IA', e, stack);

      throw const AINetworkException();
    } catch (e, stack) {
      AppLogger.e('Erro inesperado na comunicação com a API de IA', e, stack);

      throw const AIServiceException();
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

Future<String?> _getFirebaseAppCheckToken() {
  return FirebaseAppCheck.instance.getToken();
}
