import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:life_os/features/auth/domain/entities/user_entity.dart';
import 'package:life_os/features/auth/presentation/providers/auth_provider.dart';
import 'package:life_os/features/settings/presentation/screens/edit_profile_screen.dart';

class AccountManagementScreen extends ConsumerWidget {
  const AccountManagementScreen({super.key});

  void _handleExportHistory(BuildContext context, UserEntity user) {
    if (!user.isPremium) {
      showDialog(
        context: context,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: const Color(0xFF11182E),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: const Row(
            children: [
              Icon(Icons.workspace_premium, color: Colors.amberAccent),
              SizedBox(width: 8),
              Text('Recurso Premium', style: TextStyle(color: Colors.white)),
            ],
          ),
          content: const Text(
            'A exportação avançada de histórico e backups em formato '
            'universal estará disponível em breve exclusivamente para '
            'assinantes Premium.',
            style: TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text(
                'Entendi',
                style: TextStyle(color: Colors.purpleAccent),
              ),
            ),
          ],
        ),
      );
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Exportação de histórico em desenvolvimento.'),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authNotifierProvider);

    return Scaffold(
      backgroundColor: const Color(0xFF070B14),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          'Configurações',
          style: TextStyle(color: Colors.white),
        ),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: authState.maybeWhen(
        authenticated: (user) => ListView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          children: [
            _buildProfileCard(user),
            const SizedBox(height: 32),
            _buildSectionHeader('GERAL'),
            _buildSettingsTile(
              icon: Icons.edit_outlined,
              title: 'Editar Perfil',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const EditProfileScreen()),
              ),
            ),
            const SizedBox(height: 24),
            _buildSectionHeader('DADOS E BACKUP'),
            _buildSettingsTile(
              icon: Icons.history,
              title: 'Exportar Histórico',
              trailingWidget: user.isPremium
                  ? const Icon(Icons.chevron_right, color: Colors.white24)
                  : const Icon(
                      Icons.lock_outline,
                      size: 18,
                      color: Colors.amberAccent,
                    ),
              onTap: () => _handleExportHistory(context, user),
            ),
            const SizedBox(height: 24),
            _buildSectionHeader('SEGURANÇA'),
            _buildSettingsTile(
              icon: Icons.logout_rounded,
              title: 'Encerrar Sessão',
              textColor: Colors.redAccent,
              iconColor: Colors.redAccent,
              onTap: () => _showLogoutDialog(context, ref),
            ),
            _buildSettingsTile(
              icon: Icons.delete_forever_outlined,
              title: 'Excluir Conta',
              textColor: Colors.redAccent,
              iconColor: Colors.redAccent,
              onTap: () => _showDeleteAccountDialog(context, ref),
            ),
          ],
        ),
        loading: () => const Center(
          child: CircularProgressIndicator(color: Colors.purpleAccent),
        ),
        error: (message) => Center(
          child: Text(
            'Erro: $message',
            style: const TextStyle(color: Colors.red),
          ),
        ),
        orElse: () => const SizedBox.shrink(),
      ),
    );
  }

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

  Widget _buildSettingsTile({
    required IconData icon,
    required String title,
    required VoidCallback onTap,
    Color? textColor,
    Color? iconColor,
    Widget? trailingWidget,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF11182E),
        borderRadius: BorderRadius.circular(16),
      ),
      child: ListTile(
        onTap: onTap,
        tileColor: Colors.transparent,
        leading: Icon(icon, color: iconColor ?? Colors.white70),
        title: Text(
          title,
          style: TextStyle(
            color: textColor ?? Colors.white,
            fontWeight: FontWeight.w500,
          ),
        ),
        trailing:
            trailingWidget ??
            const Icon(Icons.chevron_right, color: Colors.white24),
      ),
    );
  }

  Widget _buildProfileCard(UserEntity user) {
    final photoUrl = user.photoUrl;
    final hasPhoto = photoUrl != null && photoUrl.isNotEmpty;

    final Widget avatarChild;
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
        errorBuilder: (_, _, _) =>
            const Icon(Icons.person, size: 40, color: Colors.purpleAccent),
      );
    } else if (photoUrl.startsWith('/')) {
      avatarChild = Image.file(
        File(photoUrl),
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) =>
            const Icon(Icons.person, size: 40, color: Colors.purpleAccent),
      );
    } else {
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
                  user.displayName ?? 'Usuario',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  user.email ?? '',
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
                    user.isPremium ? 'PREMIUM' : 'GRATUITO',
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

  Future<void> _showDeleteAccountDialog(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final currentUser = FirebaseAuth.instance.currentUser;
    final usesPasswordProvider =
        currentUser?.providerData.any((p) => p.providerId == 'password') ??
        false;
    final result = await showDialog<_DeleteAccountDialogResult>(
      context: context,
      builder: (_) =>
          _DeleteAccountDialog(usesPasswordProvider: usesPasswordProvider),
    );

    if (result == null) return;
    ref
        .read(authNotifierProvider.notifier)
        .deleteAccount(password: result.password);
  }

  void _showLogoutDialog(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF11182E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Encerrar Sessão',
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          'Você tem certeza que deseja sair da sua conta?',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text(
              'Cancelar',
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
            child: const Text('Sair'),
          ),
        ],
      ),
    );
  }
}

class _DeleteAccountDialogResult {
  final String? password;

  const _DeleteAccountDialogResult({required this.password});
}

class _DeleteAccountDialog extends StatefulWidget {
  final bool usesPasswordProvider;

  const _DeleteAccountDialog({required this.usesPasswordProvider});

  @override
  State<_DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<_DeleteAccountDialog> {
  late final TextEditingController _passwordController;
  bool _obscureText = true;

  @override
  void initState() {
    super.initState();
    _passwordController = TextEditingController();
  }

  @override
  void dispose() {
    FocusManager.instance.primaryFocus?.unfocus();
    _passwordController.dispose();
    super.dispose();
  }

  void _cancel() {
    FocusScope.of(context).unfocus();
    Navigator.pop(context);
  }

  void _confirm() {
    final password = _passwordController.text.trim();
    if (widget.usesPasswordProvider && password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('A senha e obrigatoria para excluir a conta.'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    FocusScope.of(context).unfocus();
    Navigator.pop(
      context,
      _DeleteAccountDialogResult(
        password: widget.usesPasswordProvider ? password : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF11182E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text(
        'Excluir Conta',
        style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Esta acao e irreversivel. Todos os seus dados locais e na nuvem serao permanentemente removidos.',
            style: TextStyle(color: Colors.white70),
          ),
          if (widget.usesPasswordProvider) ...[
            const SizedBox(height: 20),
            const Text(
              'Para sua seguranca, digite sua senha:',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _passwordController,
              obscureText: _obscureText,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Sua senha',
                hintStyle: const TextStyle(color: Colors.white38),
                filled: true,
                fillColor: Colors.black26,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscureText ? Icons.visibility_off : Icons.visibility,
                    color: Colors.white54,
                  ),
                  onPressed: () {
                    setState(() {
                      _obscureText = !_obscureText;
                    });
                  },
                ),
              ),
            ),
          ] else ...[
            const SizedBox(height: 20),
            const Text(
              'Sua conta sera confirmada novamente pelo provedor Google antes da exclusao.',
              style: TextStyle(color: Colors.white70),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _cancel,
          child: const Text(
            'Cancelar',
            style: TextStyle(color: Colors.white70),
          ),
        ),
        ElevatedButton(
          onPressed: _confirm,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.redAccent,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          child: const Text('Deletar Permanentemente'),
        ),
      ],
    );
  }
}
