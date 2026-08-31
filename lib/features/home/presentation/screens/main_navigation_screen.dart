import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
        backgroundColor: const Color(0xFF070B14),
        elevation: 0,
        title: const Text(
          "Life OS",
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.menu, color: Colors.white),
            color: const Color(0xFF11182E),
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
      bottomNavigationBar: Theme(
        data: Theme.of(context).copyWith(canvasColor: const Color(0xFF11182E)),
        child: BottomNavigationBar(
          currentIndex: _calculateSelectedIndex(context),
          onTap: (index) => _onItemTapped(index, context),
          type: BottomNavigationBarType.fixed,
          backgroundColor: const Color(0xFF11182E),
          selectedItemColor: Colors.purpleAccent,
          unselectedItemColor: Colors.white54,
          showSelectedLabels: true,
          showUnselectedLabels: false,
          items: const [
            BottomNavigationBarItem(
              icon: Icon(Icons.dashboard_outlined),
              activeIcon: Icon(Icons.dashboard),
              label: 'Início',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.local_library_outlined),
              activeIcon: Icon(Icons.local_library),
              label: 'Estudos',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.favorite_border),
              activeIcon: Icon(Icons.favorite),
              label: 'Saúde',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.account_balance_wallet_outlined),
              activeIcon: Icon(Icons.account_balance_wallet),
              label: 'Finanças',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.psychology_outlined),
              activeIcon: Icon(Icons.psychology),
              label: 'IA',
            ),
          ],
        ),
      ),
    );
  }
}
