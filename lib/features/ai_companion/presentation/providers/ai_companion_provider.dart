import 'package:firebase_auth/firebase_auth.dart';
import 'package:life_os/features/premium/domain/services/feature_gate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/features/ai_companion/data/models/chat_message.dart';
import 'package:life_os/features/ai_companion/data/models/ai_insight.dart';
import 'package:life_os/features/ai_companion/data/repositories/ai_companion_repository.dart';
import 'package:life_os/features/ai_companion/data/services/ai_insight_context_builder.dart';
import 'package:life_os/features/ai_companion/presentation/providers/ai_consent_provider.dart';
import 'package:life_os/core/database/database_provider.dart';
import 'package:life_os/features/premium/presentation/premium_provider.dart';
import 'package:life_os/core/utils/app_logger.dart';

// --- INJEÇÃO DO REPOSITÓRIO ---
final aiCompanionRepositoryProvider = Provider<AICompanionRepository>((ref) {
  return AICompanionRepository();
});

final aiCompanionCurrentUserIdProvider = Provider<AIUserIdProvider>(
  (ref) =>
      () => FirebaseAuth.instance.currentUser?.uid,
);

final aiInsightContextBuilderProvider = Provider<AIInsightContextBuilder>((
  ref,
) {
  return AIInsightContextBuilder(
    ref.watch(databaseProvider),
    currentUserIdProvider: ref.watch(aiCompanionCurrentUserIdProvider),
  );
});

final aiCompanionLocalSummaryProvider = FutureProvider.autoDispose
    .family<AICompanionLocalSummary, String>((ref, expectedUserId) async {
      if (expectedUserId.isEmpty) {
        throw const AIAuthenticationException();
      }
      return ref
          .read(aiInsightContextBuilderProvider)
          .buildLocalSummary(expectedUserId: expectedUserId);
    });

class AICompanionState {
  final List<ChatMessage> messages;
  final bool isLoading;
  final AIInsight? insight;
  final AIInsightIntent? lastIntent;
  final String? sanitizedError;

  AICompanionState({
    this.messages = const [],
    this.isLoading = false,
    this.insight,
    this.lastIntent,
    this.sanitizedError,
  });

  AICompanionState copyWith({List<ChatMessage>? messages, bool? isLoading}) {
    return AICompanionState(
      messages: messages ?? this.messages,
      isLoading: isLoading ?? this.isLoading,
      insight: insight,
      lastIntent: lastIntent,
      sanitizedError: sanitizedError,
    );
  }
}

class AICompanionNotifier extends Notifier<AICompanionState> {
  int _requestGeneration = 0;

  @override
  AICompanionState build() {
    ref.onDispose(() => _requestGeneration++);
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

  Future<void> requestInsight(
    AIInsightIntent intent, {
    required String expectedUserId,
  }) async {
    if (state.isLoading) return;
    final currentUserId = ref.read(aiCompanionCurrentUserIdProvider);
    if (expectedUserId.isEmpty || currentUserId() != expectedUserId) return;

    final canUseAi = const FeatureGate().canAccess(
      status: ref.read(premiumProvider),
      feature: PremiumFeature.aiCompanion,
    );
    if (!canUseAi) {
      state = AICompanionState(
        lastIntent: intent,
        sanitizedError: 'O Companion IA é um recurso Premium.',
      );
      return;
    }
    final consent = ref.read(aiConsentProvider);
    if (consent is! AsyncData<bool> || !consent.value) {
      state = AICompanionState(
        lastIntent: intent,
        sanitizedError: 'Aceite o consentimento para usar o Companion IA.',
      );
      return;
    }

    final generation = ++_requestGeneration;
    state = AICompanionState(lastIntent: intent, isLoading: true);
    bool canPublish() => ref.mounted && generation == _requestGeneration;
    bool stillAuthorized() {
      final currentConsent = ref.read(aiConsentProvider);
      return currentUserId() == expectedUserId &&
          currentConsent is AsyncData<bool> &&
          currentConsent.value &&
          const FeatureGate().canAccess(
            status: ref.read(premiumProvider),
            feature: PremiumFeature.aiCompanion,
          );
    }

    try {
      final context = await ref
          .read(aiInsightContextBuilderProvider)
          .buildContext(intent, expectedUserId: expectedUserId);
      if (!canPublish()) return;
      if (!stillAuthorized()) {
        state = AICompanionState();
        return;
      }
      final insight = await ref
          .read(aiCompanionRepositoryProvider)
          .requestInsight(intent, context, expectedUserId: expectedUserId);
      if (!canPublish()) return;
      if (!stillAuthorized()) {
        state = AICompanionState();
        return;
      }
      state = AICompanionState(insight: insight, lastIntent: intent);
    } catch (error) {
      if (!canPublish()) return;
      if (!stillAuthorized()) {
        state = AICompanionState();
        return;
      }
      state = AICompanionState(
        lastIntent: intent,
        sanitizedError: switch (error) {
          AINetworkException() =>
            'Não foi possível conectar. Verifique sua internet e tente novamente.',
          AITimeoutException() =>
            'O serviço demorou para responder. Tente novamente.',
          AIPremiumRequiredException() =>
            'O Companion IA é um recurso Premium.',
          AIConsentRequiredException() =>
            'Aceite o consentimento para usar o Companion IA.',
          AIAuthenticationException() =>
            'Sua sessão é inválida. Entre novamente.',
          AIRateLimitException() =>
            'Limite temporário de análises atingido. Tente mais tarde.',
          _ => 'O serviço está temporariamente indisponível. Tente novamente.',
        },
      );
    }
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
