import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/features/ai_companion/data/models/chat_message.dart';
import 'package:life_os/features/ai_companion/data/repositories/ai_companion_repository.dart';
import 'package:life_os/features/premium/presentation/premium_provider.dart';

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
              "Saudações, $userName. Sistema de IA do Life OS ativado. Como posso otimizar sua rotina, hábitos ou performance hoje? ⚡",
          isUser: false,
          timestamp: DateTime.now(),
        ),
      ],
      isLoading: false,
    );
  }

  Future<void> sendMessage(
    String text,
    Map<String, dynamic> contextData,
  ) async {
    if (text.trim().isEmpty) return;

    final premiumStatus = ref.read(premiumProvider);
    if (!premiumStatus.isPremium) {
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
      final replyText = await repository.sendMessageToApi(text, contextData);

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
      state = state.copyWith(
        isLoading: false,
        messages: [
          ...state.messages,
          ChatMessage(
            text: "🚨 ERRO DE CONEXÃO: $e",
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
