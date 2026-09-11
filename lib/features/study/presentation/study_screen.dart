import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'providers/study_provider.dart';
import 'package:life_os/features/study/presentation/screens/revisar_screen.dart';
import 'package:life_os/features/focus/presentation/providers/screens/focus_screen.dart'; // ⏱️ Importação da Tela de Foco
import 'package:life_os/features/premium/domain/services/plan_limits.dart';
import 'package:life_os/features/premium/domain/services/quota_service.dart';
import 'package:life_os/features/premium/presentation/plan_limits_provider.dart';
import 'package:life_os/core/security/input_sanitizer.dart';
import 'package:life_os/features/study/data/models/study_model.dart';
import 'package:life_os/features/study/domain/entities/study_subject_entity.dart';

const _backgroundColor = Color(0xFF070B14);
const _surfaceColor = Color(0xFF11182E);
const _sheetColor = Color(0xFF0A0F1E);
const _primaryColor = Color(0xFFB026FF);
const _primaryStartColor = Color(0xFF5D0EFF);
const _primaryEndColor = Color(0xFFD94CFF);

String? validateSubjectExamDate({
  required bool hasExam,
  required DateTime? examDate,
}) {
  if (hasExam && examDate == null) {
    return 'Selecione a data da prova.';
  }

  return null;
}

class StudyScreen extends ConsumerStatefulWidget {
  const StudyScreen({super.key});

  @override
  ConsumerState<StudyScreen> createState() => _StudyScreenState();
}

class _StudyScreenState extends ConsumerState<StudyScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(studyRepositoryProvider).syncStudyFromFirebaseToLocal();
    });
  }

  void _showDeleteConfirmation(
    BuildContext context,
    WidgetRef ref,
    String subjectId,
    String subjectTitle,
  ) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: _surfaceColor,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
          title: const Text(
            "Excluir Disciplina?",
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          content: Text(
            "Tem certeza que deseja apagar \"$subjectTitle\"? Essa ação removerá a matéria do seu painel.",
            style: const TextStyle(color: Colors.white70, fontSize: 14),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text(
                "Cancelar",
                style: TextStyle(
                  color: Colors.white38,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent.withValues(alpha: 0.85),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onPressed: () {
                ref.read(studyRepositoryProvider).removeSubject(subjectId);
                Navigator.pop(context);
              },
              child: const Text(
                "Excluir",
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  void _showAddSubjectModal(BuildContext context, WidgetRef ref) {
    final titleController = TextEditingController();
    bool hasExam = false;
    DateTime? selectedDate;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _sheetColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return SingleChildScrollView(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom + 20,
                top: 12,
                left: 20,
                right: 20,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _SheetHandle(),
                  const SizedBox(height: 22),
                  const Text(
                    "Nova disciplina",
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Organize seus flashcards e acompanhe o progresso.',
                    style: TextStyle(color: Colors.white60, fontSize: 14),
                  ),
                  const SizedBox(height: 22),
                  TextField(
                    controller: titleController,
                    style: const TextStyle(color: Colors.white),
                    decoration: _sheetInputDecoration(
                      labelText: "Nome da disciplina",
                      prefixIcon: Icons.menu_book_rounded,
                    ),
                  ),
                  const SizedBox(height: 16),

                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text(
                      "Possui prova agendada?",
                      style: TextStyle(color: Colors.white70),
                    ),
                    value: hasExam,
                    activeColor: _primaryColor,
                    onChanged: (val) => setModalState(() => hasExam = val),
                  ),

                  if (hasExam)
                    OutlinedButton.icon(
                      onPressed: () async {
                        final date = await showDatePicker(
                          context: context,
                          initialDate: DateTime.now(),
                          firstDate: DateTime.now(),
                          lastDate: DateTime(2100),
                        );
                        if (date != null)
                          setModalState(() => selectedDate = date);
                      },
                      icon: const Icon(
                        Icons.calendar_today,
                        color: Colors.white70,
                      ),
                      label: Text(
                        selectedDate == null
                            ? "Selecione a data da prova"
                            : DateFormat('dd/MM/yyyy').format(selectedDate!),
                        style: const TextStyle(color: Colors.white70),
                      ),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Colors.white24),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                      ),
                    ),

                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    height: 54,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _primaryColor,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18),
                        ),
                      ),
                      onPressed: () async {
                        final title = InputSanitizer.sanitize(
                          titleController.text.trim(),
                        );

                        if (title.isEmpty) {
                          return;
                        }

                        final examDateError = validateSubjectExamDate(
                          hasExam: hasExam,
                          examDate: selectedDate,
                        );

                        if (examDateError != null) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(examDateError)),
                            );
                          }
                          return;
                        }

                        final subjectsAsync = ref.read(subjectsStreamProvider);

                        if (!subjectsAsync.hasValue) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Não foi possível verificar suas disciplinas agora. Tente novamente.',
                                ),
                              ),
                            );
                          }
                          return;
                        }

                        final subjects = subjectsAsync.requireValue;

                        final limits = ref.read(planLimitsProvider);
                        const quotaService = QuotaService();

                        final subjectLimit = limits.limitFor(
                          QuotaResource.subjects,
                        );

                        final canCreate = quotaService.canCreate(
                          limit: subjectLimit,
                          currentCount: subjects.length,
                        );

                        if (!canCreate) {
                          final message = switch (subjectLimit.mode) {
                            QuotaMode.disabled =>
                              'Este recurso não está disponível no seu plano.',
                            QuotaMode.limited =>
                              'Você atingiu o limite de ${subjectLimit.maximum} disciplinas do seu plano.',
                            QuotaMode.unlimited =>
                              'Você não possui limite de disciplinas.',
                            QuotaMode.notConfigured =>
                              'O limite deste recurso ainda não está configurado.',
                          };

                          if (context.mounted) {
                            ScaffoldMessenger.of(
                              context,
                            ).showSnackBar(SnackBar(content: Text(message)));
                          }

                          return;
                        }

                        await ref
                            .read(studyRepositoryProvider)
                            .createSubject(
                              title,
                              hasExam: hasExam,
                              examDate: selectedDate,
                            );

                        if (context.mounted) {
                          Navigator.pop(context);
                        }
                      },
                      child: const Text(
                        "Adicionar Disciplina",
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _showAddFlashcardModal(BuildContext context, WidgetRef ref) {
    final questionController = TextEditingController();
    final answerController = TextEditingController();
    String? selectedSubjectId;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _sheetColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
      ),
      builder: (context) {
        return Consumer(
          builder: (context, ref, child) {
            final subjectsAsync = ref.watch(subjectsStreamProvider);

            return SingleChildScrollView(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom + 20,
                top: 12,
                left: 20,
                right: 20,
              ),
              child: StatefulBuilder(
                builder: (context, setModalState) {
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _SheetHandle(),
                      const SizedBox(height: 22),
                      const Text(
                        "Novo Flashcard",
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Crie uma pergunta objetiva para revisar depois.',
                        style: TextStyle(color: Colors.white60, fontSize: 14),
                      ),
                      const SizedBox(height: 22),
                      subjectsAsync.when(
                        loading: () => const Center(
                          child: CircularProgressIndicator(
                            color: Color(0xFFB026FF),
                          ),
                        ),
                        error: (_, _) => const Text(
                          "Não foi possível carregar suas disciplinas agora.",
                          style: TextStyle(color: Colors.redAccent),
                        ),
                        data: (subjects) {
                          if (subjects.isEmpty) {
                            return const Padding(
                              padding: EdgeInsets.symmetric(vertical: 8.0),
                              child: Text(
                                "Você precisa criar pelo menos uma disciplina antes de adicionar flashcards.",
                                style: TextStyle(
                                  color: Colors.orangeAccent,
                                  fontSize: 13,
                                ),
                              ),
                            );
                          }
                          return Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            decoration: BoxDecoration(
                              color: _surfaceColor,
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(color: Colors.white10),
                            ),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<String>(
                                value: selectedSubjectId,
                                hint: const Text(
                                  "Selecione a Disciplina",
                                  style: TextStyle(color: Colors.white38),
                                ),
                                dropdownColor: _surfaceColor,
                                isExpanded: true,
                                style: const TextStyle(color: Colors.white),
                                items: subjects.map((sub) {
                                  return DropdownMenuItem<String>(
                                    value: sub.id,
                                    child: Text(sub.title),
                                  );
                                }).toList(),
                                onChanged: (val) {
                                  setModalState(() {
                                    selectedSubjectId = val;
                                  });
                                },
                              ),
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: questionController,
                        style: const TextStyle(color: Colors.white),
                        decoration: _sheetInputDecoration(
                          labelText: "Pergunta",
                          prefixIcon: Icons.help_outline_rounded,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: answerController,
                        style: const TextStyle(color: Colors.white),
                        decoration: _sheetInputDecoration(
                          labelText: "Resposta",
                          prefixIcon: Icons.lightbulb_outline_rounded,
                        ),
                      ),
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        height: 54,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _primaryColor,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(18),
                            ),
                          ),
                          onPressed: () async {
                            final question = InputSanitizer.sanitize(
                              questionController.text,
                            );
                            final answer = InputSanitizer.sanitize(
                              answerController.text,
                            );

                            if (selectedSubjectId != null &&
                                question.isNotEmpty &&
                                answer.isNotEmpty) {
                              await ref
                                  .read(studyRepositoryProvider)
                                  .addFlashcard(
                                    selectedSubjectId!,
                                    question,
                                    answer,
                                  );
                              if (context.mounted) Navigator.pop(context);
                            } else {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    "Selecione a disciplina e preencha todos os campos.",
                                  ),
                                  backgroundColor: Colors.redAccent,
                                ),
                              );
                            }
                          },
                          child: const Text(
                            "Criar Flashcard",
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _confirmReset(BuildContext context, StudyModel study) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: _surfaceColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        title: const Text(
          'Resetar progresso diário?',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
        ),
        content: const Text(
          'O progresso de hoje voltará ao início. Sua sequência e suas disciplinas serão mantidas.',
          style: TextStyle(color: Colors.white70, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text(
              'Cancelar',
              style: TextStyle(color: Colors.white60),
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: _primaryColor,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            child: const Text('Resetar', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;
    await ref.read(studyRepositoryProvider).resetDailyProgress(study);
  }

  @override
  Widget build(BuildContext context) {
    final studyAsync = ref.watch(studyStreamProvider);
    final subjectsAsync = ref.watch(subjectsStreamProvider);

    return Scaffold(
      backgroundColor: _backgroundColor,
      body: SafeArea(
        child: studyAsync.when(
          loading: () => const _StudyLoadingState(),
          error: (_, _) => const _StudyErrorState(
            message: 'Não foi possível carregar seus estudos agora.',
          ),
          data: (study) => subjectsAsync.when(
            loading: () => const _StudyLoadingState(),
            error: (_, _) => const _StudyErrorState(
              message: 'Não foi possível carregar suas disciplinas agora.',
            ),
            data: (subjects) => SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 112),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Estudos',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 30,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.7,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Organize sua rotina e mantenha o aprendizado em dia.',
                    style: TextStyle(
                      color: Colors.white60,
                      fontSize: 14,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 24),
                  _ReviewHeroCard(
                    reviewCount: study.reviewQueue,
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const RevisarScreen(),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 16),
                  _StudyMetricsCard(
                    streak: study.streak,
                    progress: study.progress,
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: () => _confirmReset(context, study),
                      icon: const Icon(Icons.refresh_rounded, size: 17),
                      label: const Text('Resetar progresso diário'),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white54,
                        textStyle: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  const _SectionTitle(
                    title: 'Ações de estudo',
                    subtitle: 'Continue sua rotina',
                  ),
                  const SizedBox(height: 12),
                  _SecondaryStudyAction(
                    icon: Icons.add_card_rounded,
                    title: 'Adicionar novo flashcard',
                    subtitle: 'Crie uma pergunta para revisar depois',
                    onTap: () => _showAddFlashcardModal(context, ref),
                  ),
                  const SizedBox(height: 10),
                  _SecondaryStudyAction(
                    icon: Icons.timer_outlined,
                    title: 'Estudar agora',
                    subtitle: subjects.isNotEmpty
                        ? 'Abrir temporizador de foco e estudos'
                        : 'Adicione uma disciplina para desbloquear',
                    enabled: subjects.isNotEmpty,
                    onTap: () {
                      if (subjects.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Cadastre pelo menos uma disciplina para estudar!',
                            ),
                            backgroundColor: Colors.orangeAccent,
                          ),
                        );
                        return;
                      }

                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const FocusScreen(),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 28),
                  const _SectionTitle(
                    title: 'Minhas disciplinas',
                    subtitle: 'Acompanhe seu avanço',
                  ),
                  const SizedBox(height: 14),
                  if (subjects.isEmpty)
                    const _SubjectsEmptyState()
                  else
                    ...subjects.map(
                      (subject) => Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _SubjectCard(
                          subject: subject,
                          onDelete: () => _showDeleteConfirmation(
                            context,
                            ref,
                            subject.id,
                            subject.title,
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
      floatingActionButton: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: _primaryColor.withValues(alpha: 0.28),
              blurRadius: 22,
              spreadRadius: 1,
            ),
          ],
        ),
        child: FloatingActionButton(
          tooltip: 'Adicionar disciplina',
          backgroundColor: _primaryColor,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          onPressed: () => _showAddSubjectModal(context, ref),
          child: const Icon(Icons.add_rounded, color: Colors.white),
        ),
      ),
    );
  }
}

class _ReviewHeroCard extends StatelessWidget {
  const _ReviewHeroCard({required this.reviewCount, required this.onTap});

  final int reviewCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hasReviews = reviewCount > 0;
    final countLabel = reviewCount == 1 ? '1 revisão' : '$reviewCount revisões';

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [_primaryStartColor, _primaryColor, _primaryEndColor],
        ),
        borderRadius: BorderRadius.circular(26),
        boxShadow: [
          BoxShadow(
            color: _primaryColor.withValues(alpha: 0.22),
            blurRadius: 28,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(26),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(26),
          child: Padding(
            padding: const EdgeInsets.all(22),
            child: Row(
              children: [
                Container(
                  width: 54,
                  height: 54,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Icon(
                    hasReviews
                        ? Icons.auto_stories_rounded
                        : Icons.task_alt_rounded,
                    color: Colors.white,
                    size: 28,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        hasReviews ? 'Revisões de hoje' : 'Revisões em dia',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 19,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        hasReviews
                            ? '$countLabel aguardando você'
                            : 'Nenhum flashcard pendente por enquanto',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.78),
                          fontSize: 13,
                          height: 1.35,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        hasReviews ? 'Revisar agora' : 'Ver revisões',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(
                  Icons.arrow_forward_rounded,
                  color: Colors.white,
                  size: 24,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StudyMetricsCard extends StatelessWidget {
  const _StudyMetricsCard({required this.streak, required this.progress});

  final int streak;
  final double progress;

  @override
  Widget build(BuildContext context) {
    final safeProgress = progress.clamp(0.0, 1.0).toDouble();
    final percentage = (safeProgress * 100).round();

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: _surfaceColor,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
      ),
      child: Row(
        children: [
          Expanded(
            child: _MetricBlock(
              icon: Icons.local_fire_department_rounded,
              iconColor: const Color(0xFFFFB86B),
              value: '$streak',
              label: 'dias seguidos',
            ),
          ),
          Container(
            width: 1,
            height: 64,
            color: Colors.white.withValues(alpha: 0.09),
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Progresso diário',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Text(
                      '$percentage%',
                      style: const TextStyle(
                        color: _primaryEndColor,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(99),
                  child: LinearProgressIndicator(
                    value: safeProgress,
                    minHeight: 9,
                    backgroundColor: _backgroundColor,
                    valueColor: const AlwaysStoppedAnimation(_primaryColor),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricBlock extends StatelessWidget {
  const _MetricBlock({
    required this.icon,
    required this.iconColor,
    required this.value,
    required this.label,
  });

  final IconData icon;
  final Color iconColor;
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: iconColor, size: 24),
        const SizedBox(width: 10),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 23,
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white54, fontSize: 11),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        Text(
          subtitle,
          style: const TextStyle(color: Colors.white38, fontSize: 12),
        ),
      ],
    );
  }
}

class _SecondaryStudyAction extends StatelessWidget {
  const _SecondaryStudyAction({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.enabled = true,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final foreground = enabled ? Colors.white : Colors.white38;

    return Material(
      color: _surfaceColor,
      borderRadius: BorderRadius.circular(19),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(19),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: _primaryColor.withValues(alpha: enabled ? 0.14 : 0.06),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  icon,
                  color: enabled ? _primaryEndColor : Colors.white24,
                  size: 22,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: foreground,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: enabled ? Colors.white38 : Colors.white12,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SubjectCard extends StatelessWidget {
  const _SubjectCard({required this.subject, required this.onDelete});

  final StudySubjectEntity subject;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final safeProgress = subject.progress.clamp(0.0, 1.0).toDouble();
    final progressLabel = '${(safeProgress * 100).round()}%';
    final reviewLabel = subject.cardsToReview == 1
        ? '1 revisão'
        : '${subject.cardsToReview} revisões';

    return Container(
      padding: const EdgeInsets.fromLTRB(17, 16, 10, 16),
      decoration: BoxDecoration(
        color: _surfaceColor,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: _primaryColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(
                  Icons.school_outlined,
                  color: _primaryEndColor,
                  size: 22,
                ),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      subject.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        height: 1.25,
                      ),
                    ),
                    if (subject.hasExam && subject.examDate != null) ...[
                      const SizedBox(height: 5),
                      Text(
                        'Prova em ${DateFormat('dd/MM').format(subject.examDate!)}',
                        style: const TextStyle(
                          color: _primaryEndColor,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (subject.cardsToReview > 0)
                Container(
                  margin: const EdgeInsets.only(left: 8, top: 2),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: _primaryColor.withValues(alpha: 0.13),
                    borderRadius: BorderRadius.circular(99),
                  ),
                  child: Text(
                    reviewLabel,
                    style: const TextStyle(
                      color: _primaryEndColor,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              IconButton(
                tooltip: 'Excluir disciplina',
                onPressed: onDelete,
                icon: const Icon(
                  Icons.delete_outline_rounded,
                  color: Colors.white38,
                  size: 21,
                ),
              ),
            ],
          ),
          const SizedBox(height: 15),
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(99),
                  child: LinearProgressIndicator(
                    value: safeProgress,
                    minHeight: 6,
                    backgroundColor: _backgroundColor,
                    valueColor: const AlwaysStoppedAnimation(_primaryColor),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                progressLabel,
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SubjectsEmptyState extends StatelessWidget {
  const _SubjectsEmptyState();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 30),
      decoration: BoxDecoration(
        color: _surfaceColor,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: const Column(
        children: [
          Icon(Icons.school_outlined, color: _primaryEndColor, size: 38),
          SizedBox(height: 14),
          Text(
            'Comece sua área de estudos',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.w800,
            ),
          ),
          SizedBox(height: 7),
          Text(
            'Use o botão + para adicionar sua primeira disciplina.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white60, fontSize: 13, height: 1.4),
          ),
        ],
      ),
    );
  }
}

class _StudyLoadingState extends StatelessWidget {
  const _StudyLoadingState();

  @override
  Widget build(BuildContext context) {
    return const Center(child: CircularProgressIndicator(color: _primaryColor));
  }
}

class _StudyErrorState extends StatelessWidget {
  const _StudyErrorState({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.cloud_off_rounded,
              color: _primaryEndColor,
              size: 36,
            ),
            const SizedBox(height: 14),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}

class _SheetHandle extends StatelessWidget {
  const _SheetHandle();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 42,
        height: 4,
        decoration: BoxDecoration(
          color: Colors.white24,
          borderRadius: BorderRadius.circular(99),
        ),
      ),
    );
  }
}

InputDecoration _sheetInputDecoration({
  required String labelText,
  required IconData prefixIcon,
}) {
  return InputDecoration(
    labelText: labelText,
    labelStyle: const TextStyle(color: Colors.white54),
    prefixIcon: Icon(prefixIcon, color: Colors.white54, size: 21),
    filled: true,
    fillColor: _surfaceColor,
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(18),
      borderSide: const BorderSide(color: Colors.white10),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(18),
      borderSide: const BorderSide(color: _primaryColor, width: 1.4),
    ),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(18),
      borderSide: BorderSide.none,
    ),
  );
}
