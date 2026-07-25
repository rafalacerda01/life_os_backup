import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:life_os/core/theme/app_colors.dart'; // <-- IMPORT DO SEU TEMA
import 'package:life_os/features/circles/presentation/circles_provider.dart';

class CreateChallengeScreen extends ConsumerStatefulWidget {
  final String circleId;
  const CreateChallengeScreen({super.key, required this.circleId});

  @override
  ConsumerState<CreateChallengeScreen> createState() =>
      _CreateChallengeScreenState();
}

class _CreateChallengeScreenState extends ConsumerState<CreateChallengeScreen> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _targetXpController = TextEditingController();
  bool _isLoading = false;

  @override
  void dispose() {
    _titleController.dispose();
    _targetXpController.dispose();
    super.dispose();
  }

  Future<void> _handleCreateChallenge() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    try {
      final targetXp = int.tryParse(_targetXpController.text.trim()) ?? 0;

      // Chama o provider para criar o desafio de forma otimizada
      await ref
          .read(circlesProvider.notifier)
          .createNewChallenge(_titleController.text.trim(), targetXp);

      if (mounted) {
        Navigator.pop(context); // Volta para a tela anterior com sucesso
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Erro ao criar desafio: $e',
              style: const TextStyle(color: Colors.white),
            ),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.scaffoldBackground,
      appBar: AppBar(
        title: const Text(
          "Novo Desafio",
          style: TextStyle(
            color: AppColors.textMain,
            fontWeight: FontWeight.bold,
          ),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: AppColors.textMain),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "Motive o seu Círculo",
                style: TextStyle(
                  color: AppColors.textMain,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                "Defina uma meta coletiva de XP para todos os membros trabalharem juntos e alcançarem o objetivo.",
                style: TextStyle(color: AppColors.textHint, fontSize: 14),
              ),
              const SizedBox(height: 32),

              // --- CAMPO TÍTULO ---
              TextFormField(
                controller: _titleController,
                style: const TextStyle(color: AppColors.textMain),
                decoration: InputDecoration(
                  labelText: "Título do Desafio",
                  labelStyle: const TextStyle(color: AppColors.textHint),
                  filled: true,
                  fillColor: AppColors.cardBackground,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: const BorderSide(
                      color: AppColors.primary,
                      width: 1.5,
                    ),
                  ),
                  errorBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: const BorderSide(
                      color: Colors.redAccent,
                      width: 1,
                    ),
                  ),
                ),
                validator: (v) => v == null || v.trim().isEmpty
                    ? "Informe um título para o desafio"
                    : null,
              ),

              const SizedBox(height: 16),

              // --- CAMPO META XP ---
              TextFormField(
                controller: _targetXpController,
                style: const TextStyle(color: AppColors.textMain),
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: "Meta XP (ex: 4000)",
                  labelStyle: const TextStyle(color: AppColors.textHint),
                  filled: true,
                  fillColor: AppColors.cardBackground,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: const BorderSide(
                      color: AppColors.primary,
                      width: 1.5,
                    ),
                  ),
                  errorBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: const BorderSide(
                      color: Colors.redAccent,
                      width: 1,
                    ),
                  ),
                ),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) {
                    return "Informe a meta de XP";
                  }
                  final number = int.tryParse(v.trim());
                  if (number == null || number <= 0) {
                    return "Insira um valor numérico válido maior que zero";
                  }
                  return null;
                },
              ),

              const SizedBox(height: 40),

              // --- BOTÃO DE AÇÃO ---
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.secondary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    elevation: 0,
                  ),
                  onPressed: _isLoading ? null : _handleCreateChallenge,
                  child: _isLoading
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            color: AppColors.textMain,
                            strokeWidth: 2.5,
                          ),
                        )
                      : const Text(
                          "Criar Desafio",
                          style: TextStyle(
                            color: AppColors.textMain,
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
