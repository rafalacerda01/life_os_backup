import 'package:firebase_auth/firebase_auth.dart';
import 'package:life_os/features/premium/domain/services/feature_gate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/features/ai_companion/data/models/chat_message.dart';
import 'package:life_os/features/ai_companion/data/repositories/ai_companion_repository.dart';
import 'package:life_os/features/premium/presentation/premium_provider.dart';
import 'package:life_os/core/utils/app_logger.dart';

// --- INJEÇÃO DO REPOSITÓRIO ---
final aiCompanionRepositoryProvider = Provider<AICompanionRepository>((ref) {
  return AICompanionRepository();
});

class AICompanionState {
  final List<ChatMessage> messages;
  final bool isLoading;

  AICompanionState({required this.messages, required this.isLoading});

  AICompanionState copyWith({List<ChatMessage>? messages, bool? isLoading}) {
    return AICompanionState(
      messages: messages ?? this.messages,
      isLoading: isLoading ?? this.isLoading,
    );
  }
}

class AICompanionNotifier extends Notifier<AICompanionState> {
  @override
  AICompanionState build() {
    final user = FirebaseAuth.instance.currentUser;
    final userName =
        (user?.displayName != null && user!.displayName!.trim().isNotEmpty)
        ? user.displayName!
        : "Operador";

    return AICompanionState(
      messages: [
        ChatMessage(
          text:
              "Saudações, $userName. Sistema de IA do Life OS ativado. Como posso otimizar sua rotina, hábitos ou desempenho hoje? ⚡",
          isUser: false,
          timestamp: DateTime.now(),
        ),
      ],
      isLoading: false,
    );
  }

  Future<void> sendMessage(
    String text,
    Map<String, dynamic> contextData, {
    required String expectedUserId,
  }) async {
    if (text.trim().isEmpty) return;

    final premiumStatus = ref.read(premiumProvider);
    const featureGate = FeatureGate();

    final canUseAi = featureGate.canAccess(
      status: premiumStatus,
      feature: PremiumFeature.aiCompanion,
    );

    if (!canUseAi) {
      throw Exception("PREMIUM_REQUIRED");
    }

    final userMessage = ChatMessage(
      text: text,
      isUser: true,
      timestamp: DateTime.now(),
    );

    state = state.copyWith(
      messages: [...state.messages, userMessage],
      isLoading: true,
    );

    try {
      final repository = ref.read(aiCompanionRepositoryProvider);
      final replyText = await repository.sendMessageToApi(
        text,
        contextData,
        expectedUserId: expectedUserId,
      );

      final assistantMessage = ChatMessage(
        text: replyText,
        isUser: false,
        timestamp: DateTime.now(),
      );

      state = state.copyWith(
        messages: [...state.messages, assistantMessage],
        isLoading: false,
      );
    } catch (e) {
      String errorMessage;

      if (e is AIAuthenticationException) {
        errorMessage =
            '🔐 Sua sessão expirou ou não é válida. Faça login novamente.';
      } else if (e is AIPremiumRequiredException) {
        errorMessage = '💎 O Companion IA é um recurso Premium.';
      } else if (e is AIConsentRequiredException) {
        errorMessage =
            '🔒 O consentimento é necessário para utilizar o Companion IA.';
      } else if (e is AIRateLimitException) {
        errorMessage =
            '⏳ Você atingiu o limite de solicitações. Aguarde um pouco e tente novamente.';
      } else if (e is AIBadRequestException) {
        errorMessage =
            '⚠️ Não foi possível processar essa mensagem. Verifique o conteúdo e tente novamente.';
      } else if (e is AITimeoutException) {
        errorMessage =
            '⏱️ O servidor demorou para responder. Verifique sua conexão e tente novamente.';
      } else if (e is AINetworkException) {
        errorMessage =
            '🌐 Não foi possível conectar ao serviço de IA. Verifique sua conexão e tente novamente.';
      } else if (e is AIServiceException) {
        errorMessage =
            '⚡ O serviço de IA está temporariamente indisponível. Tente novamente mais tarde.';
      } else {
        errorMessage =
            '⚠️ Não foi possível processar sua mensagem. Tente novamente.';
      }

      AppLogger.e('Erro no AI Companion', e, StackTrace.current);

      state = state.copyWith(
        isLoading: false,
        messages: [
          ...state.messages,
          ChatMessage(
            text: errorMessage,
            isUser: false,
            timestamp: DateTime.now(),
          ),
        ],
      );
    }
  }
}

final aiCompanionProvider =
    NotifierProvider<AICompanionNotifier, AICompanionState>(
      AICompanionNotifier.new,
    );
