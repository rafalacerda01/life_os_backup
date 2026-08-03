import 'package:flutter/material.dart';
import 'package:life_os/features/settings/presentation/screens/account_management_screen.dart';
import 'package:life_os/features/settings/presentation/screens/security_privacy_screen.dart';
import 'package:life_os/features/settings/presentation/screens/subscription_screen.dart';
import 'package:life_os/features/settings/presentation/screens/notifications_screen.dart';
import 'package:life_os/features/settings/presentation/screens/appearance_screen.dart';
import 'package:life_os/features/settings/presentation/screens/privacy_policy_screen.dart';
// 🚀 Import da nova tela de Contato e Reportes
import 'package:life_os/features/settings/presentation/screens/contact_screen.dart';
import 'package:life_os/features/premium/presentation/premium_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF070B14),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          "Painel Operacional",
          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // 1. Gerenciamento da Conta
          _buildSettingsTile(
            Icons.person_outline,
            "Gerenciamento da Conta",
            "Configurações de perfil e dados",
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => const AccountManagementScreen(),
              ),
            ),
          ),

          // 2. Segurança & Privacidade
          _buildSettingsTile(
            Icons.security,
            "Segurança & Privacidade",
            "Isolamento e chaves de acesso",
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => const SecurityPrivacyScreen(),
              ),
            ),
          ),

          // 3. Assinatura (Gerenciamento)
          _buildSettingsTile(
            Icons.credit_card,
            "Minha Assinatura",
            "Status do seu plano",
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => const SubscriptionScreen(),
              ),
            ),
          ),

          // 4. Planos Premium e Valores (A Loja)
          _buildSettingsTile(
            Icons.workspace_premium_outlined,
            "Planos Premium e Valores",
            "Conheça as vantagens e assine",
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => const PremiumScreen()),
            ),
          ),

          // 5. Notificações
          _buildSettingsTile(
            Icons.notifications_none,
            "Notificações Inteligentes",
            "Alertas e revisões do Anki",
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => const NotificationsScreen(),
              ),
            ),
          ),

          // 6. Aparência
          _buildSettingsTile(
            Icons.palette_outlined,
            "Aparência (Interface)",
            "Tema escuro neon premium",
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const AppearanceScreen(),
                ),
              );
            },
          ),

          // 7. Política de Privacidade
          _buildSettingsTile(
            Icons.privacy_tip_outlined,
            "Política de Privacidade",
            "Termos, diretrizes e tratamento de dados",
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const PrivacyPolicyScreen(),
                ),
              );
            },
          ),

          // 8. NOVO: Suporte e Contato
          _buildSettingsTile(
            Icons.support_agent_rounded,
            "Suporte & Reporte de Bugs",
            "Fale conosco via e-mail oficial",
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const ContactScreen()),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildSettingsTile(
    IconData icon,
    String title,
    String subtitle, {
    VoidCallback? onTap,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF11182E),
        borderRadius: BorderRadius.circular(16),
      ),
      child: ListTile(
        onTap: onTap,
        leading: Icon(icon, color: const Color(0xFFB026FF)),
        title: Text(
          title,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 15,
          ),
        ),
        subtitle: Text(
          subtitle,
          style: const TextStyle(color: Colors.white38, fontSize: 12),
        ),
        trailing: const Icon(Icons.chevron_right, color: Colors.white38),
      ),
    );
  }
}
