import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:http/http.dart' as http;

import 'package:life_os/features/ai_companion/data/models/chat_message.dart';

// Importação necessária para verificar o status premium

import 'package:life_os/features/premium/presentation/premium_provider.dart';

import 'package:firebase_auth/firebase_auth.dart';

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

// Mudamos de StateNotifier para Notifier

class AICompanionNotifier extends Notifier<AICompanionState> {
  // O estado inicial agora é definido no método build()

  @override
  AICompanionState build() {
    // Pega o nome do usuário logado no Firebase (ou 'Operador' caso venha nulo/vazio)
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

  // 🚀 ATUALIZADO: Protegido por Guard Clause Premium

  Future<void> sendMessage(
    String text,

    Map<String, dynamic> contextData,
  ) async {
    if (text.trim().isEmpty) return;

    // --- SEGURANÇA: Bloqueio de IA não-Premium ---

    final premiumStatus = ref.read(premiumProvider);

    if (!premiumStatus.isPremium) {
      throw Exception("PREMIUM_REQUIRED");
    }

    // ---------------------------------------------

    final userMessage = ChatMessage(
      text: text,

      isUser: true,

      timestamp: DateTime.now(),
    );

    // Atualizamos o estado usando a variável 'state'

    state = state.copyWith(
      messages: [...state.messages, userMessage],

      isLoading: true,
    );

    try {
      // ✅ 1. Pega o usuário logado e gera o Token de Segurança (JWT)

      final user = FirebaseAuth.instance.currentUser;

      final token = await user?.getIdToken() ?? '';

      // 🌐 URL do seu back-end na Vercel

      final url = Uri.parse('https://life-os-backend-gray.vercel.app/api/chat');

      final response = await http.post(
        url,

        headers: {
          'Content-Type': 'application/json',

          // ✅ 2. Envia o Token no cabeçalho de Autorização
          'Authorization': 'Bearer $token',
        },

        body: jsonEncode({"message": text, "context": contextData}),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);

        final replyText = data['reply'];

        final assistantMessage = ChatMessage(
          text: replyText,

          isUser: false,

          timestamp: DateTime.now(),
        );

        state = state.copyWith(
          messages: [...state.messages, assistantMessage],

          isLoading: false,
        );
      } else {
        throw Exception(
          "O servidor Vercel respondeu com Status ${response.statusCode}: ${response.body}",
        );
      }
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

// Atualizado para NotifierProvider

final aiCompanionProvider =
    NotifierProvider<AICompanionNotifier, AICompanionState>(
      AICompanionNotifier.new,
    );
