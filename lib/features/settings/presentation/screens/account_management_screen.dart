import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/features/auth/domain/entities/user_entity.dart';
import 'package:life_os/features/auth/presentation/providers/auth_provider.dart';
import 'package:life_os/features/settings/presentation/screens/edit_profile_screen.dart';

class AccountManagementScreen extends ConsumerWidget {
  const AccountManagementScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authNotifierProvider);

    return Scaffold(
      backgroundColor: const Color(0xFF070B14),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text("Configurações"),
      ),
      body: authState.maybeWhen(
        authenticated: (user) => ListView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          children: [
            _buildProfileCard(user),
            const SizedBox(height: 32),
            _buildSectionHeader("GERAL"),
            _buildSettingsTile(
              icon: Icons.edit_outlined,
              title: "Editar Perfil",
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const EditProfileScreen()),
              ),
            ),
            const SizedBox(height: 24),
            _buildSectionHeader("DADOS E BACKUP"),
            _buildSettingsTile(
              icon: Icons.cloud_upload_outlined,
              title: "Sincronizar Dados",
              onTap: () {},
            ),
            _buildSettingsTile(
              icon: Icons.history,
              title: "Exportar Histórico",
              onTap: () {},
            ),
            const SizedBox(height: 24),
            _buildSectionHeader("SEGURANÇA"),
            _buildSettingsTile(
              icon: Icons.logout_rounded,
              title: "Encerrar Sessão",
              textColor: Colors.redAccent,
              iconColor: Colors.redAccent,
              onTap: () => _showLogoutDialog(context, ref),
            ),
            _buildSettingsTile(
              icon: Icons.delete_forever_outlined,
              title: "Excluir Conta",
              textColor: Colors.redAccent,
              iconColor: Colors.redAccent,
              onTap: () => _showDeleteAccountDialog(context, ref),
            ),
          ],
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (message) => Center(
          child: Text(
            "Erro: $message",
            style: const TextStyle(color: Colors.red),
          ),
        ),
        orElse: () => const SizedBox.shrink(),
      ),
    );
  }

  // Widget para os headers de seção
  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 8, bottom: 12),
      child: Text(
        title,
        style: const TextStyle(
          color: Colors.white38,
          fontSize: 12,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  // Componente de Tile Padronizado
  Widget _buildSettingsTile({
    required IconData icon,
    required String title,
    required VoidCallback onTap,
    Color? textColor,
    Color? iconColor,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF11182E),
        borderRadius: BorderRadius.circular(16),
      ),
      child: ListTile(
        onTap: onTap,
        tileColor: Colors
            .transparent, // <-- Define explicitamente para evitar o aviso de transparência
        leading: Icon(icon, color: iconColor ?? Colors.white70),
        title: Text(
          title,
          style: TextStyle(
            color: textColor ?? Colors.white,
            fontWeight: FontWeight.w500,
          ),
        ),
        trailing: const Icon(Icons.chevron_right, color: Colors.white24),
      ),
    );
  }

  // Perfil Card corrigido sem parâmetros inválidos no CircleAvatar
  Widget _buildProfileCard(UserEntity user) {
    final photoUrl = user.photoUrl;
    bool hasPhoto = photoUrl != null && photoUrl.isNotEmpty;

    Widget avatarChild;
    if (!hasPhoto) {
      avatarChild = const Icon(
        Icons.person,
        size: 40,
        color: Colors.purpleAccent,
      );
    } else if (photoUrl.startsWith('http')) {
      avatarChild = Image.network(
        photoUrl,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) =>
            const Icon(Icons.person, size: 40, color: Colors.purpleAccent),
      );
    } else if (photoUrl.startsWith('/')) {
      avatarChild = Image.file(
        File(photoUrl),
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) =>
            const Icon(Icons.person, size: 40, color: Colors.purpleAccent),
      );
    } else {
      // Caso seja um avatar predefinido (ex: 'avatar_male', 'avatar_female', etc.)
      avatarChild = Icon(
        photoUrl.contains('female') ? Icons.face_3 : Icons.face,
        size: 40,
        color: Colors.purpleAccent,
      );
    }

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: const Color(0xFF11182E),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 35,
            backgroundColor: Colors.purpleAccent.withOpacity(0.2),
            child: ClipOval(
              child: SizedBox(width: 70, height: 70, child: avatarChild),
            ),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  user.displayName ?? "Usuário",
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  user.email ?? "",
                  style: const TextStyle(color: Colors.white54, fontSize: 14),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: user.isPremium
                        ? Colors.greenAccent.withOpacity(0.1)
                        : Colors.amberAccent.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    user.isPremium ? "PREMIUM" : "FREE",
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: user.isPremium
                          ? Colors.greenAccent
                          : Colors.amberAccent,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Lógica de Exclusão de Conta Segura
  void _showDeleteAccountDialog(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF11182E),
        title: const Text(
          "Excluir Conta",
          style: TextStyle(color: Colors.redAccent),
        ),
        content: const Text(
          "Esta ação é irreversível. Todos os seus dados locais e na nuvem serão permanentemente removidos. Deseja continuar?",
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text("Cancelar"),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              ref.read(authNotifierProvider.notifier).deleteAccount();
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text("Deletar Permanentemente"),
          ),
        ],
      ),
    );
  }

  // Diálogo de Logout Seguro
  void _showLogoutDialog(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF11182E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          "Encerrar Sessão",
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          "Você tem certeza que deseja sair da sua conta?",
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text(
              "Cancelar",
              style: TextStyle(color: Colors.white70),
            ),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              ref.read(authNotifierProvider.notifier).logout();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
            ),
            child: const Text("Sair"),
          ),
        ],
      ),
    );
  }
}
