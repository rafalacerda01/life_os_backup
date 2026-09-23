import 'package:firebase_auth/firebase_auth.dart';
import 'package:life_os/features/premium/domain/services/feature_gate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/features/ai_companion/data/models/ai_insight.dart';
import 'package:life_os/features/ai_companion/data/repositories/ai_companion_repository.dart';
import 'package:life_os/features/ai_companion/data/services/ai_insight_context_builder.dart';
import 'package:life_os/features/ai_companion/presentation/providers/ai_consent_provider.dart';
import 'package:life_os/core/database/database_provider.dart';
import 'package:life_os/features/premium/presentation/premium_provider.dart';

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
  final bool isLoading;
  final AIInsight? insight;
  final AIInsightIntent? lastIntent;
  final String? sanitizedError;

  AICompanionState({
    this.isLoading = false,
    this.insight,
    this.lastIntent,
    this.sanitizedError,
  });
}

class AICompanionNotifier extends Notifier<AICompanionState> {
  int _requestGeneration = 0;

  @override
  AICompanionState build() {
    ref.onDispose(() => _requestGeneration++);
    return AICompanionState();
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
}

final aiCompanionProvider =
    NotifierProvider<AICompanionNotifier, AICompanionState>(
      AICompanionNotifier.new,
    );
