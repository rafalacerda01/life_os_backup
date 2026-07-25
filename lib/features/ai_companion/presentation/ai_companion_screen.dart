import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:life_os/features/premium/presentation/premium_screen.dart';
import 'package:life_os/features/ai_companion/presentation/providers/ai_companion_provider.dart';
import 'package:life_os/features/premium/presentation/premium_provider.dart'; // ✅ Import adicionado
import 'package:life_os/features/health/presentation/providers/health_provider.dart';

class AICompanionScreen extends ConsumerStatefulWidget {
  const AICompanionScreen({super.key});

  @override
  ConsumerState<AICompanionScreen> createState() => _AICompanionScreenState();
}

class _AICompanionScreenState extends ConsumerState<AICompanionScreen> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<Map<String, dynamic>> _getCurrentHealthContext() async {
    await ref.read(healthRepositoryProvider).syncHealthFromFirebase();

    final healthAsyncValue = ref.read(healthStreamProvider);
    final medicationsAsyncValue = ref.read(medicationsStreamProvider);

    // Agora, após o await do sync, o stream de medicamentos deve estar populado
    final Map<String, dynamic> healthContext = healthAsyncValue.maybeWhen(
      data: (health) => {
        "humor": health.mood.isNotEmpty ? health.mood : "Ainda não registrado",
        "hidratacao": "${health.waterIntakeMl}ml",
        "medicamentos": medicationsAsyncValue.maybeWhen(
          data: (meds) => meds.isNotEmpty
              ? meds.map((m) => m.name).join(', ')
              : "Nenhum medicamento ativo",
          orElse: () => "Nenhum medicamento registrado",
        ),
      },
      orElse: () => {
        "humor": "Dados indisponíveis",
        "hidratacao": "0ml",
        "medicamentos": "Dados indisponíveis",
      },
    );

    // ... restante do seu código (Firestore userDoc e financeDoc)

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        // 1. Ciclo menstrual
        final userDoc = await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .get();

        if (userDoc.exists) {
          healthContext["ciclo_menstrual"] =
              userDoc.data()?['menstrualCycle'] ?? "Não rastreado";
        }

        // 2. Finanças
        final financeDoc = await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .collection('finance')
            .doc('main')
            .get();

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
    } catch (e) {
      debugPrint("Erro ao buscar contexto para IA: $e");
      healthContext["ciclo_menstrual"] = "Erro ao carregar";
      healthContext["financas"] = "Erro ao carregar";
    }

    healthContext["data_coleta"] = DateTime.now().toIso8601String();
    healthContext["status"] = "Online";

    return healthContext;
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // ✅ CORREÇÃO 1: Usando o provider correto (que ouve o Firebase em tempo real)
    final premiumStatus = ref.watch(premiumProvider);
    final isPremium = premiumStatus.isPremium;

    if (!isPremium) {
      return _buildPremiumLockScreen();
    }

    final aiState = ref.watch(aiCompanionProvider);
    _scrollToBottom();

    return Scaffold(
      backgroundColor: const Color(0xFF070B14),
      appBar: _buildAppBar(),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.all(20),
                itemCount: aiState.messages.length,
                itemBuilder: (context, index) {
                  final message = aiState.messages[index];
                  return _buildMessageBubble(message);
                },
              ),
            ),
            if (aiState.isLoading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 10),
                child: Center(
                  child: SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(
                      color: Colors.purpleAccent,
                      strokeWidth: 2,
                    ),
                  ),
                ),
              ),
            _buildInputArea(aiState),
          ],
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: const Color(0xFF11182E),
      elevation: 0,
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.purpleAccent.withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.psychology_rounded,
              color: Colors.purpleAccent,
            ),
          ),
          const SizedBox(width: 12),
          const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "Companion IA",
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                "Online • Core 3.5 Flash",
                style: TextStyle(color: Colors.greenAccent, fontSize: 11),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(dynamic message) {
    return Align(
      alignment: message.isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(16),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        decoration: BoxDecoration(
          color: message.isUser
              ? const Color(0xFF5D0EFF)
              : const Color(0xFF11182E),
          borderRadius: BorderRadius.circular(16).copyWith(
            bottomRight: message.isUser
                ? const Radius.circular(0)
                : const Radius.circular(16),
            topLeft: !message.isUser
                ? const Radius.circular(0)
                : const Radius.circular(16),
          ),
          border: Border.all(
            color: message.isUser ? Colors.transparent : Colors.white10,
          ),
        ),
        child: Text(
          message.text,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 15,
            height: 1.4,
          ),
        ),
      ),
    );
  }

  Widget _buildInputArea(dynamic aiState) {
    return Container(
      padding: const EdgeInsets.all(16),
      color: const Color(0xFF11182E),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _controller,
              maxLength: 300,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: "Fale com o Core do sistema...",
                hintStyle: const TextStyle(color: Colors.white38),
                filled: true,
                fillColor: const Color(0xFF070B14),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                counterText:
                    "", // Esconde o contador de caracteres para um visual mais limpo
              ),
              // Permite enviar apertando "Enter" no teclado
              onSubmitted: (_) => _handleSendMessage(),
            ),
          ),
          const SizedBox(width: 12),
          Container(
            decoration: const BoxDecoration(
              color: Colors.purpleAccent,
              shape: BoxShape.circle,
            ),
            child: IconButton(
              icon: const Icon(
                Icons.send_rounded,
                color: Colors.white,
                size: 20,
              ),
              // ✅ O botão de envio fica desativado se já estiver carregando
              onPressed: aiState.isLoading ? null : _handleSendMessage,
            ),
          ),
        ],
      ),
    );
  }

  // ✅ CORREÇÃO 3: UX aprimorada - Limpa o campo imediatamente e previne múltiplos cliques
  Future<void> _handleSendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    // Limpa o campo instantaneamente, antes do processamento assíncrono começar
    _controller.clear();

    // Opcional: Se quiser que o teclado feche após enviar
    // FocusScope.of(context).unfocus();

    final contextData = await _getCurrentHealthContext();

    try {
      await ref
          .read(aiCompanionProvider.notifier)
          .sendMessage(text, contextData);
    } catch (e) {
      if (!mounted) return; // Proteção contra widget desmontado

      if (e.toString().contains("PREMIUM_REQUIRED")) {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const PremiumScreen()),
        );
      } else {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("Erro: ${e.toString()}")));
      }
    }
  }

  Widget _buildPremiumLockScreen() {
    return Scaffold(
      backgroundColor: const Color(0xFF070B14),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: const Color(0xFF11182E),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Colors.purpleAccent.withOpacity(0.3),
                      width: 2,
                    ),
                  ),
                  child: const Icon(
                    Icons.psychology_rounded,
                    color: Colors.purpleAccent,
                    size: 64,
                  ),
                ),
              ),
              const SizedBox(height: 32),
              const Text(
                "Companion IA",
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                "Converse com a inteligência artificial para otimizar sua rotina.",
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white54,
                  fontSize: 14,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 40),
              ElevatedButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const PremiumScreen()),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.purpleAccent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text("Desbloquear com Plano PRO"),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
