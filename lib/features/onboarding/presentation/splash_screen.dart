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
  late AnimationController _introController;
  late Animation<double> _introOpacity;
  late Animation<double> _introScale;
  bool _navigationScheduled = false;
  bool _hasNavigated = false;
  bool _retrying = false;

  @override
  void initState() {
    super.initState();
    _introController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 650),
    );
    _introOpacity = _introController.drive(
      CurveTween(curve: Curves.easeOutCubic),
    );
    _introScale = Tween<double>(begin: 0.96, end: 1).animate(_introOpacity);
    _introController.forward();
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
    _introController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authNotifierProvider);
    final onboardingState = ref.watch(onboardingCompletionStatusProvider);
    _scheduleNavigation(authState, onboardingState);

    return Scaffold(
      backgroundColor: const Color(0xFF050416),
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0, -0.2),
            radius: 0.9,
            colors: [Color(0xFF130B27), Color(0xFF050416)],
          ),
        ),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minWidth: constraints.maxWidth,
                  minHeight: constraints.maxHeight,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      FadeTransition(
                        opacity: _introOpacity,
                        child: ScaleTransition(
                          scale: _introScale,
                          child: SizedBox(
                            width: 192,
                            height: 192,
                            child: Image.asset(
                              'assets/branding/life_os_mark.png',
                              fit: BoxFit.contain,
                              semanticLabel: 'Life OS',
                              filterQuality: FilterQuality.high,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 28),
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
                      const SizedBox(height: 24),

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
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Text("Tentar novamente"),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
