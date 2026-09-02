import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/features/ai_companion/data/repositories/ai_companion_repository.dart';
import 'package:life_os/features/premium/presentation/premium_screen.dart';
import 'package:life_os/features/ai_companion/presentation/providers/ai_companion_provider.dart';
import 'package:life_os/features/premium/presentation/premium_provider.dart';
import 'package:life_os/features/health/presentation/providers/health_provider.dart';
import 'package:life_os/features/ai_companion/presentation/providers/ai_consent_provider.dart';
import 'package:life_os/features/ai_companion/presentation/screens/ai_consent_view.dart';
import 'package:life_os/features/finance/presentation/providers/finance_provider.dart';

class AICompanionScreen extends ConsumerStatefulWidget {
  const AICompanionScreen({super.key});

  @override
  ConsumerState<AICompanionScreen> createState() => _AICompanionScreenState();
}

class _AICompanionScreenState extends ConsumerState<AICompanionScreen> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  String _requireAuthenticatedUserId() {
    final userId = FirebaseAuth.instance.currentUser?.uid;
    if (userId == null || userId.isEmpty) {
      throw const AIAuthenticationException();
    }
    return userId;
  }

  void _ensureExpectedSession(String expectedUserId) {
    if (FirebaseAuth.instance.currentUser?.uid != expectedUserId) {
      throw const AIAuthenticationException();
    }
  }

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

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 1. CHECAGEM DE STATUS PREMIUM
    final premiumStatus = ref.watch(premiumProvider);
    final isPremium = premiumStatus.isPremium;

    if (!isPremium) {
      return _buildPremiumLockScreen();
    }

    // 2. CHECAGEM DE CONSENTIMENTO LGPD (OPT-IN)
    // Se o usuário é Premium mas ainda não aceitou os termos, mostra a tela de aceite.
    final consentState = ref.watch(aiConsentProvider);

    return consentState.when(
      loading: () => const Scaffold(
        backgroundColor: Color(0xFF070B14),
        body: Center(
          child: CircularProgressIndicator(color: Colors.purpleAccent),
        ),
      ),
      error: (error, stackTrace) => Scaffold(
        backgroundColor: const Color(0xFF070B14),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.error_outline_rounded,
                  color: Colors.redAccent,
                  size: 48,
                ),
                const SizedBox(height: 16),
                const Text(
                  'Não foi possível verificar o consentimento.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Tente novamente.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white54),
                ),
                const SizedBox(height: 20),
                ElevatedButton(
                  onPressed: () {
                    ref.invalidate(aiConsentProvider);
                  },
                  child: const Text('Tentar novamente'),
                ),
              ],
            ),
          ),
        ),
      ),
      data: (hasConsented) {
        if (!hasConsented) {
          return const AiConsentView();
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
      },
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
                "Assistente de IA do Life OS",
                style: TextStyle(color: Colors.greenAccent, fontSize: 11),
              ),
            ],
          ),
        ],
      ),
      actions: [
        IconButton(
          key: const ValueKey('revoke-ai-consent'),
          tooltip: 'Revogar consentimento da IA',
          onPressed: _confirmAndRevokeConsent,
          icon: const Icon(Icons.privacy_tip_outlined, color: Colors.white70),
        ),
      ],
    );
  }

  Future<void> _confirmAndRevokeConsent() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Revogar consentimento da IA?'),
        content: const Text(
          'O Companion deixará de usar seus dados para gerar novas respostas. '
          'Seus demais dados e históricos não serão apagados.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            key: const ValueKey('confirm-revoke-ai-consent'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Revogar consentimento'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    try {
      await ref.read(aiConsentProvider.notifier).revokeConsent();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Não foi possível revogar o consentimento da IA.'),
        ),
      );
    }
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
                hintText: "Converse com o Companion IA...",
                hintStyle: const TextStyle(color: Colors.white38),
                filled: true,
                fillColor: const Color(0xFF070B14),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                counterText: "",
              ),
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
              onPressed: aiState.isLoading ? null : _handleSendMessage,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _handleSendMessage() async {
    final text = _controller.text.trim();

    if (text.isEmpty) return;

    try {
      final expectedUserId = _requireAuthenticatedUserId();
      final hasConsented = ref.read(aiConsentProvider).value ?? false;
      _ensureExpectedSession(expectedUserId);

      if (!hasConsented) {
        if (!mounted) return;

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Aceite o consentimento para permitir o uso dos seus dados pelo Companion.',
            ),
          ),
        );

        return;
      }

      _controller.clear();

      // ----------------------------------------------------------------------
      // 1. SINCRONIZAÇÃO
      // ----------------------------------------------------------------------

      await ref.read(healthRepositoryProvider).syncHealthFromFirebase();
      _ensureExpectedSession(expectedUserId);

      // ----------------------------------------------------------------------
      // 2. LEITURA DOS ESTADOS ATUAIS
      //
      // O Companion usa os providers de dados completos,
      // nunca os providers destinados apenas à apresentação/paginação.
      // ----------------------------------------------------------------------

      final healthAsyncValue = ref.read(healthStreamProvider);
      final medicationsAsyncValue = ref.read(medicationsStreamProvider);
      final financeAsyncValue = ref.read(financeStreamProvider);
      _ensureExpectedSession(expectedUserId);

      final health = healthAsyncValue.asData?.value;
      final medications = medicationsAsyncValue.asData?.value ?? [];
      final transactions = financeAsyncValue.asData?.value ?? [];

      final now = DateTime.now();
      final activeMedications = medications
          .where((medication) {
            final hasStarted = !medication.startDate.isAfter(now);
            final hasNotEnded =
                medication.endDate == null ||
                !medication.endDate!.isBefore(now);
            return hasStarted && hasNotEnded;
          })
          .toList(growable: false);

      // ----------------------------------------------------------------------
      // 3. CÁLCULO FINANCEIRO
      // ----------------------------------------------------------------------

      double totalIncome = 0.0;
      double totalExpense = 0.0;

      for (final transaction in transactions) {
        if (transaction.type == 'income') {
          totalIncome += transaction.amount;
        } else if (transaction.type == 'expense') {
          totalExpense += transaction.amount;
        }
      }

      final balance = totalIncome - totalExpense;

      final financeSummary = {
        'saldo_atual': balance,
        'total_entradas': totalIncome,
        'total_saidas': totalExpense,
      };

      // ----------------------------------------------------------------------
      // 4. MONTAGEM DO CONTEXTO
      //
      // Só chegamos aqui depois de validar o consentimento.
      // ----------------------------------------------------------------------

      final repository = ref.read(aiCompanionRepositoryProvider);

      final contextData = await repository.getSystemContext(
        message: text,
        hasConsent: hasConsented,
        health: health,
        medications: activeMedications,
        finance: financeSummary,
      );
      _ensureExpectedSession(expectedUserId);

      // ----------------------------------------------------------------------
      // 5. ENVIO
      // ----------------------------------------------------------------------

      await ref
          .read(aiCompanionProvider.notifier)
          .sendMessage(text, contextData, expectedUserId: expectedUserId);
    } catch (e) {
      if (!mounted) return;

      if (e.toString().contains("PREMIUM_REQUIRED")) {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const PremiumScreen()),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Não foi possível processar a mensagem.")),
        );
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
                child: const Text("Desbloquear com Premium"),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
