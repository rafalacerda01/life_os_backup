import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';

// 🔑 IMPORTS
import 'package:life_os/features/health/data/models/health_model.dart';
import 'package:life_os/features/health/presentation/providers/health_provider.dart';
import 'package:life_os/core/security/input_sanitizer.dart';
import 'package:life_os/features/checkin/presentation/checkin_screen.dart'; // Import da tela de check-in profunda

class HealthScreen extends ConsumerWidget {
  const HealthScreen({super.key});

  // 1. Modal para adicionar medicamento
  void _showAddMedicationModal(BuildContext context, WidgetRef ref) {
    final nameController = TextEditingController();
    final durationController = TextEditingController();
    DateTime startDate = DateTime.now();

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setModal) => AlertDialog(
          backgroundColor: const Color(0xFF11182E),
          title: const Text(
            "Adicionar Medicamento",
            style: TextStyle(color: Colors.white),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: "Nome",
                  labelStyle: TextStyle(color: Colors.white54),
                ),
              ),
              TextField(
                controller: durationController,
                keyboardType: TextInputType.number,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: "Duração (dias, opcional)",
                  labelStyle: TextStyle(color: Colors.white54),
                ),
              ),
              const SizedBox(height: 10),
              TextButton(
                onPressed: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: startDate,
                    firstDate: DateTime(2025),
                    lastDate: DateTime(2030),
                  );
                  if (picked != null) setModal(() => startDate = picked);
                },
                child: Text(
                  "Início: ${DateFormat('dd/MM/yyyy').format(startDate)}",
                  style: const TextStyle(color: Colors.greenAccent),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text(
                "Cancelar",
                style: TextStyle(color: Colors.white54),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.greenAccent,
              ),
              onPressed: () async {
                final cleanName = InputSanitizer.sanitize(nameController.text);
                final duration = int.tryParse(durationController.text);

                if (cleanName.isEmpty) return;

                Navigator.pop(context);

                try {
                  await ref
                      .read(healthRepositoryProvider)
                      .addMedication(cleanName, startDate, duration);
                } catch (e) {
                  debugPrint("Erro ao salvar medicamento: $e");
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text("Erro ao salvar (pendente): $e"),
                        backgroundColor: Colors.red,
                      ),
                    );
                  }
                }
              },
              child: const Text(
                "Salvar",
                style: TextStyle(color: Colors.black),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 2. Modal de Confirmação de Exclusão
  void _showDeleteConfirmation(
    BuildContext context,
    WidgetRef ref,
    String docId,
    int localId,
  ) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF11182E),
        title: const Text(
          "Excluir Medicamento?",
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          "Tem certeza que deseja remover este medicamento da sua lista?",
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              "Cancelar",
              style: TextStyle(color: Colors.white54),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () async {
              await ref
                  .read(healthRepositoryProvider)
                  .deleteMedication(docId, localId);
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text("Excluir", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final healthAsync = ref.watch(healthStreamProvider);

    final moods = [
      {'label': 'Radiante', 'emoji': '🤩'},
      {'label': 'Focado', 'emoji': '🧠'},
      {'label': 'Neutro', 'emoji': '😐'},
      {'label': 'Cansado', 'emoji': '😴'},
      {'label': 'Estressado', 'emoji': '🤯'},
    ];

    return Scaffold(
      backgroundColor: const Color(0xFF070B14),
      body: SafeArea(
        child: healthAsync.when(
          loading: () => const Center(
            child: CircularProgressIndicator(color: Colors.greenAccent),
          ),
          error: (err, stack) => Center(
            child: Text(
              "Erro na saúde: $err",
              style: const TextStyle(color: Colors.red),
            ),
          ),
          data: (health) {
            double waterProgress = (health.waterIntakeMl / 3000).clamp(
              0.0,
              1.0,
            );

            return SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        "Bio-Monitoramento & Saúde",
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      IconButton(
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => const CheckInScreen(),
                            ),
                          );
                        },
                        icon: const Icon(
                          Icons.tune_rounded,
                          color: Colors.greenAccent,
                        ),
                        tooltip: "Check-in Profundo de Estado",
                      ),
                    ],
                  ),
                  const SizedBox(height: 25),

                  // ================= SELETOR DE HUMOR (INTEGRADO AO AI COMPANION E HOME) =================
                  const Text(
                    "Como está o seu estado mental hoje?",
                    style: TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      vertical: 16,
                      horizontal: 12,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF11182E),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: moods.map((m) {
                        bool isSelected = health.mood == m['label'];
                        return GestureDetector(
                          onTap: () async => await ref
                              .read(healthRepositoryProvider)
                              .updateMood(m['label']!),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? Colors.greenAccent.withOpacity(0.15)
                                  : Colors.transparent,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: isSelected
                                    ? Colors.greenAccent
                                    : Colors.transparent,
                                width: 1.5,
                              ),
                            ),
                            child: Text(
                              m['emoji']!,
                              style: const TextStyle(fontSize: 28),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),

                  if (health.mood != '—') ...[
                    const SizedBox(height: 8),
                    Center(
                      child: Text(
                        "Humor selecionado: ${health.mood}",
                        style: const TextStyle(
                          color: Colors.greenAccent,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],

                  // 🩸 CICLO MENSTRUAL
                  _MenstrualCycleWidget(health: health),

                  const SizedBox(height: 25),

                  // ================= CONSUMO DE ÁGUA =================
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: const Color(0xFF11182E),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Colors.white10),
                    ),
                    child: Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Row(
                              children: [
                                Icon(
                                  Icons.water_drop,
                                  color: Colors.blueAccent,
                                ),
                                SizedBox(width: 8),
                                Text(
                                  "Hidratação Diária",
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                            Text(
                              "${health.waterIntakeMl}ml / 3000ml",
                              style: const TextStyle(
                                color: Colors.blueAccent,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: LinearProgressIndicator(
                            value: waterProgress,
                            backgroundColor: const Color(0xFF070B14),
                            valueColor: const AlwaysStoppedAnimation<Color>(
                              Colors.blueAccent,
                            ),
                            minHeight: 12,
                          ),
                        ),
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          height: 45,
                          child: OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              side: const BorderSide(color: Colors.blueAccent),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            onPressed: () async => await ref
                                .read(healthRepositoryProvider)
                                .addWater(health.waterIntakeMl),
                            icon: const Icon(
                              Icons.add,
                              color: Colors.blueAccent,
                              size: 18,
                            ),
                            label: const Text(
                              "Registrar +250ml",
                              style: TextStyle(
                                color: Colors.blueAccent,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 25),

                  // ================= MEDICAMENTOS ATIVOS =================
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: const Color(0xFF11182E),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              "Medicamentos Ativos",
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            IconButton(
                              icon: const Icon(
                                Icons.add_circle,
                                color: Colors.greenAccent,
                              ),
                              onPressed: () =>
                                  _showAddMedicationModal(context, ref),
                            ),
                          ],
                        ),
                        ref
                            .watch(medicationsStreamProvider)
                            .when(
                              loading: () => const Center(
                                child: CircularProgressIndicator(
                                  color: Colors.greenAccent,
                                  strokeWidth: 2,
                                ),
                              ),
                              error: (err, stack) => Text(
                                "Erro ao carregar: $err",
                                style: const TextStyle(color: Colors.red),
                              ),
                              data: (medications) {
                                if (medications.isEmpty) {
                                  return const Text(
                                    "Nenhum medicamento.",
                                    style: TextStyle(
                                      color: Colors.white54,
                                      fontSize: 12,
                                    ),
                                  );
                                }

                                return ListView.builder(
                                  shrinkWrap: true,
                                  physics: const NeverScrollableScrollPhysics(),
                                  itemCount: medications.length,
                                  itemBuilder: (context, index) {
                                    final med = medications[index];

                                    return ListTile(
                                      contentPadding: EdgeInsets.zero,
                                      title: Text(
                                        med.name,
                                        style: const TextStyle(
                                          color: Colors.white,
                                        ),
                                      ),
                                      subtitle: Text(
                                        "Fim: ${med.endDate != null ? DateFormat('dd/MM/yyyy').format(med.endDate!) : 'Sem data'}",
                                        style: const TextStyle(
                                          color: Colors.white54,
                                          fontSize: 11,
                                        ),
                                      ),
                                      trailing: IconButton(
                                        icon: const Icon(
                                          Icons.delete,
                                          color: Colors.redAccent,
                                          size: 18,
                                        ),
                                        onPressed: () =>
                                            _showDeleteConfirmation(
                                              context,
                                              ref,
                                              med.firestoreId ?? '',
                                              med.id,
                                            ),
                                      ),
                                    );
                                  },
                                );
                              },
                            ),
                      ],
                    ),
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

// 🩸 ================= WIDGET COMPONENTE: MATRIZ DE CICLO MENSTRUAL =================
class _MenstrualCycleWidget extends ConsumerWidget {
  final HealthModel health;
  const _MenstrualCycleWidget({required this.health});

  Widget _buildWeekTracker() {
    final now = DateTime.now();
    final monday = now.subtract(Duration(days: now.weekday - 1));
    final dayNames = ['Seg', 'Ter', 'Qua', 'Qui', 'Sex', 'Sáb', 'Dom'];

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: List.generate(7, (index) {
        final date = monday.add(Duration(days: index));
        final isToday =
            date.day == now.day &&
            date.month == now.month &&
            date.year == now.year;

        return Column(
          children: [
            Text(
              dayNames[index],
              style: TextStyle(
                fontSize: 10,
                color: isToday ? Colors.pinkAccent : Colors.white38,
                fontWeight: isToday ? FontWeight.bold : FontWeight.normal,
              ),
            ),
            const SizedBox(height: 6),
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isToday
                    ? Colors.pinkAccent.withOpacity(0.2)
                    : Colors.transparent,
                border: Border.all(
                  color: isToday ? Colors.pinkAccent : Colors.white10,
                  width: isToday ? 2 : 1,
                ),
              ),
              child: Center(
                child: Text(
                  "${date.day}",
                  style: TextStyle(
                    fontSize: 10,
                    color: isToday ? Colors.white : Colors.white38,
                    fontWeight: isToday ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
              ),
            ),
          ],
        );
      }),
    );
  }

  void _showCycleSettings(
    BuildContext context,
    WidgetRef ref,
    String uid,
    Map<String, dynamic>? currentData,
  ) {
    final String initialDateStr =
        currentData?['lastPeriodStart'] ?? DateTime.now().toIso8601String();
    DateTime tempDate = DateTime.parse(initialDateStr);

    final TextEditingController cycleController = TextEditingController(
      text: (currentData?['cycleLengthDays'] ?? 28).toString(),
    );
    final TextEditingController periodController = TextEditingController(
      text: (currentData?['periodLengthDays'] ?? 5).toString(),
    );

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final formattedDate = DateFormat('dd/MM/yyyy').format(tempDate);
            return AlertDialog(
              backgroundColor: const Color(0xFF11182E),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
              title: const Row(
                children: [
                  Icon(Icons.tune_rounded, color: Colors.pinkAccent),
                  SizedBox(width: 10),
                  Text(
                    "Calibrar Matriz",
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Início do último ciclo:",
                      style: TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                    const SizedBox(height: 8),
                    InkWell(
                      onTap: () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: tempDate,
                          firstDate: DateTime(2025),
                          lastDate: DateTime.now(),
                        );
                        if (picked != null)
                          setDialogState(() => tempDate = picked);
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          vertical: 12,
                          horizontal: 16,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF070B14),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              formattedDate,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const Icon(
                              Icons.calendar_today_rounded,
                              color: Colors.pinkAccent,
                              size: 16,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                "Duração Ciclo (Dias):",
                                style: TextStyle(
                                  color: Colors.white54,
                                  fontSize: 11,
                                ),
                              ),
                              TextField(
                                controller: cycleController,
                                keyboardType: TextInputType.number,
                                style: const TextStyle(color: Colors.white),
                                decoration: const InputDecoration(
                                  filled: true,
                                  fillColor: Color(0xFF070B14),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                "Menstruação (Dias):",
                                style: TextStyle(
                                  color: Colors.white54,
                                  fontSize: 11,
                                ),
                              ),
                              TextField(
                                controller: periodController,
                                keyboardType: TextInputType.number,
                                style: const TextStyle(color: Colors.white),
                                decoration: const InputDecoration(
                                  filled: true,
                                  fillColor: Color(0xFF070B14),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text("Cancelar"),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.pinkAccent,
                  ),
                  onPressed: () async {
                    final newCycleData = {
                      'isEnabled': true,
                      'lastPeriodStart': tempDate.toIso8601String(),
                      'cycleLengthDays':
                          int.tryParse(cycleController.text) ?? 28,
                      'periodLengthDays':
                          int.tryParse(periodController.text) ?? 5,
                    };

                    try {
                      await ref
                          .read(healthRepositoryProvider)
                          .updateCycleSettings(newCycleData);
                      if (context.mounted) Navigator.pop(context);
                    } catch (e) {
                      debugPrint("Erro ao salvar ciclo: $e");
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text("Erro ao salvar: $e"),
                            backgroundColor: Colors.red,
                          ),
                        );
                      }
                    }
                  },
                  child: const Text("Salvar"),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return const SizedBox.shrink();

    final cycleData = health.menstrualCycle;
    final isEnabled = cycleData != null && (cycleData['isEnabled'] == true);

    if (!isEnabled) {
      return Container(
        margin: const EdgeInsets.only(top: 25),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF11182E),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.pinkAccent.withOpacity(0.05)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Row(
              children: [
                Icon(
                  Icons.bubble_chart_rounded,
                  color: Colors.pinkAccent,
                  size: 22,
                ),
                SizedBox(width: 12),
                Text(
                  "Ativar Ciclo Menstrual",
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
            TextButton.icon(
              onPressed: () => ref
                  .read(healthRepositoryProvider)
                  .toggleMenstrualCycleFeature(true),
              style: TextButton.styleFrom(
                foregroundColor: Colors.pinkAccent,
                backgroundColor: Colors.pinkAccent.withOpacity(0.08),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              icon: const Icon(Icons.add, size: 16),
              label: const Text(
                "Ativar",
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
              ),
            ),
          ],
        ),
      );
    }

    final cycleInfo = health.cyclePhaseInfo;
    final int currentDay = cycleInfo['day'];
    final int totalDays = cycleInfo['totalDays'];
    final String phaseName = cycleInfo['name'];
    final String aiMessage = cycleInfo['message'];
    final Color phaseColor = cycleInfo['color'];

    return Container(
      margin: const EdgeInsets.only(top: 25),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF11182E),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: phaseColor.withOpacity(0.15), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.calendar_month_rounded,
                    color: phaseColor,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    "Bio-Cycle Matrix",
                    style: TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ],
              ),
              Row(
                children: [
                  IconButton(
                    icon: const Icon(
                      Icons.settings_rounded,
                      color: Colors.white54,
                      size: 18,
                    ),
                    onPressed: () =>
                        _showCycleSettings(context, ref, user.uid, cycleData),
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.disabled_by_default_rounded,
                      color: Colors.white24,
                      size: 18,
                    ),
                    onPressed: () => ref
                        .read(healthRepositoryProvider)
                        .toggleMenstrualCycleFeature(false),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          _buildWeekTracker(),
          const SizedBox(height: 18),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "Dia $currentDay de $totalDays",
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    phaseName,
                    style: TextStyle(
                      color: phaseColor,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              InkWell(
                onTap: () => ref
                    .read(healthRepositoryProvider)
                    .updatePillStatus(!health.hasTakenPillToday),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: health.hasTakenPillToday
                        ? Colors.pinkAccent.withOpacity(0.1)
                        : const Color(0xFF070B14),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: health.hasTakenPillToday
                          ? Colors.pinkAccent
                          : Colors.white10,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        health.hasTakenPillToday
                            ? Icons.check_circle_rounded
                            : Icons.medication_liquid_sharp,
                        color: health.hasTakenPillToday
                            ? Colors.pinkAccent
                            : Colors.white38,
                        size: 18,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        health.hasTakenPillToday ? "Pílula Ok" : "Tomar Pílula",
                        style: TextStyle(
                          color: health.hasTakenPillToday
                              ? Colors.pinkAccent
                              : Colors.white54,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF070B14),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.purpleAccent.withOpacity(0.08)),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.auto_awesome,
                  color: Colors.purpleAccent,
                  size: 16,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    aiMessage,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                      height: 1.4,
                      fontStyle: FontStyle.italic,
                    ),
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
