import os

# Definição de toda a malha de diretórios (Clean Architecture - Feature First)
directories = [
    "lib/app",
    "lib/core/constants",
    "lib/core/theme",
    "lib/core/router",
    "lib/core/security",
    "lib/core/services",
    "lib/core/utils",
    "lib/core/widgets",
    "lib/core/errors",
    "lib/features/auth/domain/entities",
    "lib/features/auth/domain/repositories",
    "lib/features/auth/data/models",
    "lib/features/auth/data/repositories",
    "lib/features/auth/presentation/providers",
    "lib/features/auth/presentation/screens",
    "lib/features/onboarding/presentation",
    "lib/features/home/presentation/screens",
    "lib/features/tasks/domain/entities",
    "lib/features/tasks/presentation",
    "lib/features/focus/presentation",
    "lib/features/finance/domain/entities",
    "lib/features/finance/presentation",
    "lib/features/study/domain/entities",
    "lib/features/study/presentation",
    "lib/features/health/domain/entities",
    "lib/features/health/presentation",
    "lib/features/habits/domain/entities",
    "lib/features/habits/presentation",
    "lib/features/analytics/domain/entities",
    "lib/features/analytics/presentation",
    "lib/features/premium/domain/entities",
    "lib/features/premium/presentation",
    "lib/features/circles/domain/entities",
    "lib/features/circles/presentation",
    "lib/features/ai_companion/presentation",
    "lib/features/goals/domain/entities",
    "lib/features/goals/presentation",
    "lib/features/settings/presentation",
    "lib/features/checkin/presentation",
    "lib/features/notifications/presentation",
]

# Criação das pastas de forma recursiva
print("🚀 Inicializando infraestrutura de diretórios do Life OS...")
for folder in directories:
    os.makedirs(folder, exist_ok=True)
    print(f"🔹 Pasta criada: {folder}")

# Dicionário contendo os arquivos base e o código de produção correspondente
files_to_create = {
    "lib/main.dart": """import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/router/router.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  runApp(const ProviderScope(child: LifeOSApp()));
}

class LifeOSApp extends ConsumerWidget {
  const LifeOSApp({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: 'Life OS',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(brightness: Brightness.dark, scaffoldBackgroundColor: const Color(0xFF070B14), useMaterial3: true),
      routerConfig: router,
    );
  }
}""",

    "lib/core/errors/failure.dart": """import 'package:equatable/equatable.dart';
abstract class Failure extends Equatable {
  final String message;
  final String? code;
  const Failure(this.message, {this.code});
  @override
  List<Object?> get props => [message, code];
}
class ServerFailure extends Failure { const ServerFailure(super.message, {super.code}); }
class AuthFailure extends Failure { const AuthFailure(super.message, {super.code}); }
class SecurityFailure extends Failure { const SecurityFailure(super.message, {super.code}); }""",

    "lib/core/security/input_sanitizer.dart": """class InputSanitizer {
  static String sanitize(String input) {
    return input.replaceAll(RegExp(r'<[^>]*>'), '').trim();
  }
}""",

    "lib/core/router/router.dart": """import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/features/auth/presentation/screens/login_screen.dart';
import 'package:life_os/features/onboarding/presentation/splash_screen.dart';
import 'package:life_os/features/onboarding/presentation/onboarding_screen.dart';
import 'package:life_os/features/home/presentation/screens/home_screen.dart';

final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/splash',
    routes: [
      GoRoute(path: '/splash', builder: (context, state) => const SplashScreen()),
      GoRoute(path: '/onboarding', builder: (context, state) => const OnboardingScreen()),
      GoRoute(path: '/login', builder: (context, state) => const LoginScreen()),
      GoRoute(path: '/home', builder: (context, state) => const HomeScreen()),
    ],
  );
});"""
}

# Escrita dos arquivos estruturados na árvore do app
print("\\n📝 Injetando regras de negócio e código-fonte...")
for path, content in files_to_create.items():
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)
    print(f"✅ Arquivo gerado: {path}")

print("\\n🎯 Processo finalizado com sucesso! Seu esqueleto Clean Architecture está pronto para rodar.")