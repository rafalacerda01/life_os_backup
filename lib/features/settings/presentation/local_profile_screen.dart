import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/features/settings/data/local_profile_settings.dart';

class LocalProfileScreen extends ConsumerStatefulWidget {
  const LocalProfileScreen({super.key});

  @override
  ConsumerState<LocalProfileScreen> createState() => _LocalProfileScreenState();
}

class _LocalProfileScreenState extends ConsumerState<LocalProfileScreen> {
  bool _saving = false;

  Future<void> _update(Future<bool> Function() action) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      if (!await action() && mounted) {
        _notify('O bloqueio do Android não foi confirmado.');
      }
    } catch (_) {
      if (mounted) _notify('Não foi possível salvar a alteração.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _notify(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _editName(String currentName) async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => _NameDialog(currentName: currentName),
    );
    if (!mounted || name == null) return;
    await _update(
      () => ref.read(localProfileSettingsProvider.notifier).setName(name),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Perfil e ajustes')),
    body: ref
        .watch(localProfileSettingsProvider)
        .when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, _) => Center(
            child: TextButton(
              onPressed: () => ref.invalidate(localProfileSettingsProvider),
              child: const Text('Tentar novamente'),
            ),
          ),
          data: (settings) => ListView(
            padding: const EdgeInsets.symmetric(vertical: 12),
            children: [
              ListTile(
                leading: const Icon(Icons.person_outline_rounded),
                title: const Text('Nome de exibição'),
                subtitle: Text(
                  settings.displayName.isEmpty
                      ? 'Perfil local'
                      : settings.displayName,
                ),
                enabled: !_saving,
                onTap: () => _editName(settings.displayName),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.lock_outline_rounded),
                title: const Text('Bloqueio do dispositivo'),
                subtitle: const Text(
                  'Use a biometria ou o PIN do Android para abrir o Life OS.',
                ),
                value: settings.requireDeviceUnlock,
                onChanged: _saving
                    ? null
                    : (enabled) => _update(
                        () => ref
                            .read(localProfileSettingsProvider.notifier)
                            .setDeviceLock(enabled),
                      ),
              ),
            ],
          ),
        ),
  );
}

class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.currentName});
  final String currentName;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  final _form = GlobalKey<FormState>();
  String _name = '';

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Nome de exibição'),
    content: Form(
      key: _form,
      child: TextFormField(
        initialValue: widget.currentName,
        key: const Key('local-profile-name'),
        decoration: const InputDecoration(labelText: 'Nome'),
        maxLength: 60,
        textCapitalization: TextCapitalization.words,
        validator: (value) =>
            LocalProfileSettingsStore.validDisplayName(value?.trim() ?? '')
            ? null
            : 'O nome contém caracteres inválidos.',
        onSaved: (value) => _name = value?.trim() ?? '',
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancelar'),
      ),
      FilledButton(
        onPressed: () {
          if (!_form.currentState!.validate()) return;
          _form.currentState!.save();
          Navigator.of(context).pop(_name);
        },
        child: const Text('Salvar'),
      ),
    ],
  );
}

/// Owns access to every route in the local Navigator, including dialogs.
class LocalProfileAppLock extends ConsumerStatefulWidget {
  const LocalProfileAppLock({required this.child, super.key});
  final Widget child;

  @override
  ConsumerState<LocalProfileAppLock> createState() =>
      _LocalProfileAppLockState();
}

class _LocalProfileAppLockState extends ConsumerState<LocalProfileAppLock>
    with WidgetsBindingObserver {
  bool _requesting = false;
  bool _denied = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if ((state == AppLifecycleState.hidden ||
            state == AppLifecycleState.paused) &&
        ref.read(localProfileUnlockedProvider)) {
      ref.read(localProfileUnlockedProvider.notifier).lock();
    }
  }

  Future<void> _unlock() async {
    if (_requesting) return;
    setState(() => _requesting = true);
    final result = await ref
        .read(localProfileUnlockedProvider.notifier)
        .confirm('Confirme o bloqueio do dispositivo para abrir o Life OS.');
    if (!mounted) return;
    setState(() {
      _denied = !result;
      _requesting = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(localProfileSettingsProvider);
    final unlocked = ref.watch(localProfileUnlockedProvider);
    final values = settings.asData?.value;
    final visible = values != null && (!values.requireDeviceUnlock || unlocked);
    return Stack(
      fit: StackFit.expand,
      children: [
        Offstage(
          offstage: !visible,
          child: ExcludeFocus(
            excluding: !visible,
            child: TickerMode(enabled: visible, child: widget.child),
          ),
        ),
        if (!visible)
          Material(
            color: Theme.of(context).scaffoldBackgroundColor,
            child: SafeArea(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (settings.isLoading)
                        const CircularProgressIndicator()
                      else if (settings.hasError) ...[
                        const Text(
                          'Não foi possível abrir as configurações locais.',
                        ),
                        const SizedBox(height: 12),
                        FilledButton(
                          onPressed: () =>
                              ref.invalidate(localProfileSettingsProvider),
                          child: const Text('Tentar novamente'),
                        ),
                      ] else ...[
                        const Icon(Icons.lock_outline_rounded, size: 40),
                        const SizedBox(height: 12),
                        Text(
                          'Life OS bloqueado',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        if (_denied)
                          const Text(
                            'O bloqueio do Android não foi confirmado.',
                          ),
                        const SizedBox(height: 12),
                        FilledButton(
                          onPressed: _requesting ? null : _unlock,
                          child: const Text('Desbloquear'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
