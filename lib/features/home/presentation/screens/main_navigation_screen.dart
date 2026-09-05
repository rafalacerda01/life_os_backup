import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/core/theme/app_colors.dart';
import 'package:life_os/features/auth/presentation/providers/auth_provider.dart';

class MainNavigationScreen extends ConsumerWidget {
  final Widget child;

  const MainNavigationScreen({super.key, required this.child});

  // Função de logout global
  void _showLogoutConfirmation(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF11182E),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: const Row(
            children: [
              Icon(Icons.power_settings_new_rounded, color: Colors.redAccent),
              SizedBox(width: 10),
              Text(
                "Desconectar",
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          content: const Text(
            "Deseja realmente encerrar sua sessão no Life OS? Seus rituais e metas continuarão sincronizados com a nuvem.",
            style: TextStyle(color: Colors.white54, fontSize: 14, height: 1.4),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text(
                "Cancelar",
                style: TextStyle(color: Colors.white38),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent.withOpacity(0.2),
                foregroundColor: Colors.redAccent,
              ),
              onPressed: () {
                Navigator.pop(context);
                ref.read(authNotifierProvider.notifier).logout();
              },
              child: const Text(
                "Encerrar sessão",
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        );
      },
    );
  }

  int _calculateSelectedIndex(BuildContext context) {
    final String location = GoRouterState.of(context).matchedLocation;
    if (location.startsWith('/home')) return 0;
    if (location.startsWith('/study')) return 1;
    if (location.startsWith('/health')) return 2;
    if (location.startsWith('/finance')) return 3;
    if (location.startsWith('/ai-companion')) return 4;
    return 0;
  }

  void _onItemTapped(int index, BuildContext context) {
    switch (index) {
      case 0:
        context.go('/home');
        break;
      case 1:
        context.go('/study');
        break;
      case 2:
        context.go('/health');
        break;
      case 3:
        context.go('/finance');
        break;
      case 4:
        context.go('/ai-companion');
        break;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.scaffoldBackground,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        title: const Text(
          "Life OS",
          style: TextStyle(
            color: AppColors.textMain,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.4,
          ),
        ),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'Abrir menu',
            icon: Container(
              padding: const EdgeInsets.all(9),
              decoration: BoxDecoration(
                color: AppColors.cardBackground,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white.withOpacity(0.07)),
              ),
              child: const Icon(
                Icons.menu_rounded,
                color: AppColors.textMain,
                size: 20,
              ),
            ),
            color: AppColors.cardBackground,
            elevation: 12,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(color: Colors.white.withOpacity(0.07)),
            ),
            onSelected: (value) {
              if (value == 'logout') {
                _showLogoutConfirmation(context, ref);
              } else {
                context.go(value);
              }
            },
            itemBuilder: (context) => [
              // 1. FOCO
              const PopupMenuItem(
                value: '/focus',
                child: ListTile(
                  leading: Icon(Icons.timer, color: Colors.greenAccent),
                  title: Text("Foco", style: TextStyle(color: Colors.white)),
                ),
              ),
              // 2. METAS
              const PopupMenuItem(
                value: '/goals',
                child: ListTile(
                  leading: Icon(
                    Icons.track_changes,
                    color: Colors.purpleAccent,
                  ),
                  title: Text("Metas", style: TextStyle(color: Colors.white)),
                ),
              ),
              // 3. CÍRCULOS
              const PopupMenuItem(
                value: '/circles',
                child: ListTile(
                  leading: Icon(
                    Icons.groups_outlined,
                    color: Colors.blueAccent,
                  ),
                  title: Text(
                    "Círculos",
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ),
              // 4. INTELIGÊNCIA ANALÍTICA (ADICIONADO AQUI)
              const PopupMenuItem(
                value: '/analytics',
                child: ListTile(
                  leading: Icon(Icons.insights, color: Color(0xFFB026FF)),
                  title: Text(
                    "Análises",
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ),
              // 5. AJUSTES
              const PopupMenuItem(
                value: '/settings',
                child: ListTile(
                  leading: Icon(Icons.settings, color: Colors.white70),
                  title: Text("Ajustes", style: TextStyle(color: Colors.white)),
                ),
              ),
              const PopupMenuDivider(),
              // 6. SAIR
              const PopupMenuItem(
                value: 'logout',
                child: ListTile(
                  leading: Icon(Icons.logout, color: Colors.redAccent),
                  title: Text(
                    "Sair",
                    style: TextStyle(color: Colors.redAccent),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
      body: child,
      bottomNavigationBar: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFF0A0F1E),
          border: Border(
            top: BorderSide(color: AppColors.primary.withOpacity(0.16)),
          ),
          boxShadow: [
            BoxShadow(
              color: AppColors.primary.withOpacity(0.07),
              blurRadius: 20,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        child: SafeArea(
          top: false,
          child: BottomNavigationBar(
            currentIndex: _calculateSelectedIndex(context),
            onTap: (index) => _onItemTapped(index, context),
            type: BottomNavigationBarType.fixed,
            backgroundColor: Colors.transparent,
            elevation: 0,
            selectedItemColor: AppColors.primary,
            unselectedItemColor: Colors.white54,
            selectedFontSize: 11,
            unselectedFontSize: 10,
            iconSize: 23,
            showSelectedLabels: true,
            showUnselectedLabels: true,
            items: const [
              BottomNavigationBarItem(
                icon: Icon(Icons.dashboard_outlined),
                activeIcon: Icon(Icons.dashboard_rounded),
                label: 'Início',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.local_library_outlined),
                activeIcon: Icon(Icons.local_library_rounded),
                label: 'Estudos',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.favorite_border_rounded),
                activeIcon: Icon(Icons.favorite_rounded),
                label: 'Saúde',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.account_balance_wallet_outlined),
                activeIcon: Icon(Icons.account_balance_wallet_rounded),
                label: 'Finanças',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.psychology_outlined),
                activeIcon: Icon(Icons.psychology_rounded),
                label: 'IA',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
