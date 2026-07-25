import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/features/study/presentation/providers/study_provider.dart';

class RevisarScreen extends ConsumerStatefulWidget {
  const RevisarScreen({super.key});

  @override
  ConsumerState<RevisarScreen> createState() => _RevisarScreenState();
}

class _RevisarScreenState extends ConsumerState<RevisarScreen> {
  bool showAnswer = false; // Estado para controlar a visibilidade da resposta
  bool _isLoadingSync = true; // Estado de controle da sincronização prévia

  @override
  void initState() {
    super.initState();
    _initializeReviewSession();
  }

  Future<void> _initializeReviewSession() async {
    // Sincroniza os dados do Firestore para o banco local Drift ao entrar na tela de revisão
    await ref.read(studyRepositoryProvider).syncStudyFromFirebaseToLocal();
    if (mounted) {
      setState(() {
        _isLoadingSync = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Exibe o carregamento inicial enquanto a sincronização offline-first é concluída
    if (_isLoadingSync) {
      return Scaffold(
        backgroundColor: const Color(0xFF070B14),
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          iconTheme: const IconThemeData(color: Colors.white),
          title: const Text(
            "Revisão Ativa",
            style: TextStyle(color: Colors.white),
          ),
        ),
        body: const Center(
          child: CircularProgressIndicator(color: Colors.purpleAccent),
        ),
      );
    }

    final cardsAsync = ref.watch(flashcardStreamProvider);

    return Scaffold(
      backgroundColor: const Color(0xFF070B14),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text(
          "Revisão Ativa",
          style: TextStyle(color: Colors.white),
        ),
      ),
      body: Center(
        child: cardsAsync.when(
          loading: () =>
              const CircularProgressIndicator(color: Colors.purpleAccent),
          error: (err, _) =>
              Text("Erro: $err", style: const TextStyle(color: Colors.red)),
          data: (cards) {
            if (cards.isEmpty) {
              return const Text(
                "Tudo revisado! Parabéns! 🎉",
                style: TextStyle(color: Colors.white),
              );
            }

            final card = cards.first;

            return Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // CARD DE PERGUNTA
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(32),
                    decoration: BoxDecoration(
                      color: const Color(0xFF11182E),
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Column(
                      children: [
                        const Text(
                          "PERGUNTA",
                          style: TextStyle(color: Colors.white38, fontSize: 12),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          card.question,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                          ),
                          textAlign: TextAlign.center,
                        ),

                        // SE O USUÁRIO CLICOU EM "VER RESPOSTA", MOSTRA A RESPOSTA
                        if (showAnswer) ...[
                          const Divider(color: Colors.white12, height: 40),
                          const Text(
                            "RESPOSTA",
                            style: TextStyle(
                              color: Colors.purpleAccent,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            card.answer,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 18,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 40),

                  // LÓGICA DOS BOTÕES
                  if (!showAnswer)
                    ElevatedButton(
                      onPressed: () => setState(() => showAnswer = true),
                      child: const Text("Ver Resposta"),
                    )
                  else
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                      ),
                      onPressed: () {
                        setState(
                          () => showAnswer = false,
                        ); // Reseta a visão para o próximo card

                        // Aqui chamamos a ação de concluir/avançar o card na fila de estudos
                        ref.read(studyRepositoryProvider).completeCard(card.id);
                      },
                      child: const Text("Acertei! Marcar como Revisado"),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
