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

// Crie a classe de estado
class _StudyScreenState extends ConsumerState<StudyScreen> {
  @override
  void initState() {
    super.initState();
    // A sincronização acontece aqui, assim que a tela carrega
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(studyRepositoryProvider).syncStudyFromFirebaseToLocal();
    });
  }

  // 📝 Janela de Validação antes de Excluir Matéria
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
          backgroundColor: const Color(0xFF11182E),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
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
                backgroundColor: Colors.redAccent,
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

  // 📝 BottomSheet para Adicionar Nova Disciplina
  void _showAddSubjectModal(BuildContext context, WidgetRef ref) {
    final titleController = TextEditingController();
    bool hasExam = false;
    DateTime? selectedDate;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF11182E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom + 24,
                top: 24,
                left: 24,
                right: 24,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "Nova Matéria / Disciplina",
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    controller: titleController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: "Nome da Disciplina",
                      labelStyle: const TextStyle(color: Colors.white38),
                      filled: true,
                      fillColor: const Color(0xFF070B14),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Color(0xFFB026FF)),
                      ),
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
                    activeColor: const Color(0xFFB026FF),
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
                      ),
                    ),

                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFB026FF),
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
      backgroundColor: const Color(0xFF11182E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return Consumer(
          builder: (context, ref, child) {
            final subjectsAsync = ref.watch(subjectsStreamProvider);

            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom + 24,
                top: 24,
                left: 24,
                right: 24,
              ),
              child: StatefulBuilder(
                builder: (context, setModalState) {
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        "Novo Flashcard",
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 20),
                      subjectsAsync.when(
                        loading: () => const Center(
                          child: CircularProgressIndicator(
                            color: Color(0xFFB026FF),
                          ),
                        ),
                        error: (err, _) => Text(
                          "Erro ao carregar matérias: $err",
                          style: const TextStyle(color: Colors.red),
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
                              color: Colors.white10,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<String>(
                                value: selectedSubjectId,
                                hint: const Text(
                                  "Selecione a Disciplina",
                                  style: TextStyle(color: Colors.white38),
                                ),
                                dropdownColor: const Color(0xFF11182E),
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
                        decoration: const InputDecoration(
                          labelText: "Pergunta",
                          filled: true,
                          fillColor: Colors.white10,
                          labelStyle: TextStyle(color: Colors.white38),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: answerController,
                        style: const TextStyle(color: Colors.white),
                        decoration: const InputDecoration(
                          labelText: "Resposta",
                          filled: true,
                          fillColor: Colors.white10,
                          labelStyle: TextStyle(color: Colors.white38),
                        ),
                      ),
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        height: 50,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFB026FF),
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

  @override
  Widget build(BuildContext context) {
    final studyAsync = ref.watch(studyStreamProvider);
    final subjectsAsync = ref.watch(subjectsStreamProvider);

    return Scaffold(
      backgroundColor: const Color(0xFF070B14),
      body: SafeArea(
        child: studyAsync.when(
          loading: () => const Center(
            child: CircularProgressIndicator(color: Colors.purpleAccent),
          ),
          error: (err, stack) => Center(
            child: Text(
              "Erro ao carregar estudos: $err",
              style: const TextStyle(color: Colors.red),
            ),
          ),
          data: (study) {
            return subjectsAsync.when(
              loading: () => const Center(
                child: CircularProgressIndicator(color: Colors.purpleAccent),
              ),
              error: (err, stack) => Center(
                child: Text(
                  "Erro ao carregar disciplinas: $err",
                  style: const TextStyle(color: Colors.red),
                ),
              ),
              data: (subjectList) {
                // 🚀 Regra Senior: Verifica se há disciplinas ativas para gerenciar acessibilidade com inteligência de UX
                final bool hasActiveStudies = subjectList.isNotEmpty;

                return SingleChildScrollView(
                  padding: const EdgeInsets.only(
                    top: 20,
                    left: 20,
                    right: 20,
                    bottom: 100,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        "Área de Estudos",
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 26,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 20),
                      Card(
                        color: const Color(0xFF11182E),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: ListTile(
                          leading: const Icon(
                            Icons.psychology,
                            color: Colors.blueAccent,
                          ),
                          title: const Text(
                            "Iniciar Sessão de Flashcards",
                            style: TextStyle(color: Colors.white),
                          ),
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) => const RevisarScreen(),
                              ),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 20),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(24),
                          gradient: const LinearGradient(
                            colors: [Color(0xFFE65C00), Color(0xFFF9D423)],
                          ),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.local_fire_department,
                              color: Colors.white,
                              size: 48,
                            ),
                            const SizedBox(width: 16),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  "${study.streak} Dias Seguidos",
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 24,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                const Text(
                                  "Mantenha o seu foco diário ativo!",
                                  style: TextStyle(
                                    color: Colors.white70,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: const Color(0xFF11182E),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: Colors.white10),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text(
                                  "Progresso do Dia",
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                Text(
                                  "${(study.progress * 100).toInt()}%",
                                  style: const TextStyle(
                                    color: Colors.purpleAccent,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            LinearProgressIndicator(
                              value: study.progress,
                              backgroundColor: const Color(0xFF070B14),
                              valueColor: const AlwaysStoppedAnimation<Color>(
                                Colors.purpleAccent,
                              ),
                              minHeight: 10,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: const Color(0xFF11182E),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  "Fila de Revisões (Anki)",
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                Text(
                                  "${study.reviewQueue} tópicos pendentes",
                                  style: const TextStyle(
                                    color: Colors.white54,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                            CircleAvatar(
                              backgroundColor: Colors.purpleAccent.withOpacity(
                                0.1,
                              ),
                              child: Text(
                                "${study.reviewQueue}",
                                style: const TextStyle(
                                  color: Colors.purpleAccent,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 30),
                      const Text(
                        "Ações Acadêmicas",
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Card(
                        color: const Color(0xFF11182E),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: ListTile(
                          leading: const Icon(
                            Icons.add_card,
                            color: Colors.orangeAccent,
                          ),
                          title: const Text(
                            "Adicionar Novo Flashcard",
                            style: TextStyle(color: Colors.white),
                          ),
                          onTap: () => _showAddFlashcardModal(context, ref),
                        ),
                      ),
                      // 🚀 Aprimoramento de UX/UI: Botão inteligente redirecionando para a Tela de Foco
                      Card(
                        color: const Color(0xFF11182E),
                        margin: const EdgeInsets.only(bottom: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: ListTile(
                          leading: Icon(
                            Icons.menu_book,
                            color: hasActiveStudies
                                ? Colors.greenAccent
                                : Colors.white24,
                          ),
                          title: Text(
                            "Estudar Agora (Pomodoro)",
                            style: TextStyle(
                              color: hasActiveStudies
                                  ? Colors.white
                                  : Colors.white38,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          subtitle: Text(
                            hasActiveStudies
                                ? "Abrir temporizador de foco e estudos"
                                : "Adicione uma disciplina para desbloquear",
                            style: const TextStyle(
                              color: Colors.white38,
                              fontSize: 12,
                            ),
                          ),
                          trailing: Icon(
                            Icons.arrow_forward_ios,
                            color: hasActiveStudies
                                ? Colors.white24
                                : Colors.white10,
                            size: 14,
                          ),
                          onTap: hasActiveStudies
                              ? () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (context) => const FocusScreen(),
                                    ),
                                  );
                                }
                              : () {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        "Cadastre pelo menos uma disciplina para estudar!",
                                      ),
                                      backgroundColor: Colors.orangeAccent,
                                    ),
                                  );
                                },
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () async => await ref
                            .read(studyRepositoryProvider)
                            .resetDailyProgress(study),
                        icon: const Icon(
                          Icons.refresh,
                          color: Colors.white38,
                          size: 16,
                        ),
                        label: const Text(
                          "Resetar progresso diário",
                          style: TextStyle(color: Colors.white38, fontSize: 12),
                        ),
                      ),
                      const SizedBox(height: 24),
                      const Text(
                        "Minhas Disciplinas",
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (subjectList.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 16),
                          child: Text(
                            "Nenhuma matéria listada. Toque no + para criar.",
                            style: TextStyle(
                              color: Colors.white38,
                              fontSize: 13,
                            ),
                          ),
                        )
                      else
                        ListView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: subjectList.length,
                          itemBuilder: (context, index) {
                            final subject = subjectList[index];
                            return Container(
                              margin: const EdgeInsets.only(bottom: 12),
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: const Color(0xFF11182E),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: Colors.white.withOpacity(0.05),
                                ),
                              ),
                              child: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        subject.title,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 15,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                      if (subject.hasExam &&
                                          subject.examDate != null)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            top: 4,
                                          ),
                                          child: Text(
                                            "📅 Prova em: ${DateFormat('dd/MM').format(subject.examDate!)}",
                                            style: const TextStyle(
                                              color: Colors.purpleAccent,
                                              fontSize: 12,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                  IconButton(
                                    icon: const Icon(
                                      Icons.delete_outline,
                                      color: Colors.redAccent,
                                      size: 20,
                                    ),
                                    onPressed: () => _showDeleteConfirmation(
                                      context,
                                      ref,
                                      subject.id,
                                      subject.title,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                    ],
                  ),
                );
              },
            );
          },
        ),
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: const Color(0xFFB026FF),
        child: const Icon(Icons.add, color: Colors.white),
        onPressed: () => _showAddSubjectModal(context, ref),
      ),
    );
  }
}
