import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/features/ai_companion/presentation/providers/ai_consent_provider.dart';

class AiConsentView extends ConsumerWidget {
  const AiConsentView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      color: const Color(0xFF070B14), // Fundo padrão do Life OS
      padding: const EdgeInsets.all(24.0),
      child: Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: const Color(0xFFB026FF).withOpacity(0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.psychology,
                    size: 64,
                    color: Color(0xFFB026FF),
                  ),
                ),
              ),
              const SizedBox(height: 32),
              const Text(
                "Inteligência Artificial\nLife OS Companion",
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  height: 1.2,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              const Text(
                'Para gerar as análises que você solicitar, o Companion IA pode usar resumos dos dados que você registra no Life OS — como tarefas, hábitos, estudos, metas, Focus, check-ins, finanças e bem-estar. Apenas os dados necessários para cada análise são enviados. A geração requer conexão com a internet.',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 14,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Nesta versão são enviados agregados, não títulos de tarefas ou metas, nomes de hábitos ou disciplinas, descrições de transações, IDs, e-mail ou nomes de medicamentos.',
                style: TextStyle(
                  color: Colors.white54,
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 32),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.amberAccent.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Colors.amberAccent.withOpacity(0.3),
                  ),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.shield_outlined, color: Colors.amberAccent),
                    SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'O uso da IA é opcional e nenhuma análise é feita sem uma ação sua. Você pode revogar o consentimento a qualquer momento nas opções do Companion; novas análises só serão autorizadas após novo aceite.',
                        style: TextStyle(
                          color: Colors.amberAccent,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFB026FF),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  onPressed: () async {
                    try {
                      await ref
                          .read(aiConsentProvider.notifier)
                          .acceptConsent();
                    } catch (_) {
                      // O notifier já publica AsyncError e a tela oferece nova tentativa.
                    }
                  },
                  child: const Text(
                    "Permitir acesso aos meus dados",
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
