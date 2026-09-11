import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/features/study/presentation/providers/study_provider.dart';

const _backgroundColor = Color(0xFF070B14);
const _surfaceColor = Color(0xFF11182E);
const _primaryColor = Color(0xFFB026FF);
const _primaryEndColor = Color(0xFFD94CFF);

class RevisarScreen extends ConsumerStatefulWidget {
  const RevisarScreen({super.key});

  @override
  ConsumerState<RevisarScreen> createState() => _RevisarScreenState();
}

class _RevisarScreenState extends ConsumerState<RevisarScreen> {
  bool showAnswer = false;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        ref.read(studyRepositoryProvider).syncStudyFromFirebaseToLocal(),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final cardsAsync = ref.watch(flashcardStreamProvider);

    return Scaffold(
      backgroundColor: _backgroundColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text(
          'Revisão',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
        ),
      ),
      body: SafeArea(
        top: false,
        child: cardsAsync.when(
          loading: () => const Center(
            child: CircularProgressIndicator(color: _primaryColor),
          ),
          error: (_, _) => const _ReviewMessageState(
            icon: Icons.cloud_off_rounded,
            title: 'Não foi possível carregar as revisões agora.',
            description: 'Tente novamente em alguns instantes.',
          ),
          data: (cards) {
            if (cards.isEmpty) {
              return _ReviewCompleteState(onBack: () => Navigator.pop(context));
            }

            final card = cards.first;
            final remainingLabel = cards.length == 1
                ? '1 revisão restante'
                : '${cards.length} revisões restantes';

            return LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 32),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: constraints.maxHeight - 50,
                  ),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 680),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 38,
                                height: 38,
                                decoration: BoxDecoration(
                                  color: _primaryColor.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(13),
                                ),
                                child: const Icon(
                                  Icons.auto_stories_rounded,
                                  color: _primaryEndColor,
                                  size: 20,
                                ),
                              ),
                              const SizedBox(width: 11),
                              Expanded(
                                child: Text(
                                  remainingLabel,
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 18),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(24),
                            decoration: BoxDecoration(
                              color: _surfaceColor,
                              borderRadius: BorderRadius.circular(27),
                              border: Border.all(
                                color: _primaryColor.withValues(alpha: 0.25),
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: _primaryColor.withValues(alpha: 0.1),
                                  blurRadius: 26,
                                  offset: const Offset(0, 12),
                                ),
                              ],
                            ),
                            child: Column(
                              children: [
                                const _CardSectionLabel(
                                  icon: Icons.help_outline_rounded,
                                  label: 'PERGUNTA',
                                ),
                                const SizedBox(height: 18),
                                Text(
                                  card.question,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 22,
                                    fontWeight: FontWeight.w700,
                                    height: 1.35,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                                if (showAnswer) ...[
                                  const Padding(
                                    padding: EdgeInsets.symmetric(vertical: 26),
                                    child: Divider(color: Colors.white12),
                                  ),
                                  const _CardSectionLabel(
                                    icon: Icons.lightbulb_outline_rounded,
                                    label: 'RESPOSTA',
                                  ),
                                  const SizedBox(height: 18),
                                  Text(
                                    card.answer,
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 18,
                                      height: 1.45,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                ],
                              ],
                            ),
                          ),
                          const SizedBox(height: 24),
                          SizedBox(
                            width: double.infinity,
                            height: 54,
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: _primaryColor,
                                disabledBackgroundColor: _primaryColor
                                    .withValues(alpha: 0.45),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(18),
                                ),
                              ),
                              onPressed: !showAnswer
                                  ? () => setState(() => showAnswer = true)
                                  : _isSubmitting
                                  ? null
                                  : () async {
                                      if (_isSubmitting) return;
                                      setState(() => _isSubmitting = true);
                                      try {
                                        await ref
                                            .read(studyRepositoryProvider)
                                            .completeCard(card.id);
                                        if (!mounted) return;
                                        setState(() => showAnswer = false);
                                      } finally {
                                        if (mounted) {
                                          setState(() => _isSubmitting = false);
                                        }
                                      }
                                    },
                              child: _isSubmitting
                                  ? const SizedBox.square(
                                      dimension: 20,
                                      child: CircularProgressIndicator(
                                        color: Colors.white,
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : Text(
                                      showAnswer
                                          ? 'Marcar como revisado'
                                          : 'Ver resposta',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _CardSectionLabel extends StatelessWidget {
  const _CardSectionLabel({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, color: _primaryEndColor, size: 16),
        const SizedBox(width: 7),
        Text(
          label,
          style: const TextStyle(
            color: _primaryEndColor,
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.3,
          ),
        ),
      ],
    );
  }
}

class _ReviewCompleteState extends StatelessWidget {
  const _ReviewCompleteState({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return _ReviewMessageState(
      icon: Icons.task_alt_rounded,
      title: 'Revisões concluídas',
      description: 'Você está em dia por hoje.',
      actionLabel: 'Voltar aos estudos',
      onAction: onBack,
    );
  }
}

class _ReviewMessageState extends StatelessWidget {
  const _ReviewMessageState({
    required this.icon,
    required this.title,
    required this.description,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String description;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 76,
                height: 76,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF5D0EFF), _primaryColor],
                  ),
                  borderRadius: BorderRadius.circular(25),
                  boxShadow: [
                    BoxShadow(
                      color: _primaryColor.withValues(alpha: 0.22),
                      blurRadius: 26,
                    ),
                  ],
                ),
                child: Icon(icon, color: Colors.white, size: 36),
              ),
              const SizedBox(height: 24),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 21,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                description,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white60,
                  fontSize: 14,
                  height: 1.4,
                ),
              ),
              if (actionLabel != null && onAction != null) ...[
                const SizedBox(height: 24),
                OutlinedButton.icon(
                  onPressed: onAction,
                  icon: const Icon(Icons.arrow_back_rounded, size: 18),
                  label: Text(actionLabel!),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: BorderSide(
                      color: _primaryColor.withValues(alpha: 0.5),
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 13,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
