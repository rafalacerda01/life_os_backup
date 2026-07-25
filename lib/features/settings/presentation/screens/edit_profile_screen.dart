import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:life_os/features/auth/presentation/providers/auth_provider.dart';

class EditProfileScreen extends ConsumerStatefulWidget {
  const EditProfileScreen({super.key});

  @override
  ConsumerState<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends ConsumerState<EditProfileScreen> {
  late final TextEditingController _nameController;
  bool _isLoading = false;
  String? _selectedAvatar;

  final List<String> _avatarOptions = [
    'avatar_male',
    'avatar_female',
    'avatar_cyber',
    'avatar_neural',
  ];

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();

    final authState = ref.read(authNotifierProvider);
    authState.maybeWhen(
      authenticated: (user) {
        _nameController.text = user.displayName ?? "";
        _selectedAvatar = user.photoUrl;
      },
      orElse: () {},
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _pickImageFromGallery() async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: ImageSource.gallery);
    if (pickedFile != null) {
      setState(() {
        _selectedAvatar = pickedFile.path;
      });
    }
  }

  void _showAvatarPickerSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF11182E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "ESCOLHER FOTO DE PERFIL",
              style: TextStyle(
                color: Colors.white38,
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 20),
            ListTile(
              tileColor: Colors.transparent, // Corrige o alerta do ListTile
              leading: const Icon(Icons.face, color: Colors.purpleAccent),
              title: const Text(
                "Usar Avatar Predefinido",
                style: TextStyle(color: Colors.white),
              ),
              onTap: () {
                Navigator.pop(sheetContext);
                _showPredefinedAvatarsDialog();
              },
            ),
            ListTile(
              tileColor: Colors.transparent, // Corrige o alerta do ListTile
              leading: const Icon(
                Icons.photo_library,
                color: Colors.purpleAccent,
              ),
              title: const Text(
                "Escolher da Galeria",
                style: TextStyle(color: Colors.white),
              ),
              onTap: () {
                Navigator.pop(sheetContext);
                _pickImageFromGallery();
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showPredefinedAvatarsDialog() {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF11182E),
        title: const Text(
          "Selecione um Avatar",
          style: TextStyle(color: Colors.white),
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: GridView.builder(
            shrinkWrap: true,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              crossAxisSpacing: 16,
              mainAxisSpacing: 16,
            ),
            itemCount: _avatarOptions.length,
            itemBuilder: (context, index) {
              final avatarKey = _avatarOptions[index];
              final isSelected = _selectedAvatar == avatarKey;
              return GestureDetector(
                onTap: () {
                  setState(() => _selectedAvatar = avatarKey);
                  Navigator.pop(dialogContext);
                },
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF070B14),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: isSelected ? Colors.purpleAccent : Colors.white24,
                      width: isSelected ? 3 : 1,
                    ),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        avatarKey.contains('female')
                            ? Icons.face_3
                            : Icons.face,
                        size: 40,
                        color: isSelected
                            ? Colors.purpleAccent
                            : Colors.white70,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        avatarKey.replaceAll('avatar_', '').toUpperCase(),
                        style: TextStyle(
                          color: isSelected
                              ? Colors.purpleAccent
                              : Colors.white60,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Future<void> _saveProfile() async {
    final newName = _nameController.text.trim();
    if (newName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("O nome não pode estar vazio.")),
      );
      return;
    }

    setState(() => _isLoading = true);
    try {
      // Passa explicitamente o nome e a foto selecionada para o Notifier
      await ref
          .read(authNotifierProvider.notifier)
          .updateProfile(newName: newName, newPhotoUrl: _selectedAvatar);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Perfil atualizado com sucesso!")),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("Erro ao atualizar: $e")));
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool isLocalFile =
        _selectedAvatar != null && _selectedAvatar!.startsWith('/');

    return Scaffold(
      backgroundColor: const Color(0xFF070B14),
      appBar: AppBar(
        title: const Text(
          "Editar Perfil",
          style: TextStyle(color: Colors.white),
        ),
        backgroundColor: const Color(0xFF11182E),
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Center(
              child: Stack(
                children: [
                  CircleAvatar(
                    radius: 50,
                    backgroundColor: const Color(0xFF11182E),
                    backgroundImage: isLocalFile
                        ? FileImage(File(_selectedAvatar!)) as ImageProvider
                        : null,
                    child: !isLocalFile
                        ? Icon(
                            _selectedAvatar?.contains('female') == true
                                ? Icons.face_3
                                : Icons.face,
                            size: 50,
                            color: Colors.purpleAccent,
                          )
                        : null,
                  ),
                  Positioned(
                    bottom: 0,
                    right: 0,
                    child: Container(
                      decoration: const BoxDecoration(
                        color: Colors.purpleAccent,
                        shape: BoxShape.circle,
                      ),
                      child: IconButton(
                        icon: const Icon(
                          Icons.camera_alt,
                          size: 20,
                          color: Colors.white,
                        ),
                        onPressed: _showAvatarPickerSheet,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 35),
            TextField(
              controller: _nameController,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: "Nome de Exibição",
                labelStyle: TextStyle(color: Colors.white54),
                enabledBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: Colors.purpleAccent),
                ),
                focusedBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: Colors.purpleAccent, width: 2),
                ),
              ),
            ),
            const SizedBox(height: 40),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _isLoading ? null : _saveProfile,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.purpleAccent,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: _isLoading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2,
                        ),
                      )
                    : const Text(
                        "Salvar Alterações",
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
