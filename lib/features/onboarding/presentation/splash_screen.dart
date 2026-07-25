import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  late AnimationController _rotationController;

  @override
  void initState() {
    super.initState();
    _rotationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat();

    _navigateToNext();
  }

  void _navigateToNext() async {
    await Future.delayed(const Duration(milliseconds: 4000));
    if (mounted) {
      context.go('/onboarding');
    }
  }

  @override
  void dispose() {
    _rotationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF070B14),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Título Minimalista
            RichText(
              text: const TextSpan(
                style: TextStyle(fontSize: 38, fontWeight: FontWeight.bold, letterSpacing: -0.5),
                children: [
                  TextSpan(text: "Life ", style: TextStyle(color: Colors.white)),
                  TextSpan(text: "OS", style: TextStyle(color: Color(0xFFB026FF))),
                ],
              ),
            ),
            const SizedBox(height: 70),

            // ANEL MINIMALISTA (TRAÇO FINO)
            RotationTransition(
              turns: _rotationController,
              child: Container(
                width: 160, // Tamanho reduzido para ser mais minimalista
                height: 160,
                // O padding define a espessura do traço (quanto menor, mais fino)
                padding: const EdgeInsets.all(10), 
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: SweepGradient(
                    colors: [
                      Color(0xFF007AFF), 
                      Color(0xFFB026FF), 
                      Color(0xFFFF2675), 
                      Color(0xFF007AFF),
                    ],
                  ),
                  // Glow suave (apenas o necessário para dar o efeito neon)
                  boxShadow: [
                    BoxShadow(color: Color(0xFFB026FF), blurRadius: 15, spreadRadius: 1),
                  ],
                ),
                child: Container(
                  decoration: const BoxDecoration(
                    color: Color(0xFF070B14), // Fundo limpo
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
            
            const SizedBox(height: 70),

            const Text(
              "Seu sistema.\nSua vida.\nSeu melhor.",
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white54,
                fontSize: 16,
                fontWeight: FontWeight.w300,
                letterSpacing: 1,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}