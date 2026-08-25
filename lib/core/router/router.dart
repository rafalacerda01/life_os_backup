import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/features/circles/presentation/circles_screen.dart';
import 'package:life_os/features/focus/presentation/providers/screens/focus_screen.dart';
import 'package:life_os/features/auth/presentation/screens/login_screen.dart';
import 'package:life_os/features/auth/presentation/screens/register_screen.dart';
import 'package:life_os/features/auth/presentation/providers/auth_provider.dart';
import 'package:life_os/features/onboarding/presentation/splash_screen.dart';
import 'package:life_os/features/onboarding/presentation/onboarding_screen.dart';
import 'package:life_os/features/ai_companion/presentation/ai_companion_screen.dart';
import 'package:life_os/features/goals/presentation/goals_screen.dart';
import 'package:life_os/features/settings/presentation/settings_screen.dart';
import 'package:life_os/features/home/presentation/screens/home_screen.dart';
import 'package:life_os/features/home/presentation/screens/main_navigation_screen.dart';
import 'package:life_os/features/study/presentation/study_screen.dart';
import 'package:life_os/features/health/presentation/health_screen.dart';
import 'package:life_os/features/health/presentation/cycle/cycle_health_screen.dart';
import 'package:life_os/features/finance/presentation/finance_screen.dart';
import 'package:life_os/features/habits/presentation/habits_screen.dart';
import 'package:life_os/features/tasks/presentation/tasks_screen.dart';
import 'package:life_os/features/analytics/presentation/analytics_screen.dart';
import 'package:life_os/features/settings/presentation/screens/privacy_policy_screen.dart';
import 'package:life_os/features/settings/presentation/screens/contact_screen.dart';
import '../../features/notifications/presentation/screens/notification_screen.dart';
// ✅ Importação adicionada para a tela de Notificações
import 'package:life_os/features/settings/presentation/screens/notifications_screen.dart';

class AuthRefreshListenable extends ChangeNotifier {
  final Ref ref;
  AuthRefreshListenable(this.ref) {
    // Escuta mudanças no provider de autenticação
    ref.listen(authNotifierProvider, (_, _) => notifyListeners());
  }
}

final routerProvider = Provider<GoRouter>((ref) {
  // Agora usamos a classe que escuta o provider, não o stream
  final refreshListenable = AuthRefreshListenable(ref);

  return GoRouter(
    initialLocation: '/splash',
    refreshListenable: refreshListenable,
    redirect: (context, state) {
      final authState = ref.read(authNotifierProvider);

      final isFreeAccessRoute =
          state.matchedLocation == '/splash' ||
          state.matchedLocation == '/onboarding' ||
          state.matchedLocation == '/login' ||
          state.matchedLocation == '/register';

      return authState.maybeWhen(
        authenticated: (_) => isFreeAccessRoute ? '/home' : null,
        unauthenticated: () => !isFreeAccessRoute ? '/login' : null,
        orElse: () => null,
      );
    },
    routes: [
      GoRoute(
        path: '/splash',
        builder: (context, state) => const SplashScreen(),
      ),
      GoRoute(
        path: '/onboarding',
        builder: (context, state) => const OnboardingScreen(),
      ),
      GoRoute(path: '/login', builder: (context, state) => const LoginScreen()),
      GoRoute(
        path: '/register',
        builder: (context, state) => const RegisterScreen(),
      ),

      ShellRoute(
        builder: (context, state, child) {
          return MainNavigationScreen(child: child);
        },
        routes: [
          GoRoute(
            path: '/home',
            builder: (context, state) => const HomeScreen(),
          ),
          GoRoute(
            path: '/study',
            builder: (context, state) => const StudyScreen(),
          ),
          GoRoute(
            path: '/health',
            builder: (context, state) => const HealthScreen(),
          ),
          GoRoute(
            path: '/health/cycle',
            builder: (context, state) => const CycleHealthScreen(),
          ),
          GoRoute(
            path: '/finance',
            builder: (context, state) => const FinanceScreen(),
          ),
          GoRoute(
            path: '/tasks',
            builder: (context, state) => const TasksScreen(),
          ),
          GoRoute(
            path: '/ai-companion',
            builder: (context, state) => const AICompanionScreen(),
          ),
          GoRoute(
            path: '/goals',
            builder: (context, state) => const GoalsScreen(),
          ),
          GoRoute(
            path: '/settings',
            builder: (context, state) => const SettingsScreen(),
          ),
          GoRoute(
            path: '/habits',
            builder: (context, state) => const HabitsScreen(),
          ),
          // ✅ Rota de notificações adicionada
          GoRoute(
            path: '/notifications',
            builder: (context, state) => const NotificationScreen(),
          ),
          // ✅ Rota para acessar a sua tela antiga de toggles (ajustes)
          GoRoute(
            path: '/notifications_insights',
            builder: (context, state) =>
                const NotificationsScreen(), // Mantém a classe antiga aqui
          ),
          GoRoute(
            path: '/focus',
            builder: (context, state) => const FocusScreen(),
          ),
          GoRoute(
            path: '/circles',
            builder: (context, state) => const CirclesScreen(),
          ),
          GoRoute(
            path: '/analytics',
            builder: (context, state) => const AnalyticsScreen(),
          ),
          GoRoute(
            path: '/privacy-policy',
            builder: (context, state) => const PrivacyPolicyScreen(),
          ),
          GoRoute(
            path: '/contact',
            builder: (context, state) => const ContactScreen(),
          ),
        ],
      ),
    ],
  );
});
