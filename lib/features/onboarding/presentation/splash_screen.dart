import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:life_os/features/auth/presentation/providers/auth_provider.dart';
import 'package:life_os/features/auth/presentation/providers/auth_state.dart';
import 'package:life_os/features/onboarding/presentation/onboarding_provider.dart';

class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _rotationController;
  bool _navigationScheduled = false;
  bool _hasNavigated = false;
  bool _retrying = false;

  @override
  void initState() {
    super.initState();
    _rotationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat();
  }

  String? _resolveDestination(
    AuthState authState,
    AsyncValue<bool> onboardingState,
  ) {
    if (authState is AuthAuthenticated) return '/home';
    if (authState is! AuthUnauthenticated ||
        onboardingState is! AsyncData<bool>) {
      return null;
    }

    return onboardingState.value ? '/login' : '/onboarding';
  }

  void _scheduleNavigation(
    AuthState authState,
    AsyncValue<bool> onboardingState,
  ) {
    if (_hasNavigated || _navigationScheduled) return;
    if (_resolveDestination(authState, onboardingState) == null) return;

    _navigationScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _navigationScheduled = false;
      if (!mounted || _hasNavigated) return;

      final destination = _resolveDestination(
        ref.read(authNotifierProvider),
        ref.read(onboardingCompletionStatusProvider),
      );
      if (destination == null) return;

      _hasNavigated = true;
      context.go(destination);
    });
  }

  Future<void> _retryAuth() async {
    if (_retrying) return;
    setState(() => _retrying = true);
    try {
      await ref.read(authNotifierProvider.notifier).checkCurrentUser();
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  @override
  void dispose() {
    _rotationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authNotifierProvider);
    final onboardingState = ref.watch(onboardingCompletionStatusProvider);
    _scheduleNavigation(authState, onboardingState);

    return Scaffold(
      backgroundColor: const Color(0xFF070B14),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Título Minimalista
            RichText(
              text: const TextSpan(
                style: TextStyle(
                  fontSize: 38,
                  fontWeight: FontWeight.bold,
                  letterSpacing: -0.5,
                ),
                children: [
                  TextSpan(
                    text: "Life ",
                    style: TextStyle(color: Colors.white),
                  ),
                  TextSpan(
                    text: "OS",
                    style: TextStyle(color: Color(0xFFB026FF)),
                  ),
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
                    BoxShadow(
                      color: Color(0xFFB026FF),
                      blurRadius: 15,
                      spreadRadius: 1,
                    ),
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
            if (authState is AuthError) ...[
              const SizedBox(height: 28),
              const Text(
                "Não foi possível iniciar sua sessão.",
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70, fontSize: 14),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _retrying ? null : _retryAuth,
                child: _retrying
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text("Tentar novamente"),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
