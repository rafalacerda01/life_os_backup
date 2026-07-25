import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:life_os/core/theme/app_colors.dart'; // <-- IMPORT DO SEU TEMA
import 'package:life_os/features/circles/presentation/circles_provider.dart';

class JoinCircleScreen extends ConsumerStatefulWidget {
  const JoinCircleScreen({super.key});

  @override
  ConsumerState<JoinCircleScreen> createState() => _JoinCircleScreenState();
}

class _JoinCircleScreenState extends ConsumerState<JoinCircleScreen> {
  final _codeController = TextEditingController();
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _handleJoin() async {
    final code = _codeController.text.trim();
    if (code.isEmpty) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    // Chama o provider para tentar entrar
    final errorMessage = await ref
        .read(circlesProvider.notifier)
        .joinCircleByCode(code);

    if (mounted) {
      if (errorMessage != null) {
        setState(() {
          _isLoading = false;
          _errorMessage = errorMessage;
        });
      } else {
        // Sucesso! Volta para a tela principal (que já estará carregando o novo círculo)
        Navigator.pop(context);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.scaffoldBackground,
      appBar: AppBar(
        title: const Text(
          "Entrar em um Círculo",
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
        // Proteção contra o teclado
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "Cole o código de convite",
              style: TextStyle(
                color: AppColors.textMain,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              "Peça para um amigo copiar o código na aba de Detalhes do Círculo dele e enviar para você.",
              style: TextStyle(color: AppColors.textHint, fontSize: 14),
            ),
            const SizedBox(height: 32),

            // --- CAMPO CÓDIGO ---
            TextField(
              controller: _codeController,
              style: const TextStyle(color: AppColors.textMain),
              decoration: InputDecoration(
                labelText: "Código (Ex: q4t2iL...)",
                labelStyle: const TextStyle(color: AppColors.textHint),
                errorText: _errorMessage,
                filled: true,
                fillColor: AppColors.cardBackground,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderSide: const BorderSide(
                    color: AppColors.primary,
                    width: 1.5,
                  ),
                  borderRadius: BorderRadius.circular(16),
                ),
                errorBorder: OutlineInputBorder(
                  borderSide: const BorderSide(
                    color: Colors.redAccent,
                    width: 1,
                  ),
                  borderRadius: BorderRadius.circular(16),
                ),
                focusedErrorBorder: OutlineInputBorder(
                  borderSide: const BorderSide(
                    color: Colors.redAccent,
                    width: 1.5,
                  ),
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
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
                onPressed: _isLoading ? null : _handleJoin,
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
                        "Entrar",
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
    );
  }
}
