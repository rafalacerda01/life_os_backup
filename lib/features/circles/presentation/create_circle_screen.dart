import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:life_os/core/theme/app_colors.dart'; // <-- IMPORT DO SEU TEMA
import 'package:life_os/features/circles/data/repositories/circles_repository.dart';
import 'package:life_os/features/circles/presentation/circle_detail_screen.dart';
import 'package:life_os/features/circles/presentation/circles_provider.dart';

class CreateCircleScreen extends ConsumerStatefulWidget {
  const CreateCircleScreen({super.key});

  @override
  ConsumerState<CreateCircleScreen> createState() => _CreateCircleScreenState();
}

class _CreateCircleScreenState extends ConsumerState<CreateCircleScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _descController = TextEditingController();
  bool _isLoading = false;

  Future<void> _createCircle() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    try {
      // 1. Cria o círculo no Firebase
      final circleId = await ref
          .read(circlesRepositoryProvider)
          .createCircle(_nameController.text, _descController.text);

      if (!mounted) return;

      // 2. Avisa o provider para começar a ouvir esse novo círculo
      await ref.read(circlesProvider.notifier).joinCircle(circleId);

      if (!mounted) return;

      // 3. Navega para a tela de detalhes substituindo a atual na pilha
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => CircleDetailScreen(circleId: circleId),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Erro ao criar círculo: $e',
            style: const TextStyle(color: Colors.white),
          ),
          backgroundColor: Colors.redAccent,
        ),
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.scaffoldBackground,
      appBar: AppBar(
        title: const Text(
          "Criar Novo Círculo",
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
        // Proteção contra o teclado cobrindo os campos
        padding: const EdgeInsets.all(24.0),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "Dê vida à sua comunidade",
                style: TextStyle(
                  color: AppColors.textMain,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                "Crie um espaço para evoluir junto com seus amigos, estabelecer metas e competir de forma saudável.",
                style: TextStyle(color: AppColors.textHint, fontSize: 14),
              ),
              const SizedBox(height: 32),

              // --- CAMPO NOME ---
              TextFormField(
                controller: _nameController,
                style: const TextStyle(color: AppColors.textMain),
                decoration: InputDecoration(
                  labelText: "Nome do Círculo",
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
                validator: (v) =>
                    v!.isEmpty ? "O nome não pode estar vazio" : null,
              ),

              const SizedBox(height: 16),

              // --- CAMPO DESCRIÇÃO ---
              TextFormField(
                controller: _descController,
                style: const TextStyle(color: AppColors.textMain),
                decoration: InputDecoration(
                  labelText: "Propósito (Descrição)",
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
                maxLines: 3,
                validator: (v) =>
                    v!.isEmpty ? "Adicione uma breve descrição" : null,
              ),

              const SizedBox(height: 40),

              // --- BOTÃO DE AÇÃO ---
              SizedBox(
                width: double.infinity, // Estica o botão para a largura total
                height: 56, // Altura confortável para o toque
                child: _isLoading
                    ? const Center(
                        child: CircularProgressIndicator(
                          color: AppColors.primary,
                        ),
                      )
                    : ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.secondary,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          elevation: 0,
                        ),
                        onPressed: _createCircle,
                        child: const Text(
                          "Criar Círculo",
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
