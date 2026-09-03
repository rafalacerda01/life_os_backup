import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:life_os/features/auth/presentation/providers/auth_provider.dart';
import 'package:life_os/features/auth/presentation/providers/auth_state.dart';
import 'package:life_os/features/settings/presentation/providers/biometric_provider.dart';

class BiometricAppGate extends ConsumerStatefulWidget {
  const BiometricAppGate({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<BiometricAppGate> createState() => _BiometricAppGateState();
}

class _BiometricAppGateState extends ConsumerState<BiometricAppGate>
    with WidgetsBindingObserver {
  bool _authenticationRequestScheduled = false;
  bool _signOutInProgress = false;
  bool _sessionWasAuthenticated = false;
  bool _lifecycleLocked = false;
  String? _authenticatedUid;
  AppLifecycleState? _lifecycleState;
  BiometricLockStatus? _lastBiometricStatus;

  bool get _isForeground =>
      _lifecycleState == null || _lifecycleState == AppLifecycleState.resumed;

  @override
  void initState() {
    super.initState();
    _lifecycleState = WidgetsBinding.instance.lifecycleState;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    _lifecycleState = state;
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      if (ref.read(authNotifierProvider) is AuthAuthenticated &&
          ref.read(biometricProvider).isEnabled) {
        _lifecycleLocked = true;
        ref.read(biometricProvider.notifier).lock();
        setState(() {});
      }
      return;
    }
    if (state == AppLifecycleState.resumed) _scheduleUnlockIfNeeded();
  }

  void _scheduleUnlockIfNeeded() {
    if (_authenticationRequestScheduled || !mounted) return;
    final authState = ref.read(authNotifierProvider);
    final biometricState = ref.read(biometricProvider);
    if (authState is! AuthAuthenticated ||
        !biometricState.isLocked ||
        biometricState.authenticationInProgress) {
      return;
    }

    _authenticationRequestScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        if (mounted &&
            ref.read(authNotifierProvider) is AuthAuthenticated &&
            ref.read(biometricProvider).isLocked) {
          final unlocked = await ref.read(biometricProvider.notifier).unlock();
          _handleUnlockResult(unlocked);
        }
      } finally {
        _authenticationRequestScheduled = false;
      }
    });
  }

  Future<void> _retry() async {
    if (_authenticationRequestScheduled) return;
    _authenticationRequestScheduled = true;
    try {
      final unlocked = await ref.read(biometricProvider.notifier).unlock();
      _handleUnlockResult(unlocked);
    } finally {
      _authenticationRequestScheduled = false;
    }
  }

  void _handleUnlockResult(bool unlocked) {
    if (!unlocked || !mounted) return;
    if (_isForeground) {
      setState(() => _lifecycleLocked = false);
    } else {
      ref.read(biometricProvider.notifier).lock();
    }
  }

  Future<void> _signOut() async {
    if (_signOutInProgress) return;
    setState(() => _signOutInProgress = true);
    try {
      await ref.read(authNotifierProvider.notifier).logout();
      if (ref.read(authNotifierProvider) is AuthUnauthenticated) {
        await ref.read(biometricProvider.notifier).clearAfterConfirmedSignOut();
      }
    } catch (_) {
      // AuthNotifier owns user-facing logout errors and session cleanup.
    } finally {
      if (mounted) setState(() => _signOutInProgress = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authNotifierProvider);
    final biometricState = ref.watch(biometricProvider);
    final enteredLockedState =
        biometricState.isLocked &&
        _lastBiometricStatus != BiometricLockStatus.locked;
    _lastBiometricStatus = biometricState.status;

    if (authState is AuthAuthenticated) {
      if (_authenticatedUid != null &&
          _authenticatedUid != authState.user.uid &&
          biometricState.isEnabled) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) ref.read(biometricProvider.notifier).lock();
        });
        _sessionWasAuthenticated = true;
        _authenticatedUid = authState.user.uid;
        return const _BiometricLockScreen(loading: true);
      }
      _sessionWasAuthenticated = true;
      _authenticatedUid = authState.user.uid;
    } else if (authState is AuthUnauthenticated) {
      if (_sessionWasAuthenticated && biometricState.isEnabled) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) ref.read(biometricProvider.notifier).lock();
        });
      }
      _sessionWasAuthenticated = false;
      _authenticatedUid = null;
      return widget.child;
    } else if (!_sessionWasAuthenticated) {
      return widget.child;
    }

    if (!_lifecycleLocked &&
        (biometricState.status == BiometricLockStatus.disabled ||
            biometricState.status == BiometricLockStatus.unlocked)) {
      return widget.child;
    }

    if (enteredLockedState && _isForeground) {
      _scheduleUnlockIfNeeded();
    }
    return _BiometricLockScreen(
      loading: biometricState.status == BiometricLockStatus.loading,
      authenticating: biometricState.authenticationInProgress,
      signOutInProgress: _signOutInProgress,
      onRetry: _retry,
      onSignOut: _signOut,
    );
  }
}

class _BiometricLockScreen extends StatelessWidget {
  const _BiometricLockScreen({
    this.loading = false,
    this.authenticating = false,
    this.signOutInProgress = false,
    this.onRetry,
    this.onSignOut,
  });

  final bool loading;
  final bool authenticating;
  final bool signOutInProgress;
  final VoidCallback? onRetry;
  final VoidCallback? onSignOut;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFF070B14),
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock_outline, color: Colors.white, size: 52),
                const SizedBox(height: 20),
                Text(
                  loading ? 'Protegendo sua sessão...' : 'Life OS bloqueado',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (!loading) ...[
                  const SizedBox(height: 12),
                  Text(
                    authenticating
                        ? 'Confirme sua biometria no dispositivo.'
                        : 'Use sua biometria para continuar.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 28),
                  FilledButton.icon(
                    onPressed: authenticating ? null : onRetry,
                    icon: const Icon(Icons.fingerprint),
                    label: const Text('Tentar novamente'),
                  ),
                ],
                if (loading) const SizedBox(height: 20),
                TextButton(
                  onPressed: signOutInProgress ? null : onSignOut,
                  child: Text(
                    signOutInProgress
                        ? 'Encerrando sessão...'
                        : 'Encerrar sessão',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
