import 'dart:async';
import 'dart:convert';

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'package:life_os/core/utils/app_logger.dart';
import 'package:life_os/features/health/data/models/health_model.dart';

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

enum AIRelevantDomain {
  finance,
  hydration,
  moodWellbeing,
  cycle,
  medications,
  productivity,
  habits,
  tasks,
  study,
  goals,
  foodWellbeing,
  lifeOs,
}

String normalizeAIMessage(String message) {
  return message
      .trim()
      .toLowerCase()
      .replaceAll(RegExp('[áàâãä]'), 'a')
      .replaceAll(RegExp('[éèêë]'), 'e')
      .replaceAll(RegExp('[íìîï]'), 'i')
      .replaceAll(RegExp('[óòôõö]'), 'o')
      .replaceAll(RegExp('[úùûü]'), 'u')
      .replaceAll('ç', 'c');
}

bool _containsAnyTerm(String message, Iterable<String> terms) {
  return terms.any(
    (term) => RegExp(
      '(?:^|[^a-z0-9])${RegExp.escape(term)}(?:\$|[^a-z0-9])',
    ).hasMatch('$message '),
  );
}

Set<AIRelevantDomain> detectAIRelevantDomains(String message) {
  final normalized = normalizeAIMessage(message);
  final domains = <AIRelevantDomain>{};

  if (_containsAnyTerm(normalized, const [
    'saldo',
    'gasto',
    'gastos',
    'dinheiro',
    'financa',
    'financas',
    'despesa',
    'despesas',
    'orcamento',
    'transacao',
    'transacoes',
    'economizar',
  ])) {
    domains.add(AIRelevantDomain.finance);
  }
  if (_containsAnyTerm(normalized, const [
    'agua',
    'hidratacao',
    'hidratar',
    'sede',
    'ml',
  ])) {
    domains.add(AIRelevantDomain.hydration);
  }
  if (_containsAnyTerm(normalized, const [
    'humor',
    'animo',
    'estresse',
    'energia',
    'bem-estar',
    'bem estar',
    'cansaco',
    'cansada',
    'cansado',
    'saude',
  ])) {
    domains.add(AIRelevantDomain.moodWellbeing);
  }
  if (_containsAnyTerm(normalized, const [
    'menstruacao',
    'menstrual',
    'menstruada',
    'ciclo',
    'fase do ciclo',
    'tpm',
    'ovulacao',
    'ovulando',
    'lutea',
    'folicular',
  ])) {
    domains.add(AIRelevantDomain.cycle);
  }
  if (_containsAnyTerm(normalized, const [
    'medicamento',
    'medicamentos',
    'remedio',
    'remedios',
    'medicacao',
    'comprimido',
  ])) {
    domains.add(AIRelevantDomain.medications);
  }
  if (_containsAnyTerm(normalized, const [
    'rotina',
    'produtividade',
    'foco',
    'disciplina',
    'planejamento',
    'organizacao',
  ])) {
    domains.add(AIRelevantDomain.productivity);
  }
  if (_containsAnyTerm(normalized, const ['habito', 'habitos'])) {
    domains.add(AIRelevantDomain.habits);
  }
  if (_containsAnyTerm(normalized, const ['tarefa', 'tarefas'])) {
    domains.add(AIRelevantDomain.tasks);
  }
  if (_containsAnyTerm(normalized, const ['estudo', 'estudos', 'estudar'])) {
    domains.add(AIRelevantDomain.study);
  }
  if (_containsAnyTerm(normalized, const ['meta', 'metas', 'objetivo'])) {
    domains.add(AIRelevantDomain.goals);
  }
  if (_containsAnyTerm(normalized, const [
    'life os',
    'companion',
    'core',
    'aplicativo',
  ])) {
    domains.add(AIRelevantDomain.lifeOs);
  }

  final hasFoodTerm = _containsAnyTerm(normalized, const [
    'comer',
    'alimentacao',
    'lanche',
    'fome',
    'apetite',
    'chocolate',
    'doce',
    'cafe',
    'refeicao',
    'bolo',
  ]);
  final isGeneralCooking =
      hasFoodTerm &&
      _containsAnyTerm(normalized, const [
        'receita',
        'como fazer',
        'como faco',
        'ingredientes',
        'modo de preparo',
        'passo a passo',
        'assar',
        'cozinhar',
      ]);
  const foodContextDomains = {
    AIRelevantDomain.hydration,
    AIRelevantDomain.moodWellbeing,
    AIRelevantDomain.cycle,
    AIRelevantDomain.productivity,
    AIRelevantDomain.study,
    AIRelevantDomain.habits,
  };
  final hasFoodContext =
      domains.any(foodContextDomains.contains) ||
      _containsAnyTerm(normalized, const ['fome', 'apetite']);

  if (isGeneralCooking && !hasFoodContext) {
    return const <AIRelevantDomain>{};
  }
  if (hasFoodTerm && hasFoodContext) {
    domains.add(AIRelevantDomain.foodWellbeing);
  }

  return domains;
}

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
    required String message,
    required bool hasConsent,
    HealthModel? health,
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

    final domains = detectAIRelevantDomains(message);
    final context = <String, dynamic>{};

    if (domains.contains(AIRelevantDomain.finance)) {
      final safeFinance = _minimizeFinance(finance);
      if (safeFinance != null) {
        context['financas'] = safeFinance;
      }
    }

    if (domains.contains(AIRelevantDomain.hydration) && health != null) {
      context['hidratacao_ml'] = health.waterIntakeMl.clamp(0, 100000);
    }

    if (domains.contains(AIRelevantDomain.moodWellbeing) && health != null) {
      final mood = health.mood.trim();
      if (mood.isNotEmpty && mood != '—') {
        context['humor'] = mood.length <= 80 ? mood : mood.substring(0, 80);
      }
    }

    if (domains.contains(AIRelevantDomain.medications)) {
      context['medicamentos_ativos'] = medications.length.clamp(0, 1000);
    }

    if (domains.contains(AIRelevantDomain.cycle) && health != null) {
      final cyclePhase = _normalizedCyclePhase(health);
      if (cyclePhase != null) {
        context['fase_ciclo'] = cyclePhase;
      }
    }

    return context;
  }

  Map<String, num>? _minimizeFinance(Map<String, dynamic>? finance) {
    if (finance == null) {
      return null;
    }

    final balance = finance['saldo_atual'];
    final income = finance['total_entradas'];
    final expenses = finance['total_saidas'];
    if (balance is! num ||
        !balance.isFinite ||
        income is! num ||
        !income.isFinite ||
        expenses is! num ||
        !expenses.isFinite) {
      return null;
    }

    return {
      'saldo_atual': balance,
      'total_entradas': income,
      'total_saidas': expenses,
    };
  }

  String? _normalizedCyclePhase(HealthModel health) {
    final phaseInfo = health.cyclePhaseInfo;
    if (phaseInfo['isEnabled'] != true) {
      return null;
    }

    final name = phaseInfo['name'];
    if (name is! String) {
      return null;
    }
    if (name.startsWith('Fase Menstrual')) {
      return 'menstrual';
    }
    if (name.startsWith('Fase Folicular')) {
      return 'follicular';
    }
    if (name.startsWith('Fase Ovulatória')) {
      return 'ovulatory';
    }
    if (name.startsWith('Fase Lútea')) {
      return 'luteal';
    }

    return null;
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
