import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/features/ai_companion/data/models/ai_insight.dart';
import 'package:life_os/features/ai_companion/presentation/ai_companion_hub.dart';
import 'package:life_os/features/premium/presentation/premium_screen.dart';
import 'package:life_os/features/ai_companion/presentation/providers/ai_companion_provider.dart';
import 'package:life_os/features/premium/presentation/premium_provider.dart';
import 'package:life_os/features/ai_companion/presentation/providers/ai_consent_provider.dart';
import 'package:life_os/features/ai_companion/presentation/screens/ai_consent_view.dart';

class AICompanionScreen extends ConsumerStatefulWidget {
  const AICompanionScreen({super.key, this.initialIntent});

  final AIInsightIntent? initialIntent;

  @override
  ConsumerState<AICompanionScreen> createState() => _AICompanionScreenState();
}

class _AICompanionScreenState extends ConsumerState<AICompanionScreen> {
  bool _initialIntentHandled = false;

  void _request(AIInsightIntent intent) {
    final userId = ref.read(aiCompanionCurrentUserIdProvider)();
    if (userId == null || userId.isEmpty) return;
    ref
        .read(aiCompanionProvider.notifier)
        .requestInsight(intent, expectedUserId: userId);
  }

  void _scheduleInitialIntent() {
    if (_initialIntentHandled || widget.initialIntent == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _initialIntentHandled) return;
      final userId = ref.read(aiCompanionCurrentUserIdProvider)();
      if (userId == null || userId.isEmpty) return;
      _initialIntentHandled = true;
      ref
          .read(aiCompanionProvider.notifier)
          .requestInsight(widget.initialIntent!, expectedUserId: userId);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(premiumProvider).isPremium) {
      return _buildPremiumLockScreen();
    }

    final consent = ref.watch(aiConsentProvider);
    return consent.when(
      loading: () => const ColoredBox(
        color: Color(0xFF070B14),
        child: Center(
          child: CircularProgressIndicator(color: Color(0xFFB026FF)),
        ),
      ),
      error: (_, _) => ColoredBox(
        color: const Color(0xFF070B14),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Não foi possível verificar o consentimento.',
                style: TextStyle(color: Colors.white),
              ),
              TextButton(
                onPressed: () => ref.invalidate(aiConsentProvider),
                child: const Text('Tentar novamente'),
              ),
            ],
          ),
        ),
      ),
      data: (accepted) {
        if (!accepted) return const AiConsentView();
        _scheduleInitialIntent();
        final userId = ref.watch(aiCompanionCurrentUserIdProvider)();
        return AICompanionHub(
          state: ref.watch(aiCompanionProvider),
          localSummary: ref.watch(
            aiCompanionLocalSummaryProvider(userId ?? ''),
          ),
          onIntent: _request,
          onRevoke: _confirmAndRevokeConsent,
        );
      },
    );
  }

  Future<void> _confirmAndRevokeConsent() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Revogar consentimento da IA?'),
        content: const Text(
          'O Companion deixará de usar seus dados para gerar novas análises. '
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
                "Desbloqueie análises e insights sobre os dados do seu Life OS.",
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
