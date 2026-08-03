import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'package:life_os/core/utils/app_logger.dart';

class AICompanionRepository {
  final http.Client client;

  // 🚀 Timeout de segurança global para operações de rede e nuvem
  static const Duration _networkTimeout = Duration(seconds: 15);

  AICompanionRepository({http.Client? client})
    : client = client ?? http.Client();

  Future<Map<String, dynamic>> getSystemContext({
    required dynamic health,
    required List<dynamic> medications,
  }) async {
    final Map<String, dynamic> healthContext = {};

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

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        // 1. Ciclo menstrual com timeout de segurança
        final userDoc = await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .get()
            .timeout(
              _networkTimeout,
              onTimeout: () => throw TimeoutException(
                'Timeout ao buscar dados de usuário para a IA.',
              ),
            );

        if (userDoc.exists) {
          healthContext["ciclo_menstrual"] =
              userDoc.data()?['menstrualCycle'] ?? "Não rastreado";
        }

        // 2. Finanças com timeout de segurança
        final financeDoc = await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .collection('finance')
            .doc('main')
            .get()
            .timeout(
              _networkTimeout,
              onTimeout: () => throw TimeoutException(
                'Timeout ao buscar dados financeiros para a IA.',
              ),
            );

        if (financeDoc.exists) {
          final data = financeDoc.data();
          final income = (data?['totalIncome'] ?? 0.0).toDouble();
          final expense = (data?['totalExpense'] ?? 0.0).toDouble();

          healthContext["financas"] = {
            "entradas": income,
            "saidas": expense,
            "saldo": income - expense,
          };
        } else {
          healthContext["financas"] = "Dados indisponíveis";
        }
      }
    } catch (e, stack) {
      AppLogger.e('Erro ao buscar contexto para IA', e, stack);
      healthContext["ciclo_menstrual"] = "Erro ao carregar";
      healthContext["financas"] = "Erro ao carregar";
    }

    healthContext["data_coleta"] = DateTime.now().toIso8601String();
    healthContext["status"] = "Online";

    return healthContext;
  }

  Future<String> sendMessageToApi(
    String text,
    Map<String, dynamic> contextData,
  ) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      final token = await user?.getIdToken() ?? '';

      final url = Uri.parse('https://life-os-backend-gray.vercel.app/api/chat');

      // 🚀 Requisição HTTP blindada com timeout explícito
      final response = await client
          .post(
            url,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode({"message": text, "context": contextData}),
          )
          .timeout(
            _networkTimeout,
            onTimeout: () {
              throw TimeoutException(
                "O servidor demorou muito para responder. Verifique sua conexão e tente novamente.",
              );
            },
          );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['reply'] as String;
      } else {
        throw Exception(
          "O servidor Vercel respondeu com Status ${response.statusCode}: ${response.body}",
        );
      }
    } catch (e, stack) {
      AppLogger.e('Erro na comunicação com a API de IA', e, stack);
      rethrow;
    }
  }
}
